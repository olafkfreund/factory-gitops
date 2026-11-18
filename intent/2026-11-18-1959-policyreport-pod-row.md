---
status: draft
issue: 1959
author: olafkfreund
---

# Intent: verify-gateway-policyreport accepts the image on the Pod or ReplicaSet row

## Problem

`scripts/verify-gateway-policyreport.sh --strict` exits 1 with `image_pass=0`
even when Kyverno verified the current model-gateway image. Kyverno now writes
the Deployment row message as `verified from cache`, which does not name the
image, and the script only counts a Deployment row that names it (finding in
the Factory#1958 comment of 2026-11-18 20:40 UTC). The existing test pins the
cache message as a failure.

## Proposed outcome

`image_pass=1` when the Deployment row passes with the image token, or when a
passing row on a Pod or ReplicaSet of the same Deployment names the image.
A cache-only Deployment row with no such Pod/ReplicaSet row still fails.

## Affected users and systems

Gateway admission proof (Factory#1959 AC-1), the CI report-only step that runs
this script, `scripts/test-verify-gateway-policyreport.sh`. No cluster change.

## Constraints

Must keep strict mode fail-closed and the image-token boundary rules. Must not
accept another Deployment's rows. No live-cluster action.

## Open questions

None. Decision (owner delegation 2026-11-18): accept the Pod/ReplicaSet row,
as the finding recommends; it is the least invasive fix.
