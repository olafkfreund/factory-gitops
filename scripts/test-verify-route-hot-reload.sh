#!/usr/bin/env bash
# Cluster-free tests for verify-route-hot-reload.sh; only throwaway routes.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'KUBE'
#!/bin/bash
case "$*" in
    '--context k3d-factory get pods -n gateway -l app=model-gateway -o json')
        phase=$(cat "$FIXTURES/phase" 2>/dev/null || printf 0)
        phase=$((phase + 1))
        printf '%s' "$phase" > "$FIXTURES/phase"
        if ((phase == 1)); then cat "$FIXTURES/pods-1.json"; else cat "$FIXTURES/pods-2.json"; fi
        exit ;;
    '--context k3d-factory exec -n gateway pod-a -c model-gateway -- python3 -c import sys;sys.stdout.write(open("/etc/model-routes/routes.json").read())') pod=pod-a ;;
    '--context k3d-factory exec -n gateway pod-b -c model-gateway -- python3 -c import sys;sys.stdout.write(open("/etc/model-routes/routes.json").read())') pod=pod-b ;;
    '--context k3d-factory get configmap model-routes -n gateway -o json') cat "$FIXTURES/cm.json"; exit ;;
    *) exit 97 ;;
esac
phase=$(cat "$FIXTURES/phase")
[[ ${SCENARIO:-} == record-exec-fail && $phase == 1 ]] && exit 97
[[ ${SCENARIO:-} == exec-fail-check && $phase == 2 ]] && exit 97
if ((phase == 1)) || [[ ${SCENARIO:-} == no-change ]]; then
    cat "$FIXTURES/old.routes"
elif [[ ${SCENARIO:-} == divergent && $pod == pod-b ]]; then
    cat "$FIXTURES/old.routes"
else
    cat "$FIXTURES/new.routes"
fi
KUBE
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH" FIXTURES="$work" POLL_SECONDS=0
cat > "$work/fixtures.py" <<'PY'
import json, os, sys
base, scenario = os.environ['FIXTURES'], sys.argv[1]
old = '{"cheap":"throwaway-old"}\n'
new = '{"cheap":"throwaway-new"}\n'
for name, content in [('old.routes', old), ('new.routes', new)]:
    with open(f'{base}/{name}', 'w') as file: file.write(content)

def pod(name):
    return {'metadata': {'name': name, 'uid': f'uid-{name}'},
            'status': {'phase': 'Running', 'containerStatuses': [{'restartCount': 0}]}}
first = [pod('pod-a'), pod('pod-b')]
second = [pod('pod-a'), pod('pod-b')]
if scenario == 'missing': second.pop()
elif scenario == 'uid-change': second[0]['metadata']['uid'] = 'replacement-uid'
elif scenario == 'restart': second[0]['status']['containerStatuses'][0]['restartCount'] = 1
for phase, pods in [(1, first), (2, second)]:
    with open(f'{base}/pods-{phase}.json', 'w') as file: json.dump({'items': pods}, file)
with open(f'{base}/cm.json', 'w') as file: json.dump({'data': {'routes.json': new}}, file)
PY
check() { # scenario expected-check-exit expected-text
    local scenario=$1 want=$2 pattern=$3 rc=0 out
    python3 "$work/fixtures.py" "$scenario"
    rm -f "$work/phase" "$work/state.json"
    if [[ $scenario == record-exec-fail ]]; then
        out=$(SCENARIO="$scenario" bash "$here/verify-route-hot-reload.sh" record "$work/state.json" 2>&1) || rc=$?
        [[ $rc == 1 && ! -e $work/state.json && $out == *"$pattern"* ]] || { echo "FAIL $scenario: $rc $out" >&2; exit 1; }
    else
        out=$(SCENARIO="$scenario" bash "$here/verify-route-hot-reload.sh" record "$work/state.json" 2>&1) || { echo "FAIL $scenario record: $out" >&2; exit 1; }
        [[ -s $work/state.json ]] || { echo "FAIL $scenario empty state" >&2; exit 1; }
        rc=0
        out=$(SCENARIO="$scenario" bash "$here/verify-route-hot-reload.sh" check "$work/state.json" 0 2>&1) || rc=$?
        [[ $rc == "$want" && $out == *"$pattern"* ]] || { echo "FAIL $scenario: exit $rc, output $out" >&2; exit 1; }
    fi
    echo "pass $scenario"
}
check converged 0 'cheap: throwaway-old -> throwaway-new'
check no-change 1 'routes did not change'
check exec-fail-check 1 'exec failed'
check divergent 1 'divergent routes'
check missing 1 'missing pod'
check restart 1 'restart count changed'
check uid-change 1 'UID changed'
check record-exec-fail 1 'exec failed'
echo 'verify-route-hot-reload tests passed'
