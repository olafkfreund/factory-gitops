---
status: approved
issue: 1959
spec: spec/2026-11-18-1959-policyreport-pod-row.md
coders:
  1: codex   # small tricky jq logic
  2: codex   # contained fixture/test edit
reviewers:
  - codex
---

# Plan: image proof from Pod or ReplicaSet rows

Approved decisions (from the spec): `image_pass=1` also when a passing
`verify-factory-image-signatures` row naming the image is scoped to a Pod or
ReplicaSet whose uid is owned by the current Deployment (ReplicaSet ownerRef
uid == Deployment uid; Pod ownerRef uid in those ReplicaSets). Ownership by
uid, not name. Deployment rule unchanged.

## Steps

1. `scripts/verify-gateway-policyreport.sh`: add a third fetch
   `kubectl --context "${KUBE_CONTEXT:-k3d-factory}" -n gateway get replicaset,pod -o json > "$work/children.json" 2>/dev/null || inspection_fail 'children fetch failed'`
   after the reports fetch; add `--slurpfile children "$work/children.json"`;
   extend the validity guard (`$children[0].items` must be an array); define
   `$owned` = uids of RS with `.metadata.ownerReferences[]? | select(.kind=="Deployment" and .uid==$uid)`
   plus uids of Pods owned by those RS uids; in the `image_pass` scope clause use
   `((.scope.kind == "Deployment" and name/uid as today) or ((.scope.kind == "Pod" or .scope.kind == "ReplicaSet") and (.scope.uid | type) == "string" and ($owned | index(.scope.uid)) != null))`.
   -> `bash -n`, then step 2 tests.
   Traps: keep `$uid` non-empty guard; missing ownerReferences must not error; do not widen the `pass`/policy/image_token checks.
2. `scripts/test-verify-gateway-policyreport.sh`: the kubectl stub must serve
   `get replicaset,pod -o json` from `children.json` (and honour
   `KUBECTL_FAIL=children`); `fixtures.py` writes a default children file (owned RS
   `rs-uid`, owned Pod `pod-uid`) and new modes `cache-pod`, `cache-rs` (Deployment
   row `verified from cache` plus a separate report item for the child naming the
   image), `pod-unowned`, `pod-old-deploy`, `pod-wrong-policy`, `pod-fail`,
   `pod-suffix`, `pod-no-uid`; add `check` lines per the spec (`--strict`);
   keep `cache` at exit 1 and add the children fetch-failure check.
   -> `bash scripts/test-verify-gateway-policyreport.sh`.
   Traps: harness fails on output containing `verified image signatures`; scope
   is read from the enclosing report item, so a child row needs its own item.

## Tests

`bash scripts/test-verify-gateway-policyreport.sh` prints all `pass` lines and
`tests passed`. Also `shellcheck` on both scripts if installed.

## Rollback

Revert the PR; the script returns to the Deployment-row-only rule.
