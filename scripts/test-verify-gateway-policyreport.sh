#!/usr/bin/env bash
# Cluster-free tests for verify-gateway-policyreport.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/nojq"
cat > "$work/bin/kubectl" <<'KUBE'
#!/bin/bash
case "$*" in
  '--context k3d-factory -n gateway get deploy model-gateway -o json') file=deploy ;;
  '--context k3d-factory -n gateway get policyreport -o json') file=reports ;;
  '--context k3d-factory -n gateway get replicaset,pod -o json') file=children ;;
  *) exit 97 ;;
esac
[[ ${KUBECTL_FAIL:-} == "$file" ]] && exit 97
cat "$FIXTURES/$file.json"
KUBE
chmod +x "$work/bin/kubectl"
cp "$work/bin/kubectl" "$work/nojq/kubectl"
cat > "$work/fixtures.py" <<'PY'
import json, os, sys

mode = sys.argv[1]
base = os.environ['FIXTURES']
image = 'ghcr.io/olafkfreund/aifactory:sha-24184c6-gateway'
deployment = {'metadata': {'uid': 'current-uid'}, 'spec': {'template': {'spec': {
    'containers': [{'name': 'model-gateway', 'image': image}]}}}}
scope = {'kind': 'Deployment', 'name': 'model-gateway', 'uid': 'current-uid'}
row = {'policy': 'verify-factory-image-signatures', 'rule': 'verify-image',
       'result': 'pass', 'message': f'verified image signatures for {image}',
       'timestamp': {'seconds': 1763467200}}
children = [
    {'kind': 'ReplicaSet', 'metadata': {'uid': 'rs-uid', 'ownerReferences': [
        {'kind': 'Deployment', 'uid': 'current-uid'}]}},
    {'kind': 'Pod', 'metadata': {'uid': 'pod-uid', 'ownerReferences': [
        {'kind': 'ReplicaSet', 'uid': 'rs-uid'}]}}
]
if mode == 'cache': row['message'] = 'verified from cache'
elif mode == 'fail': row['result'] = 'fail'
elif mode == 'error': row['result'] = 'error'
elif mode == 'prefix': row['message'] += '-other'
elif mode == 'embedded': row['message'] = f'prefix/{image} verified'
elif mode == 'wrong-resource': scope['name'] = 'another-deployment'
elif mode == 'wrong-uid': scope['uid'] = 'old-uid'
elif mode == 'missing-uid':
    scope.pop('uid')
    deployment['metadata'].pop('uid')
elif mode == 'empty-image': deployment['spec']['template']['spec']['containers'][0]['image'] = ''
elif mode == 'other-policy': row['policy'] = 'another-policy'
elif mode == 'skip': row['result'] = 'skip'
elif mode == 'delimiter': row['message'] = f'verified {image}, signature valid'
items = [{'scope': scope, 'results': [row]}]
if mode in ('cache-pod', 'cache-rs', 'pod-unowned', 'pod-old-deploy',
            'pod-wrong-policy', 'pod-fail', 'pod-suffix', 'pod-no-uid'):
    child_row = row.copy()
    row['message'] = 'verified from cache'
    child_scope = {'kind': 'Pod', 'name': 'model-gateway-pod', 'uid': 'pod-uid'}
    if mode == 'cache-rs':
        child_scope = {'kind': 'ReplicaSet', 'name': 'model-gateway-rs', 'uid': 'rs-uid'}
    elif mode == 'pod-unowned':
        child_scope.update(name='model-gateway-evil', uid='unowned-uid')
        children.append({'kind': 'Pod', 'metadata': {'uid': 'unowned-uid'}})
    elif mode == 'pod-old-deploy':
        children[0]['metadata']['ownerReferences'][0]['uid'] = 'old-uid'
    elif mode == 'pod-wrong-policy': child_row['policy'] = 'another-policy'
    elif mode == 'pod-fail': child_row['result'] = 'fail'
    elif mode == 'pod-suffix': child_row['message'] += '-other'
    elif mode == 'pod-no-uid': child_scope.pop('uid')
    items.append({'scope': child_scope, 'results': [child_row]})
with open(f'{base}/deploy.json', 'w') as f:
    json.dump(deployment, f)
with open(f'{base}/reports.json', 'w') as f:
    json.dump({'items': items}, f)
with open(f'{base}/children.json', 'w') as f:
    json.dump({'items': children}, f)
if mode == 'malformed':
    with open(f'{base}/reports.json', 'w') as f: f.write('{bad json')
elif mode == 'not-list':
    with open(f'{base}/reports.json', 'w') as f: json.dump({'items': {}}, f)
PY
export FIXTURES="$work"
export PATH="$work/bin:$PATH"
check() { # mode expected-exit expected-text [extra args...]
    local mode=$1 want=$2 pattern=$3 rc=0 out
    shift 3
    python3 "$work/fixtures.py" "$mode"
    out=$(PATH="${RUN_PATH:-$PATH}" /bin/bash "$here/verify-gateway-policyreport.sh" "$@" 2>&1) || rc=$?
    if [[ $rc != "$want" || $out != *"$pattern"* || $out == *'verified image signatures'* ]]; then
        printf 'FAIL %s: exit %s, expected %s; output: %s\n' "$mode" "$rc" "$want" "$out" >&2
        exit 1
    fi
    echo "pass $mode"
}
check pass 0 'image_pass=1 inspection_failed=0' --strict
check pass 0 'PASS verify-factory-image-signatures/verify-image Deployment/model-gateway 2025-11-18T12:00:00Z'
check delimiter 0 'image_pass=1' --strict
check cache 1 'image_pass=0' --strict
check cache-pod 0 'image_pass=1' --strict
check cache-rs 0 'image_pass=1' --strict
check pod-unowned 1 'image_pass=0' --strict
check pod-old-deploy 1 'image_pass=0' --strict
check pod-wrong-policy 1 'image_pass=0' --strict
check pod-fail 1 'image_pass=0' --strict
check pod-suffix 1 'image_pass=0' --strict
check pod-no-uid 1 'image_pass=0' --strict
check fail 1 'fail=1 error=0 image_pass=0' --strict
check fail 0 'fail=1 error=0 image_pass=0'
check error 1 'fail=0 error=1 image_pass=0' --strict
check prefix 1 'image_pass=0' --strict
check embedded 1 'image_pass=0' --strict
check wrong-resource 1 'image_pass=0' --strict
check wrong-uid 1 'image_pass=0' --strict
check missing-uid 1 'image_pass=0' --strict
check empty-image 1 'image= pass=1' --strict
check other-policy 1 'image_pass=0' --strict
check skip 1 'SKIP verify-factory-image-signatures/verify-image' --strict
check malformed 0 'INSPECTION-FAIL invalid report data'
check malformed 1 'inspection_failed=1' --strict
check not-list 1 'INSPECTION-FAIL invalid report data' --strict
KUBECTL_FAIL=reports check pass 0 'INSPECTION-FAIL PolicyReports fetch failed'
KUBECTL_FAIL=deploy check pass 1 'INSPECTION-FAIL Deployment fetch failed' --strict
KUBECTL_FAIL=children check pass 1 'INSPECTION-FAIL children fetch failed' --strict
RUN_PATH="$work/nojq" check pass 0 'INSPECTION-FAIL jq unavailable'
RUN_PATH="$work/nojq" check pass 1 'inspection_failed=1' --strict
echo 'verify-gateway-policyreport tests passed'
