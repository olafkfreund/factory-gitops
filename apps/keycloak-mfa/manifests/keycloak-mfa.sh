#!/bin/sh
# Keycloak MFA ladder for realm "factory" (Factory#312). Modes: see cronjob.yaml.
# Reads everything first and writes only afterwards, so a failed read leaves the
# realm untouched. Never removes an action or a credential; never touches master.
set -eu

K="${KCADM:-/opt/keycloak/bin/kcadm.sh}"
URL="${KC_URL:-http://keycloak:8080}"
REALM=factory
MODE="${MFA_MODE:-audit}"
CFG="${KCADM_CONFIG:-/tmp/kcadm.config}"
EXEMPT=",$(printf %s "${MFA_EXEMPT_USERS:-}" | tr -d ' '),"
REQUIRE=$(printf %s "${MFA_REQUIRE_ENROLLED:-}" | tr -d ' ')
MAX_USERS=5000

case "$MODE" in audit | new-users | enforce) ;; *)
  echo "unknown MFA_MODE '$MODE': refusing, nothing written" >&2
  exit 2 ;;
esac

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# stdin closed: kcadm must not swallow the loop's input.
kc() { "$K" "$@" --config "$CFG" </dev/null; }
die() { echo "FAIL: $*" >&2; exit 1; }

kc config credentials --server "$URL" --realm master --user "${KC_ADMIN_USER:-admin}" \
  --password "$KCADM_PASSWORD" >/dev/null || die "admin login"

# ---- read phase ---------------------------------------------------------------
kc get users -r "$REALM" -q "max=$MAX_USERS" --fields id,username,enabled --format csv --noquotes \
  >"$W/users.csv" || die "list users"
[ "$(wc -l <"$W/users.csv")" -lt "$MAX_USERS" ] || die "user list may be truncated at $MAX_USERS"

: >"$W/unenrolled"    # id,username,has_action
: >"$W/enrolled"      # username
while IFS=, read -r id name enabled; do
  [ -n "$id" ] || continue
  [ "$enabled" = true ] || continue
  case "$name" in service-account-*) continue ;; esac
  kc get "users/$id/credentials" -r "$REALM" --fields type --format csv --noquotes \
    >"$W/creds" || die "credentials of a user"
  if grep -qxE 'otp|webauthn|webauthn-passwordless' "$W/creds"; then
    echo "$name" >>"$W/enrolled"
    continue
  fi
  kc get "users/$id" -r "$REALM" --fields requiredActions --format csv --noquotes \
    >"$W/actions" || die "required actions of a user"
  if grep -q CONFIGURE_TOTP "$W/actions"; then has=yes; else has=no; fi
  echo "$id,$name,$has" >>"$W/unenrolled"
done <"$W/users.csv"

echo "mode=$MODE realm=$REALM enrolled=$(wc -l <"$W/enrolled") without_second_factor=$(wc -l <"$W/unenrolled")"
cut -d, -f2 "$W/unenrolled" | sed 's/^/  no second factor: /'

# ---- guards -------------------------------------------------------------------
if [ "$MODE" = enforce ]; then
  [ -n "$REQUIRE" ] || die "enforce needs MFA_REQUIRE_ENROLLED (the owner): nothing written"
  for u in $(printf %s "$REQUIRE" | tr ',' ' '); do
    grep -qx "$u" "$W/enrolled" || die "MFA_REQUIRE_ENROLLED user '$u' has no second factor (or is not an enabled user): nothing written"
  done
fi

[ "$MODE" != audit ] || { echo "audit: nothing written"; exit 0; }

# ---- write phase --------------------------------------------------------------
kc update authentication/required-actions/CONFIGURE_TOTP -r "$REALM" \
  -s enabled=true -s defaultAction=true >/dev/null || die "enable CONFIGURE_TOTP"
echo "CONFIGURE_TOTP enabled and default for new users"

[ "$MODE" = enforce ] || exit 0

while IFS=, read -r id name has; do
  [ -n "$id" ] || continue
  case "$EXEMPT" in *",$name,"*) echo "exempt: $name"; continue ;; esac
  [ "$has" = no ] || { echo "already required: $name"; continue; }
  kc update "users/$id" -r "$REALM" -s 'requiredActions+=CONFIGURE_TOTP' >/dev/null \
    || die "assign CONFIGURE_TOTP to $name"
  echo "required: $name"
done <"$W/unenrolled"
