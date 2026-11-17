#!/bin/bash
# Dev-only end-to-end test against a THROWAWAY Keycloak container (never the cluster).
# A second realm "upstream" stands in for GitHub as the brokered IdP (alias "github").
# Proves: the script builds the flow, the realm JSON matches the live flow, a brokered
# user WITH otp is challenged, a user WITHOUT otp is not, a wrong code is refused,
# unbind restores the unchallenged login. Needs docker, curl, jq, python3.
#   sh e2e-local.sh        (pulls the pinned image, removes its container on exit)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
IMG=$(grep -o 'quay.io/keycloak/keycloak:[^ "]*' "$here/cronjob.yaml" | head -n1)
N=kc-broker-otp-e2e; PORT=${E2E_PORT:-18081}; PW=throwaway-e2e
tmp=$(mktemp -d); trap '[ -n "${E2E_KEEP:-}" ] || docker rm -f $N >/dev/null 2>&1; rm -rf "$tmp"' EXIT
docker rm -f $N >/dev/null 2>&1 || :
docker run -d --name $N -p 127.0.0.1:$PORT:$PORT -e KC_HTTP_PORT=$PORT -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=$PW "$IMG" start-dev >/dev/null
for _ in $(seq 90); do curl -sf "localhost:$PORT/realms/master" >/dev/null && break; sleep 2; done
curl -sf "localhost:$PORT/realms/master" >/dev/null || { echo "FAIL keycloak did not start"; exit 1; }
kc() { docker exec $N /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/e2e.cfg </dev/null; }
fail() { echo "FAIL $1"; exit 1; }
kc config credentials --server http://localhost:$PORT --realm master --user admin --password $PW >/dev/null

# --- fixtures: upstream (fake GitHub) + factory realm with the brokered IdP ----------
kc create realms -s realm=upstream -s enabled=true >/dev/null
kc create clients -r upstream -s clientId=factory-broker -s secret=s3cret -s publicClient=false -s 'redirectUris=["*"]' >/dev/null
for u in gh-a gh-b; do
  kc create users -r upstream -s username=$u -s enabled=true -s email=$u@example.test -s emailVerified=true -s firstName=$u -s lastName=x >/dev/null
  kc set-password -r upstream --username $u --new-password pw-throwaway-1 >/dev/null
done
kc create realms -s realm=factory -s enabled=true >/dev/null
kc create clients -r factory -s clientId=app -s publicClient=true -s 'redirectUris=["*"]' >/dev/null
kc create identity-provider/instances -r factory -s alias=github -s providerId=oidc -s enabled=true \
  -s config.clientId=factory-broker -s config.clientSecret=s3cret -s config.validateSignature=false \
  -s config.authorizationUrl="http://localhost:$PORT/realms/upstream/protocol/openid-connect/auth" \
  -s config.tokenUrl=http://localhost:$PORT/realms/upstream/protocol/openid-connect/token \
  -s config.userInfoUrl=http://localhost:$PORT/realms/upstream/protocol/openid-connect/userinfo \
  -s config.defaultScope=openid >/dev/null
SECRET=JBSWY3DPEHPK3PXPJBSW   # arbitrary; Keycloak keys the HMAC with these bytes
# factory users pre-linked to the upstream users so the first-broker-login flow is not in play
mk() { # name withOtp
  cred=''
  [ "$2" = yes ] && cred=",\"credentials\":[{\"type\":\"otp\",\"secretData\":\"{\\\"value\\\":\\\"$SECRET\\\"}\",\"credentialData\":\"{\\\"subType\\\":\\\"totp\\\",\\\"digits\\\":6,\\\"counter\\\":0,\\\"period\\\":30,\\\"algorithm\\\":\\\"HmacSHA1\\\"}\"}]"
  kc create users -r factory -b "{\"username\":\"$1\",\"enabled\":true,\"email\":\"$1@example.test\",\"emailVerified\":true,\"firstName\":\"$1\",\"lastName\":\"x\"$cred}" >/dev/null
  fid=$(kc get users -r factory -q username=$1 --fields id --format csv --noquotes)
  uid=$(kc get users -r upstream -q username=$3 --fields id --format csv --noquotes)
  kc create "users/$fid/federated-identity/github" -r factory -s userId="$uid" -s userName=$3 >/dev/null
}
mk alice no gh-a; mk bob yes gh-b

