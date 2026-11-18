---
status: draft
issue: 1959
intent: intent/2026-11-18-1959-policyreport-pod-row.md
---

# Spec: image proof from Pod or ReplicaSet rows

## Design

The script makes one more read, `kubectl -n gateway get replicaset,pod -o json`,
and in jq computes the set of owned uids: ReplicaSets whose ownerReference is
the current Deployment uid (kind Deployment), plus Pods owned by one of those
ReplicaSets. The `image_pass` predicate keeps its policy, `pass`, string
message and `image_token` checks, and widens only the scope test to: the
Deployment row (unchanged), or kind `Pod`/`ReplicaSet` with `scope.uid` in the
owned set. Ownership is by uid, never by name. A failed fetch or non-list
`items` is an inspection failure, like the other fetches.

## Alternatives rejected

- Match by name pattern: Codex review showed `Pod/model-gateway-evil` and old
  Deployment children would pass; names do not prove ownership.
- Drop the image check when the message is `verified from cache`: passes
  without proving which image was verified.

## Risks

One more kubectl read (read-only, same namespace). If Kyverno omits `scope.uid`
on child rows, they simply do not count and strict still fails closed.

## Verification

`bash scripts/test-verify-gateway-policyreport.sh` with new fixtures (child
rows are separate report items with their own scope): cache message on
Deployment only (1); plus an owned Pod row naming the image (0); plus an owned
ReplicaSet row (0); unowned Pod named `model-gateway-evil` (1); child of an old
Deployment uid (1); owned child with wrong policy, non-pass result, image suffix
or missing uid (1); children fetch failure (inspection fail).
