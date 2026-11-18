#!/usr/bin/env bash
# Cluster-free guard (Factory#1959): the client Deployments keep their optional gateway Secret refs and the
# task-Job egress policy keeps its one gateway peer on TCP 8080. Needs kustomize, yq (mikefarah) and jq.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

render() { for d in "$@"; do kustomize build "$d"; echo ---; done | yq -o=json -I0 '.' | jq -s '.'; }
render apps/aifactory/manifests apps/tfactory/manifests apps/cfactory/manifests apps/factory-namespace/manifests > "$work/all.json"

check() { # file; prints problems, one per line
    jq -r '
    def ref($d; $n; $key): [$d.spec.template.spec.containers[].env[]? | select(.name == $n)] as $e |
        if ($e | length) != 1 then "\($d.metadata.name): \($n) missing or duplicated"
        elif $e[0].valueFrom.secretKeyRef.name != "factory-secrets" or $e[0].valueFrom.secretKeyRef.key != $key
            or $e[0].valueFrom.secretKeyRef.optional != true then "\($d.metadata.name): \($n) not an optional factory-secrets/\($key) ref"
        else empty end;
    (.[] | select(.kind == "Deployment" and (.metadata.name | IN("aifactory", "tfactory", "cfactory"))) | . as $d |
        ($d.metadata.name | ascii_upcase) as $s |
        ref($d; "\($s)_MODEL_GATEWAY_URL"; "MODEL_GATEWAY_URL"),
        ref($d; "\($s)_MODEL_GATEWAY_TOKEN"; "MODEL_GATEWAY_CLIENT_TOKEN")),
    ([.[] | select(.kind == "Deployment" and (.metadata.name | IN("aifactory", "tfactory", "cfactory")))] | length | if . == 3 then empty else "expected 3 client Deployments, got \(.)" end),
    ([.[] | select(.kind == "NetworkPolicy" and .metadata.name == "factory-sandbox-jobs-egress")] | if length != 1 then "factory-sandbox-jobs-egress missing" else .[0] |
        (if .spec.podSelector.matchLabels["factory.io/kind"] != "task" then "policy does not select factory.io/kind=task" else empty end),
        ([.spec.egress[]? | select(any(.to[]?; .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "gateway"))] | 
            if length != 1 then "expected exactly one gateway egress rule"
            else .[0] | if (.to | length) != 1 or .to[0].podSelector.matchLabels.app != "model-gateway"
                    or (.ports | length) != 1 or .ports[0].port != 8080 or .ports[0].protocol != "TCP"
                 then "gateway egress rule must be one peer (namespace + app=model-gateway) on TCP 8080 only" else empty end end) end)
    ' "$1"
}

problems=$(check "$work/all.json")
[[ -z $problems ]] || { echo "FAIL wiring:" >&2; echo "$problems" >&2; exit 1; }
echo "pass wiring"

# Negative self-checks: each mutation must be caught.
mutate() { # name jq-filter
    jq "$2" "$work/all.json" > "$work/mut.json"
    [[ -n $(check "$work/mut.json") ]] || { echo "FAIL $1: mutation not detected" >&2; exit 1; }
    echo "pass $1"
}
mutate not-optional '(.[] | select(.metadata.name == "tfactory" and .kind == "Deployment") | .spec.template.spec.containers[].env[]? | select(.name == "TFACTORY_MODEL_GATEWAY_URL") | .valueFrom.secretKeyRef.optional) = false'
mutate literal-url '(.[] | select(.metadata.name == "cfactory" and .kind == "Deployment") | .spec.template.spec.containers[].env[]? | select(.name == "CFACTORY_MODEL_GATEWAY_URL")) |= {name, value: "http://x"}'
mutate wrong-key '(.[] | select(.metadata.name == "aifactory" and .kind == "Deployment") | .spec.template.spec.containers[].env[]? | select(.name == "AIFACTORY_MODEL_GATEWAY_TOKEN") | .valueFrom.secretKeyRef.key) = "OTHER"'
mutate port '(.[] | select(.kind == "NetworkPolicy") | .spec.egress[]? | select(any(.to[]?; .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "gateway")) | .ports[0].port) = 9090'
mutate split-peer '(.[] | select(.kind == "NetworkPolicy") | .spec.egress[]? | select(any(.to[]?; .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "gateway")) | .to) |= [{namespaceSelector: .[0].namespaceSelector}, {podSelector: .[0].podSelector}]'
echo 'gateway wiring tests passed'