run_job() { # mode  (the real script, run inside the container)
  docker cp "$here/keycloak-broker-otp.sh" $N:/tmp/b.sh
  docker exec -e KC_URL=http://localhost:$PORT -e KCADM_PASSWORD=$PW -e KCADM_CONFIG=/tmp/b.cfg -e BROKER_OTP_MODE=$1 $N sh /tmp/b.sh
}

# --- brokered login driver ------------------------------------------------------------
totp() { python3 -I - "$SECRET" "${1:-0}" <<'PY'
import hmac,hashlib,struct,sys,time
c=int(time.time())//30+int(sys.argv[2])
h=hmac.new(sys.argv[1].encode(),struct.pack(">Q",c),hashlib.sha1).digest()
o=h[-1]&15; print("%06d"%((struct.unpack(">I",h[o:o+4])[0]&0x7fffffff)%1000000))
PY
}
action() { grep -o 'action="[^"]*"' "$1" | head -n1 | sed 's/^action="//;s/"$//;s/&amp;/\&/g'; }
# login USER -> prints "code" | "otp" (stopped at an OTP form) ; leaves the OTP page in $tmp/page
login() {
  rm -f "$tmp/jar"
  url=$(curl -s -L -c "$tmp/jar" -b "$tmp/jar" -o "$tmp/page" -w '%{url_effective}' \
    "http://localhost:$PORT/realms/factory/protocol/openid-connect/auth?client_id=app&redirect_uri=http://127.0.0.1:9/cb&response_type=code&scope=openid&kc_idp_hint=github") || :
  a=$(action "$tmp/page"); [ -n "$a" ] || fail "no upstream login form"
  url=$(curl -s -L -c "$tmp/jar" -b "$tmp/jar" -o "$tmp/page" -w '%{url_effective}' -d username=$1 -d password=pw-throwaway-1 "$a") || :
  case "$url" in http://127.0.0.1:9/cb*code=*) echo code; return;; esac
  grep -q 'name="otp"' "$tmp/page" && echo otp || { echo "unexpected: $url"; head -c 600 "$tmp/page"; echo other; }
}
send_otp() { a=$(action "$tmp/page"); curl -s -L -c "$tmp/jar" -b "$tmp/jar" -o "$tmp/page" -w '%{url_effective}' -d "otp=$1" -d login=Sign+In "$a" || :; }

# --- tests ---------------------------------------------------------------------------
run_job audit | grep -q 'flow_present=no' || fail "audit before install"
[ "$(login gh-b)" = code ] || fail "baseline: bob should not be challenged before the flow is bound"
echo "PASS baseline: no challenge without the flow"

run_job install >/dev/null || fail "install"
run_job install | grep -q 'already present and matching' || fail "install not idempotent"
[ "$(login gh-b)" = code ] || fail "install alone must not bind the flow"
echo "PASS install builds the flow, is idempotent, and does not bind"

# the committed realm JSON equals the live flow (ids dropped)
tok=$(curl -s -d grant_type=password -d client_id=admin-cli -d username=admin -d password=$PW "localhost:$PORT/realms/master/protocol/openid-connect/token" | jq -r .access_token)
curl -s -X POST -H "Authorization: Bearer $tok" "localhost:$PORT/admin/realms/factory/partial-export?exportClients=false&exportGroupsAndRoles=false" \
  | jq -S '[.authenticationFlows[]|select(.alias|startswith("post-broker-otp"))|del(.id)]|sort_by(.alias)' >"$tmp/live.json"
jq -S '[.authenticationFlows[]|del(.id)]|sort_by(.alias)' "$here/post-broker-otp.realm.json" >"$tmp/want.json"
diff "$tmp/want.json" "$tmp/live.json" >&2 || fail "post-broker-otp.realm.json differs from the live flow"
echo "PASS realm JSON matches the live flow"

run_job bind >/dev/null || fail "bind"
r=$(login gh-a); [ "$r" = code ] || fail "alice (no otp) must not be challenged: $r"
echo "PASS bound: user without a second factor is not challenged"
[ "$(login gh-b)" = otp ] || fail "bob (otp) must be challenged"
out=$(send_otp 000000); case "$out" in http://127.0.0.1:9/cb*code=*) fail "wrong otp accepted";; esac
echo "PASS bound: user with otp is challenged, wrong code refused"
[ "$(login gh-b)" = otp ] || fail "bob challenge again"
out=$(send_otp "$(totp)"); case "$out" in http://127.0.0.1:9/cb*code=*) ;; *) out=$(send_otp "$(totp 1)"); case "$out" in http://127.0.0.1:9/cb*code=*) ;; *) fail "right otp refused: $out";; esac;; esac
echo "PASS bound: right code completes the login"

