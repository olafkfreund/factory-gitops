#!/usr/bin/env bash
# Cluster-free guard (Factory#1959): client Deployments, task-Job egress and gateway defaults
# keep their intended wiring. Needs kustomize, yq (mikefarah) and jq.
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

render apps/model-gateway/manifests > "$work/gateway.json"
check_gateway() { # file; prints problems, one per line
    jq -r '
    def env($d; $n): [$d.spec.template.spec.containers[] | select(.name == "model-gateway") | .env[]? | select(.name == $n)];
    ([.[] | select(.kind == "Deployment" and .metadata.name == "model-gateway" and .metadata.namespace == "gateway")] | if length != 1 then "model-gateway Deployment missing or duplicated" else .[0] as $d |
        (env($d; "GATEWAY_METRICS") | if length != 1 or .[0] != {name: "GATEWAY_METRICS", value: "off"} then "GATEWAY_METRICS must be literal off" else empty end),
        ("GATEWAY_OTLP_ENDPOINT", "GATEWAY_OTLP_HEADERS", "GATEWAY_UPSTREAM2_API_KEY") as $n |
            (env($d; $n) | if length != 1 then "\($n) missing or duplicated"
                elif .[0] != {name: $n, valueFrom: {secretKeyRef: {name: "model-gateway-secrets", key: $n, optional: true}}}
                then "\($n) must be an optional model-gateway-secrets/\($n) ref without a literal value" else empty end),
        ([$d.spec.template.spec.containers[] | select(.name == "model-gateway") | .env[]? | select(.name | test("(_API_KEY|TOKEN)$")) | select(.valueFrom.secretKeyRef.optional != true) | .name][] | "\(.) must be optional") end),
    ([.[] | select(.kind == "ConfigMap" and .metadata.name == "model-routes" and .metadata.namespace == "gateway")] | if length != 1 then "model-routes ConfigMap missing or duplicated" else
        (try (.[0].data["routes.json"] | fromjson) catch null) | if type != "object" or any(.[]; type != "string") then "model-routes routes.json must contain string routes only" else empty end end),
    ([.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress")] | if length != 1 then "allow-otlp-egress missing or duplicated" else .[0] |
        (if .metadata.namespace != "gateway" then "allow-otlp-egress must be in gateway" else empty end),
        (if .spec.podSelector != {matchLabels: {app: "model-gateway"}} then "allow-otlp-egress must select app=model-gateway" else empty end),
        (if .spec.policyTypes != ["Egress"] then "allow-otlp-egress policyTypes must be Egress only" else empty end),
        (if .spec.egress != [{to: [{namespaceSelector: {matchLabels: {"kubernetes.io/metadata.name": "factory"}}, podSelector: {matchLabels: {app: "observe"}}}], ports: [{protocol: "TCP", port: 5080}]}]
         then "allow-otlp-egress must have one peer (factory namespace and app=observe) on TCP 5080 only" else empty end) end)
    ' "$1"
}

problems=$(check_gateway "$work/gateway.json")
[[ -z $problems ]] || { echo "FAIL gateway wiring:" >&2; echo "$problems" >&2; exit 1; }
echo "pass gateway wiring"

gateway_mutate() { # name jq-filter
    jq "$2" "$work/gateway.json" > "$work/gateway-mut.json"
    [[ -n $(check_gateway "$work/gateway-mut.json") ]] || { echo "FAIL $1: mutation not detected" >&2; exit 1; }
    echo "pass $1"
}
gateway_mutate metrics-on '(.[] | select(.kind == "Deployment" and .metadata.name == "model-gateway") | .spec.template.spec.containers[].env[] | select(.name == "GATEWAY_METRICS") | .value) = "on"'
gateway_mutate missing-otlp '(.[] | select(.kind == "Deployment" and .metadata.name == "model-gateway") | .spec.template.spec.containers[].env) |= map(select(.name != "GATEWAY_OTLP_ENDPOINT"))'
gateway_mutate duplicate-otlp '(.[] | select(.kind == "Deployment" and .metadata.name == "model-gateway") | .spec.template.spec.containers[].env) |= . + [(.[] | select(.name == "GATEWAY_OTLP_HEADERS"))]'
gateway_mutate literal-otlp '(.[] | select(.kind == "Deployment" and .metadata.name == "model-gateway") | .spec.template.spec.containers[].env[] | select(.name == "GATEWAY_OTLP_ENDPOINT")) |= {name, value: "http://example.invalid"}'
gateway_mutate nonoptional-otlp '(.[] | select(.kind == "Deployment" and .metadata.name == "model-gateway") | .spec.template.spec.containers[].env[] | select(.name == "GATEWAY_OTLP_HEADERS") | .valueFrom.secretKeyRef.optional) = false'
gateway_mutate wrong-secret '(.[] | select(.kind == "Deployment" and .metadata.name == "model-gateway") | .spec.template.spec.containers[].env[] | select(.name == "GATEWAY_UPSTREAM2_API_KEY") | .valueFrom.secretKeyRef.name) = "other"'
gateway_mutate wrong-key '(.[] | select(.kind == "Deployment" and .metadata.name == "model-gateway") | .spec.template.spec.containers[].env[] | select(.name == "GATEWAY_UPSTREAM2_API_KEY") | .valueFrom.secretKeyRef.key) = "OTHER"'
gateway_mutate nonoptional-client-token '(.[] | select(.kind == "Deployment" and .metadata.name == "model-gateway") | .spec.template.spec.containers[].env[] | select(.name == "GATEWAY_CLIENT_TOKEN") | .valueFrom.secretKeyRef.optional) = false'
gateway_mutate object-route '(.[] | select(.kind == "ConfigMap" and .metadata.name == "model-routes") | .data["routes.json"]) |= (fromjson | .balanced = {model: "example", quota: {requests: 1}} | tojson)'
gateway_mutate wrong-source-selector '(.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress") | .spec.podSelector.matchLabels.app) = "other"'
gateway_mutate wrong-policy-types '(.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress") | .spec.policyTypes) = ["Ingress", "Egress"]'
gateway_mutate wrong-namespace '(.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress") | .spec.egress[0].to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]) = "other"'
gateway_mutate wrong-destination '(.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress") | .spec.egress[0].to[0].podSelector.matchLabels.app) = "other"'
gateway_mutate wrong-port '(.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress") | .spec.egress[0].ports[0].port) = 9090'
gateway_mutate wrong-protocol '(.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress") | .spec.egress[0].ports[0].protocol) = "UDP"'
gateway_mutate split-otlp-peer '(.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress") | .spec.egress[0].to) |= [{namespaceSelector: .[0].namespaceSelector}, {podSelector: .[0].podSelector}]'
gateway_mutate extra-otlp-rule '(.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress") | .spec.egress) |= . + [.[0]]'
gateway_mutate duplicate-otlp-policy '. += [(.[] | select(.kind == "NetworkPolicy" and .metadata.name == "allow-otlp-egress"))]'
echo 'gateway wiring tests passed'
