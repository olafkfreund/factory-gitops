#!/bin/sh
# Runs keycloak-mfa.sh against a stub kcadm.sh that serves fixtures and logs every call.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
FIX="$tmp/fix"; LOG="$tmp/calls.log"; mkdir -p "$FIX"
cat >"$tmp/kcadm.sh" <<STUB
#!/bin/sh
# stub: \$1 verb, \$2 path
echo "\$*" >>"$LOG"
case "\$1 \$2" in
  "config credentials") [ -z "\${FAIL_LOGIN:-}" ] ;;
  "get users") [ -z "\${FAIL_USERS:-}" ] && cat "$FIX/users.csv" ;;
  "get users/"*"/credentials") id=\${2#users/}; id=\${id%/credentials}; [ "\$id" != "\${FAIL_CREDS:-}" ] && cat "$FIX/creds-\$id" ;;
  "get users/"*) id=\${2#users/}; cat "$FIX/actions-\$id" ;;
  "update "*) [ "\$2" != "\${FAIL_UPDATE:-}" ] ;;
esac
STUB
chmod +x "$tmp/kcadm.sh"
export KCADM="$tmp/kcadm.sh" KCADM_CONFIG="$tmp/cfg" KCADM_PASSWORD=hunter2-sentinel
# id,username,enabled
cat >"$FIX/users.csv" <<USERS
u1,owner,true
u2,alice,true
u3,bob,true
u4,gone,false
u5,service-account-human,true
u6,carol,true
u7,breakglass,true
USERS
for u in u1 u6; do printf 'password\notp\n' >"$FIX/creds-$u"; done      # enrolled
printf 'password\n' >"$FIX/creds-u2"; printf 'password\n' >"$FIX/creds-u5"; printf 'password\n' >"$FIX/creds-u3"; printf 'password\n' >"$FIX/creds-u7"
for u in u1 u2 u5 u6 u7; do printf '\n' >"$FIX/actions-$u"; done
printf 'UPDATE_PASSWORD,CONFIGURE_TOTP\n' >"$FIX/actions-u3"              # bob already has it
fail() { echo "FAIL $1"; cat "$LOG" 2>/dev/null; cat "$tmp/out" 2>/dev/null; exit 1; }
run() { : >"$LOG"; env "$@" sh "$here/keycloak-mfa.sh" >"$tmp/out" 2>&1; }
writes() { grep -c '^update ' "$LOG" || true; }

run MFA_MODE=audit || fail "audit exit"
[ "$(writes)" = 0 ] || fail "audit wrote"
grep -q 'without_second_factor=4' "$tmp/out" && grep -q 'no second factor: alice' "$tmp/out" || fail "audit report"
! grep -q 'gone' "$tmp/out" || fail "audit listed a disabled user"
grep -q 'service-account-human' "$tmp/out" || fail "a human named service-account-* was skipped"
! grep -q hunter2-sentinel "$tmp/out" || fail "password echoed"
echo "PASS audit writes nothing, reports 4"

run MFA_MODE=new-users || fail "new-users exit"
[ "$(writes)" = 1 ] && grep -q '^update authentication/required-actions/CONFIGURE_TOTP .*defaultAction=true' "$LOG" || fail "new-users writes"
echo "PASS new-users writes only the action definition"

run MFA_MODE=enforce MFA_REQUIRE_ENROLLED= && fail "enforce without owner guard" || :
[ "$(writes)" = 0 ] || fail "guard wrote"
run MFA_MODE=enforce MFA_REQUIRE_ENROLLED=alice && fail "enforce with unenrolled owner" || :
[ "$(writes)" = 0 ] || fail "guard 2 wrote"
run MFA_MODE=enforce MFA_REQUIRE_ENROLLED=nobody && fail "enforce with unknown owner" || :
[ "$(writes)" = 0 ] || fail "guard 3 wrote"
echo "PASS enforce refuses without an enrolled MFA_REQUIRE_ENROLLED user"

run MFA_MODE=enforce MFA_REQUIRE_ENROLLED=owner,carol MFA_EXEMPT_USERS=breakglass || fail "enforce exit"
grep -q '^update users/u2 .*requiredActions+=CONFIGURE_TOTP' "$LOG" || fail "alice not assigned"
! grep -q '^update users/u3' "$LOG" || fail "bob already has it, must not be updated"
grep -q '^update users/u5 ' "$LOG" || fail "human named service-account-* not assigned"
! grep -qE '^update users/(u1|u4|u6|u7)' "$LOG" || fail "wrong user updated"
[ "$(writes)" = 3 ] || fail "expected action definition plus two users, got $(writes)"
grep -q 'exempt: breakglass' "$tmp/out" || fail "exempt not reported"
echo "PASS enforce updates only unenrolled, non-exempt, enabled users"

run MFA_MODE=enforce MFA_REQUIRE_ENROLLED=o.ner && fail "regex match let a lookalike satisfy the owner guard" || :
[ "$(writes)" = 0 ] || fail "lookalike guard wrote"
echo "PASS the owner guard matches names literally"

run MFA_MODE=bogus && fail "bogus mode accepted" || :
[ ! -s "$LOG" ] || fail "bogus mode called kcadm"
echo "PASS unknown mode refuses"

run MFA_MODE=enforce MFA_REQUIRE_ENROLLED=owner FAIL_CREDS=u3 && fail "read failure ignored" || :
[ "$(writes)" = 0 ] || fail "wrote after failed read"
run MFA_MODE=new-users FAIL_USERS=1 && fail "list failure ignored" || :
[ "$(writes)" = 0 ] || fail "wrote after failed list"
run MFA_MODE=new-users FAIL_LOGIN=1 && fail "login failure ignored" || :
[ "$(writes)" = 0 ] || fail "wrote after failed login"
echo "PASS a failed read aborts before any write"

run MFA_MODE=enforce MFA_REQUIRE_ENROLLED=owner FAIL_UPDATE=users/u2 && fail "update failure ignored" || :
echo "PASS a failed update fails the job"
