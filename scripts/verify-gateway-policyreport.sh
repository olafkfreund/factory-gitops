#!/usr/bin/env bash
# Report Kyverno admission results for the current model-gateway image.
set +x
set -u

strict=0
if (($#)); then
    [[ $# == 1 && $1 == --strict ]] || { echo "usage: $0 [--strict]" >&2; exit 2; }
    strict=1
fi

inspection_fail() {
    echo "INSPECTION-FAIL $1"
    echo 'SUMMARY image= pass=0 fail=0 error=0 image_pass=0 inspection_failed=1'
    if ((strict)); then exit 1; else exit 0; fi
}

command -v kubectl >/dev/null 2>&1 || inspection_fail 'kubectl unavailable'
command -v jq >/dev/null 2>&1 || inspection_fail 'jq unavailable'
work=$(mktemp -d) || inspection_fail 'cannot create temporary directory'
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
kubectl --context "${KUBE_CONTEXT:-k3d-factory}" -n gateway get deploy model-gateway -o json > "$work/deploy.json" 2>/dev/null || inspection_fail 'Deployment fetch failed'
kubectl --context "${KUBE_CONTEXT:-k3d-factory}" -n gateway get policyreport -o json > "$work/reports.json" 2>/dev/null || inspection_fail 'PolicyReports fetch failed'

if ! jq -r -n --slurpfile deployment "$work/deploy.json" --slurpfile reports "$work/reports.json" '
    def image_token($message; $image):
        any(range(0; ($message | length) - ($image | length) + 1) as $i |
            $message[$i:$i + ($image | length)] == $image and
            ($i == 0 or ($message[$i - 1:$i] | test("[^A-Za-z0-9._/:-]"))) and
            ($i + ($image | length) == ($message | length) or
                ($message[$i + ($image | length):$i + ($image | length) + 1] | test("[^A-Za-z0-9._-]"))));
    if ($deployment | length) != 1 or ($reports | length) != 1 or
       ($deployment[0] | type) != "object" or ($reports[0].items | type) != "array" or
       ($deployment[0].spec.template.spec.containers | type) != "array" or
       ($reports[0].items | any((.results | type) != "array")) then
        error("invalid report data")
    else
        ($deployment[0].spec.template.spec.containers | map(select(.name == "model-gateway") | .image) | first // "") as $image |
        $deployment[0].metadata.uid as $uid |
        [$reports[0].items[] | . as $report | .results[] | {scope: $report.scope, row: .}] as $rows |
        if ($rows | any((.row.result | type) != "string" or (.row.policy | type) != "string" or
                        (.row.rule | type) != "string" or (.row.timestamp.seconds | type) != "number")) then
            error("invalid report row")
        else
            ($rows[] | "\(.row.result | ascii_upcase) \(.row.policy)/\(.row.rule) \(.scope.kind)/\(.scope.name) \(.row.timestamp.seconds | todate)"),
            "SUMMARY image=\($image) pass=\([$rows[] | select(.row.result == "pass")] | length) fail=\([$rows[] | select(.row.result == "fail")] | length) error=\([$rows[] | select(.row.result == "error")] | length) image_pass=\(if $image != "" and ($uid | type) == "string" and $uid != "" and ($rows | any(.scope.kind == "Deployment" and .scope.name == "model-gateway" and .scope.uid == $uid and .row.policy == "verify-factory-image-signatures" and .row.result == "pass" and (.row.message | type) == "string" and image_token(.row.message; $image))) then 1 else 0 end) inspection_failed=0"
        end
    end
    ' > "$work/results" 2>/dev/null; then
    inspection_fail 'invalid report data'
fi

cat "$work/results"
if ((strict)) && [[ $(tail -n 1 "$work/results") != *'fail=0 error=0 image_pass=1 inspection_failed=0' ]]; then exit 1; fi