# bind refuses to replace a different flow; unbind restores the plain login
run_job unbind >/dev/null || fail "unbind"
[ "$(login gh-b)" = code ] || fail "unbind did not remove the challenge"
echo "PASS unbind removes the challenge"

# keycloak-mfa.sh (#360) on the same realm: the unverified `requiredActions+=` append, and what a
# brokered login does with a pending CONFIGURE_TOTP.
aid=$(kc get users -r factory -q username=alice --fields id --format csv --noquotes)
kc update "users/$aid" -r factory -s 'requiredActions=["UPDATE_PASSWORD"]' >/dev/null
mfa() { docker cp "$here/../../keycloak-mfa/manifests/keycloak-mfa.sh" $N:/tmp/m.sh
  docker exec -e KC_URL=http://localhost:$PORT -e KCADM_PASSWORD=$PW -e KCADM_CONFIG=/tmp/m.cfg -e MFA_MODE=enforce -e MFA_REQUIRE_ENROLLED=bob $N sh /tmp/m.sh; }
mfa >/dev/null || fail "keycloak-mfa enforce"
mfa >/dev/null || fail "keycloak-mfa enforce (second run)"
acts=$(kc get "users/$aid" -r factory --fields requiredActions --format csv --noquotes)
[ "$acts" = "CONFIGURE_TOTP,UPDATE_PASSWORD" ] || fail "requiredActions+= result: $acts"
echo "PASS requiredActions+= appends, keeps UPDATE_PASSWORD, adds no duplicate on a second run"
enrol() { # a brokered login with CONFIGURE_TOTP pending must reach the enrolment form, never the app
  kc update "users/$aid" -r factory -s 'requiredActions=["CONFIGURE_TOTP"]' >/dev/null
  r=$(login gh-a); [ "$r" != code ] || fail "$1: brokered login skipped the pending CONFIGURE_TOTP"
  grep -q 'name="totp"' "$tmp/page" || fail "$1: no OTP enrolment form for a pending CONFIGURE_TOTP"
}
enrol "flow unbound"
run_job bind >/dev/null || fail "rebind"
enrol "flow bound"
echo "PASS a brokered login with CONFIGURE_TOTP pending is sent to OTP enrolment, flow unbound and bound"

# bind never replaces another flow bound to the IdP
run_job unbind >/dev/null || fail "unbind before the foreign-flow test"
kc update identity-provider/instances/github -r factory -s 'postBrokerLoginFlowAlias=first broker login' >/dev/null
run_job bind >/dev/null 2>&1 && fail "bind replaced a foreign post-broker flow"
kc get identity-provider/instances/github -r factory --fields postBrokerLoginFlowAlias --format csv --noquotes | grep -q 'first broker login' || fail "foreign binding was changed"
kc update identity-provider/instances/github -r factory -s postBrokerLoginFlowAlias= >/dev/null
echo "PASS bind refuses to replace a different post-broker flow"
run_job bind >/dev/null || fail "rebind after the foreign-flow test"

# drift: someone edits the flow by hand -> install/bind refuse, audit shows it, unbind still works
id=$(kc get authentication/flows/post-broker-otp/executions -r factory --fields id,providerId,displayName --format csv --noquotes | grep 'OTP Form' | cut -d, -f1)
kc update authentication/flows/post-broker-otp-conditional/executions -r factory -b "{\"id\":\"$id\",\"requirement\":\"DISABLED\"}" >/dev/null
run_job audit | grep -q 'flow_present=drift' || fail "audit did not report drift"
run_job install >/dev/null 2>&1 && fail "install accepted a drifted flow"
run_job bind >/dev/null 2>&1 && fail "bind accepted a drifted flow"
run_job unbind >/dev/null || fail "unbind blocked by a drifted flow"
kc get identity-provider/instances/github -r factory --fields postBrokerLoginFlowAlias --format csv --noquotes | grep -q post-broker-otp && fail "unbind left the binding"
echo "PASS a hand-edited flow is refused by install/bind, shown by audit, and unbind still works"
echo "ALL PASS"
