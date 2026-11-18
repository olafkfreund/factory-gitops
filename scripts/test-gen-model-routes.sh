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
rg -q '"cheap": "cheap-a"' "$output"
rg -q '"balanced": "balanced-ok"' "$output"
rg -q '"frontier": "frontier-ok"' "$output"
if rg -q '"local"' "$output"; then exit 1; fi

printf '{"cheap":"override-model"}\n' > "$tmp/apps/model-gateway/route-overrides.json"
python3 "$script" --catalog "$tmp/catalog.json"
rg -q '"cheap": "override-model"' "$output"
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
    rg -q '^--- ' "$tmp/diff"
fi

rg -q '^- model-routes.yaml$' "$repo/apps/model-gateway/manifests/kustomization.yaml"
if command -v kustomize >/dev/null 2>&1; then
    kustomize build "$repo/apps/model-gateway/manifests" > "$tmp/build.yaml"
    test -s "$tmp/build.yaml"
    rg -q 'name: model-routes' "$tmp/build.yaml"
elif test "${REQUIRE_KUSTOMIZE:-0}" = 1; then
    echo 'kustomize is required' >&2; exit 1
fi
echo 'gen-model-routes tests passed'
