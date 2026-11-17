#!/bin/sh
# Fails if any deployable file in this repo mentions DISABLE_AUTH (or APP_DISABLE_AUTH).
# Production must never carry the local-dev auth bypass (Factory#312). Prose under docs/
# may name it. Usage: check-no-disable-auth.sh [root]   (default: repo root)
# Self-test: check-no-disable-auth.sh --self-test
set -eu
if [ "${1:-}" = --self-test ]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; self=$(cd "$(dirname "$0")" && pwd)/check-no-disable-auth.sh
  mkdir -p "$t/ok/apps/x" "$t/ok/docs" "$t/bad/apps/x" "$t/bad2/infra"
  printf 'env:\n  - name: APP_DISABLE_AUTH\n' >"$t/ok/docs/a.md"; echo 'kind: Deployment' >"$t/ok/apps/x/d.yaml"
  printf 'env:\n  - { name: APP_DISABLE_AUTH, value: "true" }\n' >"$t/bad/apps/x/d.yaml"
  printf 'x: disable_auth=1\n' >"$t/bad2/infra/v.yml"
  sh "$self" "$t/ok" >/dev/null || { echo "FAIL: clean tree rejected"; exit 1; }
  sh "$self" "$t/bad" >/dev/null 2>&1 && { echo "FAIL: APP_DISABLE_AUTH not caught"; exit 1; }
  sh "$self" "$t/bad2" >/dev/null 2>&1 && { echo "FAIL: lowercase not caught"; exit 1; }
  mkdir -p "$t/bad3/apps/docs"; echo 'APP_DISABLE_AUTH=1' >"$t/bad3/apps/docs/d.yaml"
  sh "$self" "$t/bad3" >/dev/null 2>&1 && { echo "FAIL: nested docs dir exempted"; exit 1; }
  if [ "$(id -u)" != 0 ]; then
    mkdir -p "$t/bad4"; echo x >"$t/bad4/f.yaml"; chmod 000 "$t/bad4/f.yaml"
    sh "$self" "$t/bad4" >/dev/null 2>&1 && { echo "FAIL: unreadable file passed"; exit 1; }
  fi
  sh "$self" "$t/nonexistent" >/dev/null 2>&1 && { echo "FAIL: missing root passed"; exit 1; }
  echo "self-test PASS"; exit 0
fi
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
[ -d "$root" ] || { echo "FAIL: $root is not a directory" >&2; exit 2; }
cd "$root"
# Only the top-level docs/ (prose) and this script (names the flag on purpose) are exempt.
# grep exits 1 for "no match" and 2 for an error: an unreadable file must not pass.
out=$(mktemp); trap 'rm -f "$out"' EXIT
rc=0
grep -rIniE 'disable_auth' . --exclude-dir=.git >"$out" 2>&1 || rc=$?
[ "$rc" -lt 2 ] || { echo "FAIL: scan error (unreadable file?), cannot vouch for the tree" >&2; cat "$out" >&2; exit 2; }
hits=$(grep -v -e '^\./docs/' -e '^\./scripts/check-no-disable-auth\.sh:' "$out" || :)
if [ -n "$hits" ]; then
  echo "FAIL: DISABLE_AUTH found in deployable files (production must run real auth):" >&2
  echo "$hits" >&2
  exit 1
fi
echo "OK: no DISABLE_AUTH outside docs/"
