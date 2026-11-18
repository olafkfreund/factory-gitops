#!/usr/bin/env bash
# Cluster-free tests for verify-no-provider-keys.sh; fixture values are throwaway.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/nojq" "$work/nokube"
cat > "$work/bin/kubectl" <<'KUBE'
#!/bin/bash
case "$*" in
  '--context k3d-factory -n factory get deploy aifactory pfactory tfactory cfactory -o json') file=deploy ;;
  '--context k3d-factory -n factory get jobs -l factory.io/kind -o json') file=jobs ;;
  *) exit 97 ;;
esac
[[ ${KUBECTL_FAIL:-} == "$file" ]] && exit 97
cat "$FIXTURES/$file.json"
KUBE
chmod +x "$work/bin/kubectl"
cp "$work/bin/kubectl" "$work/nojq/kubectl"
for tool in chmod cp jq mktemp rm sed tail; do
    ln -s "$(command -v "$tool")" "$work/nokube/$tool"
done
printf '{bad json' > "$work/bad.json"
: > "$work/empty.json"
printf 'throwaway-gateway-token\n' > "$work/token"
cat > "$work/fixtures.py" <<'PY'
import json, os, sys
mode = sys.argv[1]
base = os.environ['FIXTURES']

def pod(name):
    return {'metadata': {'name': name}, 'spec': {'template': {'spec': {
        'containers': [{'name': 'main'}], 'initContainers': [{'name': 'init'}], 'volumes': []
    }}}}

d = [pod(n) for n in ('aifactory', 'pfactory', 'tfactory', 'cfactory')]
j = [pod('build-job')]
container = d[0]['spec']['template']['spec']['containers'][0]
init = d[0]['spec']['template']['spec']['initContainers'][0]
key = 'OPENAI_COMPATIBLE_API_KEY'
secret = {'name': key, 'valueFrom': {'secretKeyRef': {'name': 'provider-secret', 'key': 'PROVIDER_KEY'}}}
literal = {'name': key, 'value': 'throwaway-provider-value'}
ref = {'name': key, 'valueFrom': {'secretKeyRef': {'name': 'factory-secrets', 'key': 'MODEL_GATEWAY_CLIENT_TOKEN'}}}
volume = {'name': 'cli-volume', 'projected': {'sources': [{'secret': {'name': 'factory-cli-creds'}}]}}
if mode == 'env-secret': container['env'] = [secret]
elif mode == 'env-literal': container['env'] = [literal]
elif mode == 'env-unverified': container['env'] = [literal]
elif mode == 'envfrom': init['envFrom'] = [{'secretRef': {'name': 'provider-bundle'}}]
elif mode == 'volume': d[0]['spec']['template']['spec']['volumes'] = [volume]
elif mode == 'job': j[0]['spec']['template']['spec']['containers'][0]['env'] = [secret]
elif mode == 'gateway-ref': container['env'] = [ref]
elif mode == 'wrong-secret':
    ref['valueFrom']['secretKeyRef']['name'] = 'other-secret'
    container['env'] = [ref]
elif mode == 'gateway-literal': container['env'] = [{'name': key, 'value': 'throwaway-gateway-token'}]
elif mode == 'zero-jobs': j = []
elif mode == 'missing-deploy': d.pop()
for name, items in (('deploy', d), ('jobs', j)):
    with open(f'{base}/{name}.json', 'w') as f:
        json.dump({'items': items}, f)
if mode == 'malformed':
    with open(f'{base}/jobs.json', 'w') as f: f.write('{bad json')
PY
export FIXTURES="$work"
export PATH="$work/bin:$PATH"
check() { # mode expected-exit expected-text [extra args...]
    local mode=$1 want=$2 pattern=$3 rc=0 out
    shift 3
    python3 "$work/fixtures.py" "$mode"
    out=$(PATH="${RUN_PATH:-$PATH}" /bin/bash "$here/verify-no-provider-keys.sh" "$@" 2>&1) || rc=$?
    if [[ $rc != "$want" || $out != *"$pattern"* ]]; then
        printf 'FAIL %s: exit %s, expected %s; output: %s\n' "$mode" "$rc" "$want" "$out" >&2
        exit 1
    fi
    if [[ $out == *throwaway-gateway-token* || $out == *throwaway-provider-value* ]]; then
        echo "FAIL $mode leaked a literal" >&2; exit 1
    fi
    echo "pass $mode"
}
check clean 0 'deployments=4 jobs=1 inspection_failed=0 static=0' --strict
check env-secret 1 'VIOLATION Deployment/aifactory main OPENAI_COMPATIBLE_API_KEY' --strict
check env-literal 1 'VIOLATION Deployment/aifactory main OPENAI_COMPATIBLE_API_KEY' --strict --gateway-token-file "$work/token"
check env-unverified 1 'UNVERIFIED Deployment/aifactory main OPENAI_COMPATIBLE_API_KEY' --strict
check envfrom 1 'UNVERIFIED Deployment/aifactory init provider-bundle' --strict
check volume 1 'VIOLATION Deployment/aifactory cli-volume factory-cli-creds' --strict
check job 1 'VIOLATION Job/build-job main OPENAI_COMPATIBLE_API_KEY' --strict
check gateway-ref 0 'GATEWAY-REF Deployment/aifactory main OPENAI_COMPATIBLE_API_KEY' --strict
check wrong-secret 1 'VIOLATION Deployment/aifactory main OPENAI_COMPATIBLE_API_KEY' --strict
check gateway-literal 0 'GATEWAY-REF Deployment/aifactory main OPENAI_COMPATIBLE_API_KEY' --strict --gateway-token-file "$work/token"
check volume 0 'ACCEPTED Deployment/aifactory cli-volume factory-cli-creds' --strict --accept-volume cli-volume
check env-secret 0 'VIOLATION Deployment/aifactory main OPENAI_COMPATIBLE_API_KEY'
check zero-jobs 1 'INSPECTION-FAIL' --strict
check malformed 1 'INSPECTION-FAIL' --strict
check missing-deploy 1 'INSPECTION-FAIL' --strict
KUBECTL_FAIL='jobs' check clean 1 'INSPECTION-FAIL' --strict
RUN_PATH="$work/nojq" check clean 1 'INSPECTION-FAIL jq unavailable' --strict
RUN_PATH="$work/nokube" check clean 0 'deployments=4 jobs=0 inspection_failed=0 static=1' --strict --deployments-json "$work/deploy.json"
check env-secret 0 'SUMMARY VIOLATION=1 UNVERIFIED=0 GATEWAY-REF=0 ACCEPTED=0 deployments=4 jobs=0 inspection_failed=0 static=1' --deployments-json "$work/deploy.json"
check env-secret 1 'VIOLATION Deployment/aifactory main OPENAI_COMPATIBLE_API_KEY' --strict --deployments-json "$work/deploy.json"
check clean 0 'INSPECTION-FAIL Deployments file unreadable' --deployments-json "$work/missing.json"
check clean 1 'inspection_failed=1 static=1' --strict --deployments-json "$work/missing.json"
check clean 1 'INSPECTION-FAIL invalid workload data' --strict --deployments-json "$work/empty.json"
check clean 1 'inspection_failed=1 static=1' --strict --deployments-json "$work/bad.json"
echo 'verify-no-provider-keys tests passed'
