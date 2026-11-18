#!/usr/bin/env bash
# Report model-provider credentials in Factory workload specs (Factory#1959).
set +x
set -u

usage() { echo "usage: $0 [--strict] [--accept-volume NAME]... [--gateway-token-file FILE] [--deployments-json FILE]" >&2; exit 2; }
strict=0
static=0
token_file=
deployments_json=
accepted=()
while (($#)); do
    case $1 in
        --strict) strict=1; shift ;;
        --accept-volume)
            (($# >= 2)) && [[ -n $2 ]] || usage
            accepted+=("$2"); shift 2 ;;
        --gateway-token-file)
            (($# >= 2)) && [[ -n $2 ]] || usage
            token_file=$2; shift 2 ;;
        --deployments-json)
            (($# >= 2)) && [[ -n $2 ]] || usage
            deployments_json=$2; static=1; shift 2 ;;
        *) usage ;;
    esac
done

token=
if [[ -n $token_file ]]; then
    IFS= read -r token < "$token_file" 2>/dev/null || [[ -n $token ]] || usage
    [[ -n $token ]] || usage
fi

inspection_fail() {
    echo "INSPECTION-FAIL $1"
    echo "SUMMARY VIOLATION=0 UNVERIFIED=0 GATEWAY-REF=0 ACCEPTED=0 deployments=0 jobs=0 inspection_failed=1 static=$static"
    if ((strict)); then exit 1; else exit 0; fi
}
if (( ! static )); then command -v kubectl >/dev/null 2>&1 || inspection_fail 'kubectl unavailable'; fi
command -v jq >/dev/null 2>&1 || inspection_fail 'jq unavailable'

work=$(mktemp -d) || inspection_fail 'cannot create temporary directory'
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
if ((static)); then
    cp -- "$deployments_json" "$work/deploy.json" 2>/dev/null || inspection_fail 'Deployments file unreadable'
    printf '{"items":[]}\n' > "$work/jobs.json"
else
    kubectl --context "${KUBE_CONTEXT:-k3d-factory}" -n factory get deploy aifactory pfactory tfactory cfactory -o json > "$work/deploy.json" 2>/dev/null || inspection_fail 'Deployments fetch failed'
    kubectl --context "${KUBE_CONTEXT:-k3d-factory}" -n factory get jobs -l factory.io/kind -o json > "$work/jobs.json" 2>/dev/null || inspection_fail 'Jobs fetch failed'
fi
accept_json=$(jq -cn '$ARGS.positional' --args "${accepted[@]}") || inspection_fail 'jq unavailable'

# Keep token out of argv and output; jq sees it only in its process environment.
if ! GATEWAY_TOKEN="$token" jq -r -n \
    --slurpfile deployments "$work/deploy.json" \
    --slurpfile jobs "$work/jobs.json" \
    --argjson accepted "$accept_json" --argjson static "$static" '
    def key_name: IN("OPENAI_API_KEY", "OPENAI_COMPATIBLE_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "OLLAMA_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN");
    def finding($class; $workload; $container; $name): {class: $class, workload: $workload, container: $container, name: $name};
    def source_name: .secretRef.name // .configMapRef.name // "unknown";
    def volume_secrets:
        [(.secret.secretName // empty), (.projected.sources[]?.secret.name // empty)];
    def scan($kind):
        . as $item | ($kind + "/" + .metadata.name) as $workload |
        [(.spec.template.spec.containers // [])[], (.spec.template.spec.initContainers // [])[]] as $containers |
        [ $containers[] | .name as $container |
            (.env // [])[] | select(.name | key_name) |
            finding(
                if .valueFrom.secretKeyRef? then
                    if .valueFrom.secretKeyRef.name == "factory-secrets" and .valueFrom.secretKeyRef.key == "MODEL_GATEWAY_CLIENT_TOKEN" then "GATEWAY-REF" else "VIOLATION" end
                elif .valueFrom.configMapKeyRef? then "VIOLATION"
                elif has("value") then
                    if (env.GATEWAY_TOKEN // "") == "" then "UNVERIFIED"
                    elif .value == env.GATEWAY_TOKEN then "GATEWAY-REF"
                    else "VIOLATION" end
                else "UNVERIFIED" end;
                $workload; $container; .name)
        ] +
        [ $containers[] | .name as $container | (.envFrom // [])[] |
            finding("UNVERIFIED"; $workload; $container; source_name)
        ] +
        [ ($item.spec.template.spec.volumes // [])[] | . as $volume |
            [volume_secrets[] | select(contains("cli-creds"))] as $secrets |
            $secrets[] | finding(
                if ($accepted | index($volume.name)) != null then "ACCEPTED" else "VIOLATION" end;
                $workload; $volume.name; .)
        ];
    if ($deployments | length) != 1 or ($jobs | length) != 1 or
       ($deployments[0].items | type) != "array" or ($jobs[0].items | type) != "array" then
        error("invalid workload lists")
    else
        $deployments[0].items as $ds | $jobs[0].items as $js |
        if (["aifactory", "pfactory", "tfactory", "cfactory"] | all(. as $name | [$ds[].metadata.name] | index($name) != null)) | not then
            error("missing Deployment")
        elif $static == 0 and ($js | length) == 0 then error("no Jobs")
        else
            (($ds | map(scan("Deployment")) | add // []) + ($js | map(scan("Job")) | add // [])) as $findings |
            ($findings[] | "\(.class) \(.workload) \(.container) \(.name)"),
            "SUMMARY VIOLATION=\([$findings[] | select(.class == "VIOLATION")] | length) UNVERIFIED=\([$findings[] | select(.class == "UNVERIFIED")] | length) GATEWAY-REF=\([$findings[] | select(.class == "GATEWAY-REF")] | length) ACCEPTED=\([$findings[] | select(.class == "ACCEPTED")] | length) deployments=\($ds | length) jobs=\($js | length) inspection_failed=0 static=\($static)",
            (if ($findings | any(.class == "VIOLATION" or .class == "UNVERIFIED")) then "STRICT-FAIL" else "STRICT-PASS" end)
        end
    end
    ' > "$work/results" 2>/dev/null; then
    inspection_fail 'invalid workload data'
fi

result=$(tail -n 1 "$work/results")
sed '$d' "$work/results"
if ((strict)) && [[ $result == STRICT-FAIL ]]; then exit 1; fi
