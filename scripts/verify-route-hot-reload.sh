#!/usr/bin/env bash
# Verify model-routes propagation without mistaking a pod restart for hot reload.
set +x
set -u

usage() { echo "usage: $0 record STATE_FILE | check STATE_FILE [TIMEOUT_SECONDS=180]" >&2; exit 2; }
fail() { echo "FAIL $1" >&2; exit 1; }
(($# >= 2)) || usage
mode=$1
state=$2
case $mode in
    record) (($# == 2)) || usage ;;
    check) (($# <= 3)) || usage ;;
    *) usage ;;
esac
timeout=${3:-180}
poll=${POLL_SECONDS:-10}
[[ $timeout =~ ^[0-9]+$ && $poll =~ ^[0-9]+$ ]] || usage
command -v kubectl >/dev/null 2>&1 || fail 'kubectl unavailable'
command -v jq >/dev/null 2>&1 || fail 'jq unavailable'
context=${KUBE_CONTEXT:-k3d-factory}
work=$(mktemp -d) || fail 'cannot create temporary directory'
state_tmp=
trap 'rm -rf "$work"; if [[ -n $state_tmp ]]; then rm -f "$state_tmp"; fi' EXIT

collect() {
    kubectl --context "$context" get pods -n gateway -l app=model-gateway -o json > "$work/list.json" 2>/dev/null || fail 'pod listing failed'
    jq -e '.items | type == "array" and length > 0 and all(.[]; .status.phase == "Running" and (.metadata.name | type == "string") and (.metadata.uid | type == "string") and (.status.containerStatuses[0].restartCount | type == "number"))' "$work/list.json" >/dev/null 2>&1 || fail 'no usable Running pod list'
    jq -r '.items[] | [.metadata.name, .metadata.uid, .status.containerStatuses[0].restartCount] | @tsv' "$work/list.json" > "$work/list.tsv" || fail 'invalid pod list'
    : > "$work/pods.ndjson"
    while IFS=$'\t' read -r name uid restarts; do
        kubectl --context "$context" exec -n gateway "$name" -c model-gateway -- python3 -c 'import sys;sys.stdout.write(open("/etc/model-routes/routes.json").read())' > "$work/routes.json" 2>/dev/null || fail "exec failed for $name"
        jq -e 'type == "object" and all(.[]; type == "string")' "$work/routes.json" >/dev/null 2>&1 || fail "invalid routes for $name"
        jq -cn --arg name "$name" --arg uid "$uid" --argjson restartCount "$restarts" --rawfile routes "$work/routes.json" \
            '{name: $name, uid: $uid, restartCount: $restartCount, routes: $routes}' >> "$work/pods.ndjson" || fail 'cannot record pod'
    done < "$work/list.tsv"
    jq -s '{pods: .}' "$work/pods.ndjson" > "$work/current.json" || fail 'cannot record pods'
}

if [[ $mode == record ]]; then
    collect
    state_tmp=$(mktemp -- "${state}.XXXXXX") || fail 'cannot create state file'
    cat "$work/current.json" > "$state_tmp" || fail 'cannot write state file'
    mv -- "$state_tmp" "$state" || fail 'cannot save state file'
    state_tmp=
    echo "Recorded routes in $state:"
    jq -r '.pods[] | .name as $pod | .routes | fromjson | to_entries[] | "\($pod) \(.key)=\(.value)"' "$state"
    echo 'Change apps/model-gateway/route-overrides.json in a PR and let Argo sync, then run check.'
    exit 0
fi

jq -e '.pods | type == "array" and length > 0 and all(.[]; (.name | type == "string") and (.uid | type == "string") and (.restartCount | type == "number") and (.routes | fromjson | type == "object"))' "$state" >/dev/null 2>&1 || fail 'invalid state file'
start=$SECONDS
while :; do
    collect
    kubectl --context "$context" get configmap model-routes -n gateway -o json > "$work/configmap.json" 2>/dev/null || fail 'ConfigMap fetch failed'
    jq -e '.data["routes.json"] | type == "string"' "$work/configmap.json" >/dev/null 2>&1 || fail 'ConfigMap has no routes.json'
    result=$(jq -nr --slurpfile old "$state" --slurpfile now "$work/current.json" --slurpfile cm "$work/configmap.json" '
        $old[0].pods as $before | $now[0].pods as $after |
        [$before[] | . as $pod | ($after | map(select(.name == $pod.name)) | first) as $current |
            if $current == null then "missing pod " + $pod.name
            elif $current.uid != $pod.uid then "UID changed for " + $pod.name
            elif $current.restartCount != $pod.restartCount then "restart count changed for " + $pod.name
            else empty end] as $failed |
        if ($failed | length) > 0 then $failed[0]
        elif ($after | map(.routes) | unique | length) != 1 then "pods have divergent routes"
        elif $after[0].routes == $cm[0].data["routes.json"] and
             ([$before[] | .routes != $after[0].routes] | all) then "success"
        elif ([$before[] | .routes == $after[0].routes] | any) then "routes did not change"
        else "pod routes differ from ConfigMap" end
    ') || fail 'cannot compare routes'
    if [[ $result == success ]]; then
        jq -nr --slurpfile old "$state" --slurpfile now "$work/current.json" '
            ($old[0].pods[0].routes | fromjson) as $before |
            ($now[0].pods[0].routes | fromjson) as $after |
            (($before + $after) | keys[]) as $class |
            "\($class): \($before[$class] // "<absent>") -> \($after[$class] // "<absent>")"
        '
        echo 'Hot reload verified: pod UIDs and restart counts stayed unchanged.'
        exit 0
    fi
    if ((SECONDS - start >= timeout)); then fail "$result within ${timeout}s"; fi
    sleep "$poll"
done
