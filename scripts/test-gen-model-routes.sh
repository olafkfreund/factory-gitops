#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/apps/model-gateway/manifests"
cp "$repo/scripts/gen-model-routes.py" "$tmp/scripts/"
cp "$repo/apps/model-gateway/hub-catalog.sha" "$tmp/apps/model-gateway/"
printf '{}\n' > "$tmp/apps/model-gateway/route-overrides.json"
cat > "$tmp/catalog.json" <<'JSON'
{"models": {
  "cheap-z": {"class":"cheap","provider":"claude","price":{"mode":"metered","in_per_mtok":1,"out_per_mtok":1},"caps":{"context":200}},
  "cheap-a": {"class":"cheap","provider":"claude","price":{"mode":"metered","in_per_mtok":1,"out_per_mtok":1},"caps":{"context":200}},
  "cheap-small": {"class":"cheap","provider":"claude","price":{"mode":"metered","in_per_mtok":1,"out_per_mtok":1},"caps":{"context":100}},
  "cheap-expensive": {"class":"cheap","provider":"claude","price":{"mode":"metered","in_per_mtok":2,"out_per_mtok":2},"caps":{"context":1000}},
  "balanced-ok": {"class":"balanced","provider":"claude","price":{"mode":"metered","in_per_mtok":3,"out_per_mtok":3},"caps":{"context":100}},
  "balanced-subscription": {"class":"balanced","provider":"claude","price":{"mode":"subscription"},"caps":{"context":1000}},
  "balanced-other": {"class":"balanced","provider":"gemini","price":{"mode":"metered","in_per_mtok":0,"out_per_mtok":0},"caps":{"context":1000}},
  "balanced-<model>": {"class":"balanced","provider":"claude","price":{"mode":"metered","in_per_mtok":0,"out_per_mtok":0},"caps":{"context":1000}},
  "frontier-ok": {"class":"frontier","provider":"claude","price":{"mode":"metered","in_per_mtok":5,"out_per_mtok":5},"caps":{"context":100}},
  "local-<model>": {"class":"local","provider":"ollama","price":{"mode":"local"},"caps":{"context":100}}
}}
JSON
script="$tmp/scripts/gen-model-routes.py"
output="$tmp/apps/model-gateway/manifests/model-routes.yaml"
python3 "$script" --catalog "$tmp/catalog.json"
python3 "$script" --catalog "$tmp/catalog.json" --check
grep -q '"cheap": "cheap-a"' "$output"
grep -q '"balanced": "balanced-ok"' "$output"
grep -q '"frontier": "frontier-ok"' "$output"
if grep -q '"local"' "$output"; then exit 1; fi
cp "$output" "$tmp/no-policy.yaml"
printf '{}\n' > "$tmp/apps/model-gateway/route-policy.json"
python3 "$script" --catalog "$tmp/catalog.json"
cmp "$output" "$tmp/no-policy.yaml"
cat > "$tmp/apps/model-gateway/route-policy.json" <<'JSON'
{"cheap":{"quota":{"requests":10,"tokens":100},"upstreams":[{"url":"https://primary.example/","key_env":"GATEWAY_UPSTREAM_API_KEY"},{"url":"http://backup.example/","key_env":"GATEWAY_UPSTREAM2_API_KEY","model":"backup-model"}]}}
JSON
python3 "$script" --catalog "$tmp/catalog.json"
python3 - "$output" <<'PY'
import json
import sys

lines = open(sys.argv[1]).read().split('  routes.json: |\n', 1)[1].splitlines()
routes = json.loads('\n'.join(line[4:] for line in lines))
assert routes['cheap'] == {
    'model': 'cheap-a',
    'quota': {'window_s': 60, 'requests': 10, 'tokens': 100},
    'upstreams': [
        {'url': 'https://primary.example', 'key_env': 'GATEWAY_UPSTREAM_API_KEY'},
        {'url': 'http://backup.example', 'key_env': 'GATEWAY_UPSTREAM2_API_KEY', 'model': 'backup-model'},
    ],
}
assert routes['balanced'] == 'balanced-ok'
PY
for bad in \
    '[]' \
    '{' \
    '{"cheap":{"quota":{"requests":0}}}' \
    '{"cheap":{"quota":{"requests":true}}}' \
    '{"cheap":{"quota":{"requests":-1}}}' \
    '{"cheap":{"quota":{"window_s":60}}}' \
    '{"cheap":{"upstreams":[{"url":"ftp://primary.example"}]}}' \
    '{"cheap":{"upstreams":[{"url":"https://primary.example","key_env":"GATEWAY_UPSTREAM99_API_KEY"}]}}' \
    '{"cheap":{"upstreams":[{"url":"https://primary.example","key_env":"PATH"}]}}' \
    '{"unknown":{}}' \
    '{"cheap":{"unknown":1}}' \
    '{"local":{"quota":{"requests":1}}}'; do
    printf '%s\n' "$bad" > "$tmp/apps/model-gateway/route-policy.json"
    if python3 "$script" --catalog "$tmp/catalog.json" > "$tmp/out" 2>&1; then
        echo "invalid policy passed: $bad" >&2; exit 1
    else
        status=$?
        test "$status" -eq 2
    fi
done
printf '{}\n' > "$tmp/apps/model-gateway/route-policy.json"

printf '{"cheap":"override-model"}\n' > "$tmp/apps/model-gateway/route-overrides.json"
python3 "$script" --catalog "$tmp/catalog.json"
grep -q '"cheap": "override-model"' "$output"
for bad in '{"unknown":"model"}' '{"cheap":""}'; do
    printf '%s\n' "$bad" > "$tmp/apps/model-gateway/route-overrides.json"
    if python3 "$script" --catalog "$tmp/catalog.json" > "$tmp/out" 2>&1; then
        echo "invalid override passed" >&2; exit 1
    else
        status=$?
        test "$status" -eq 2
    fi
done
printf '{}\n' > "$tmp/apps/model-gateway/route-overrides.json"
if python3 "$script" --catalog "$tmp/catalog.json" --check > "$tmp/diff"; then
    echo "drift passed --check" >&2; exit 1
else
    status=$?
    test "$status" -eq 1
    grep -q '^--- ' "$tmp/diff"
fi

grep -q '^- model-routes.yaml$' "$repo/apps/model-gateway/manifests/kustomization.yaml"
if command -v kustomize >/dev/null 2>&1; then
    kustomize build "$repo/apps/model-gateway/manifests" > "$tmp/build.yaml"
    test -s "$tmp/build.yaml"
    grep -q 'name: model-routes' "$tmp/build.yaml"
elif test "${REQUIRE_KUSTOMIZE:-0}" = 1; then
    echo 'kustomize is required' >&2; exit 1
fi
echo 'gen-model-routes tests passed'
