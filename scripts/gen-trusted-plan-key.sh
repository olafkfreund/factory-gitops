#!/usr/bin/env bash
# Generate a trusted-plan HMAC key for a kid (Factory#3689, R-013).
#   gen-trusted-plan-key.sh <KID> <OUT_FILE>      e.g. 2026Q4 /dev/shm/tp-2026q4.env
#   gen-trusted-plan-key.sh --self-test
# The key is written ONLY to OUT_FILE (mode 600, must not exist). stdout carries the kid,
# the Secret key names, a fingerprint and the expiry, never the key. The trusted-plan key is a
# shared HMAC secret, so there is no public key: the fingerprint (first 12 hex of sha256) lets
# you compare two copies without showing either. Next steps: docs/secrets-management.md.
set -euo pipefail

gen() {
  local kid=$1 out=$2 key fp
  [[ $kid =~ ^[0-9A-Za-z]{2,16}$ ]] || { echo "kid must be 2-16 letters or digits (no _)" >&2; return 2; }
  [[ -e $out ]] && { echo "refusing to overwrite $out" >&2; return 2; }
  key=$(openssl rand -hex 32)
  (umask 077; printf 'AIFACTORY_TRUSTED_PLAN_KEY_PFACTORY__%s=%s\nPFACTORY_TRUSTED_PLAN_SIGNING_KEY__%s=%s\n' \
    "${kid^^}" "$key" "${kid^^}" "$key" > "$out")
  fp=$(printf %s "$key" | sha256sum | cut -c1-12)
  echo "kid:          ${kid,,}"
  echo "secret keys:  AIFACTORY_TRUSTED_PLAN_KEY_PFACTORY__${kid^^} (aifactory)"
  echo "              PFACTORY_TRUSTED_PLAN_SIGNING_KEY__${kid^^} (pfactory)"
  echo "fingerprint:  $fp"
  echo "expiry:       pfactory/${kid,,}=$(date -u -d '+104 days' +%F)   (90 days + 14 overlap)"
  echo "              make AIFACTORY_TRUSTED_PLAN_EXPIRY in apps/aifactory equal to this (manifest default: 2027-03-15)"
  echo "file:         $out (mode 600); seed both keys with agenix, then shred -u it"
}

if [[ ${1:-} == --self-test ]]; then
  d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
  out=$(gen 2026Q4 "$d/k.env")
  secret=$(sed -n '1s/^[^=]*=//p' "$d/k.env")
  [[ ${#secret} -eq 64 ]] || { echo "FAIL: key length" >&2; exit 1; }
  grep -qF "$secret" <<<"$out" && { echo "FAIL: key printed" >&2; exit 1; }
  [[ $(stat -c %a "$d/k.env") == 600 ]] || { echo "FAIL: mode" >&2; exit 1; }
  gen 2026Q4 "$d/k.env" 2>/dev/null && { echo "FAIL: overwrote" >&2; exit 1; }
  gen 'a_b' "$d/x.env" 2>/dev/null && { echo "FAIL: bad kid accepted" >&2; exit 1; }
  echo "self-test OK"; exit 0
fi
[[ $# -eq 2 ]] || { sed -n '2,4p' "$0" >&2; exit 2; }
gen "$1" "$2"
