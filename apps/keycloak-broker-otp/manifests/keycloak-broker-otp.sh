#!/bin/sh
# Post-broker-login conditional OTP flow for realm "factory" (Factory#3781, R-010).
# Modes: see cronjob.yaml. The flow is the one in post-broker-otp.realm.json
# (realm-export format); this script builds exactly that tree with kcadm, because
# partial import does not carry authentication flows.
# Never edits or deletes an existing flow, never touches master, reads before writing.
set -eu

K="${KCADM:-/opt/keycloak/bin/kcadm.sh}"
URL="${KC_URL:-http://keycloak:8080}"
REALM=factory
IDP="${BROKER_IDP_ALIAS:-github}"
MODE="${BROKER_OTP_MODE:-audit}"
CFG="${KCADM_CONFIG:-/tmp/kcadm.config}"
FLOW=post-broker-otp
SUB=post-broker-otp-conditional
# Expected rows, in order: providerId,requirement,level,priority (what the realm JSON declares).
# The sub-flow row has no providerId. "Allow access" is the flow's one unconditional
# success: a flow whose only step is a skipped conditional fails every login. Explicit priorities: ties are ordered by id, not by intent.
WANT=",CONDITIONAL,0,10
conditional-user-configured,REQUIRED,1,10
auth-otp-form,REQUIRED,1,20
allow-access-authenticator,REQUIRED,0,20"

case "$MODE" in audit | install | bind | unbind) ;; *)
  echo "unknown BROKER_OTP_MODE '$MODE': refusing, nothing written" >&2
  exit 2 ;;
esac

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
kc() { "$K" "$@" --config "$CFG" </dev/null; }
die() { echo "FAIL: $*" >&2; exit 1; }

kc config credentials --server "$URL" --realm master --user "${KC_ADMIN_USER:-admin}" \
  --password "$KCADM_PASSWORD" >/dev/null || die "admin login"

# ---- read phase ---------------------------------------------------------------
kc get identity-provider/instances -r "$REALM" --fields alias --format csv --noquotes >"$W/idps" || die "list identity providers"
grep -qxF -- "$IDP" "$W/idps" || die "identity provider '$IDP' not found in realm $REALM: nothing written"
kc get "identity-provider/instances/$IDP" -r "$REALM" --fields postBrokerLoginFlowAlias --format csv --noquotes >"$W/bound" || die "read IdP"
BOUND=$(tr -d '\r\n' <"$W/bound")

kc get authentication/flows -r "$REALM" --fields alias --format csv --noquotes >"$W/flows" || die "list flows"
if grep -qxF -- "$FLOW" "$W/flows"; then
  kc get "authentication/flows/$FLOW/executions" -r "$REALM" --fields providerId,requirement,level,priority --format csv --noquotes >"$W/have" || die "read flow"
  if [ "$WANT" = "$(cat "$W/have")" ]; then HAVE=yes; else HAVE=drift; fi
else
  HAVE=no
fi
echo "mode=$MODE realm=$REALM idp=$IDP flow_present=$HAVE idp_post_broker_flow='${BOUND:-none}'"

[ "$MODE" != audit ] || { echo "audit: nothing written"; exit 0; }

# ---- write phase --------------------------------------------------------------
# unbind is the way out, so it must work even when the flow was edited by hand.
if [ "$MODE" = unbind ]; then
  [ "$BOUND" = "$FLOW" ] || { echo "unbind: '$IDP' is not bound to $FLOW; nothing to do"; exit 0; }
  kc update "identity-provider/instances/$IDP" -r "$REALM" -s postBrokerLoginFlowAlias= >/dev/null || die "unbind"
  echo "unbound $FLOW from $IDP"
  exit 0
fi

[ "$HAVE" != drift ] || die "flow '$FLOW' differs from post-broker-otp.realm.json (a change made by hand?): nothing written"

# requirement of one execution, by display name or providerId, within a flow
set_req() { # flow match requirement priority
  kc get "authentication/flows/$1/executions" -r "$REALM" --fields id,providerId,displayName --format csv --noquotes >"$W/ids" || die "read executions"
  id=$(grep -F -- "$2" "$W/ids" | head -n1 | cut -d, -f1)
  [ -n "$id" ] || die "execution '$2' not found in $1"
  kc update "authentication/flows/$1/executions" -r "$REALM" -b "{\"id\":\"$id\",\"requirement\":\"$3\",\"priority\":$4}" >/dev/null || die "set requirement $2"
}

if [ "$HAVE" = no ]; then
  kc create authentication/flows -r "$REALM" -s alias="$FLOW" -s providerId=basic-flow -s topLevel=true -s builtIn=false \
    -s description="Conditional OTP after a brokered login (Factory#3781)" >/dev/null || die "create flow"
  kc create "authentication/flows/$FLOW/executions/flow" -r "$REALM" -s alias="$SUB" -s type=basic-flow -s provider=registration-page-form >/dev/null || die "create sub-flow"
  set_req "$FLOW" "$SUB" CONDITIONAL 10
  kc create "authentication/flows/$SUB/executions/execution" -r "$REALM" -s provider=conditional-user-configured >/dev/null || die "add condition"
  kc create "authentication/flows/$SUB/executions/execution" -r "$REALM" -s provider=auth-otp-form >/dev/null || die "add otp"
  kc create "authentication/flows/$FLOW/executions/execution" -r "$REALM" -s provider=allow-access-authenticator >/dev/null || die "add allow-access"
  set_req "$FLOW" allow-access-authenticator REQUIRED 20
  set_req "$SUB" conditional-user-configured REQUIRED 10
  set_req "$SUB" auth-otp-form REQUIRED 20
  echo "created flow $FLOW"
else
  echo "flow $FLOW already present and matching"
fi

[ "$MODE" = bind ] || exit 0
if [ "$BOUND" = "$FLOW" ]; then echo "$IDP already bound"; exit 0; fi
[ -z "$BOUND" ] || die "$IDP is bound to '$BOUND', not replacing it by script: nothing bound"
kc update "identity-provider/instances/$IDP" -r "$REALM" -s postBrokerLoginFlowAlias="$FLOW" >/dev/null || die "bind"
echo "bound $FLOW to $IDP"
