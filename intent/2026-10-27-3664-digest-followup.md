---
status: draft
issue: 3664
repo-issue: olafkfreund/Factory#3664
author: olafkfreund
---

# Intent: follow-ups to the digest-reference admission fix (#316)

## Problem

1. Since #316, digest-pinned first-party Pods (sandbox, gate and TFactory job
   Pods on `factory-runner-nix@e2e4…`) can only start if ghcr.io and Sigstore
   are reachable at admission. An uncovered image also fails at Pod creation,
   not at Argo sync. The runbook says neither.
2. `AIFACTORY_IMAGE` is pinned to `aifactory:sha-ccbd0ce`, which has no
   signature. Only the build-image fallback reads it, and the live
   `AIFACTORY_BUILD_IMAGE` takes precedence. But unsetting that override would
   make every build Job be denied by `verify-aifactory-signature`.

## Proposed outcome

The runbook and PANIC.sh name both failure modes and the signals to watch.
`AIFACTORY_IMAGE` is a signed image that passes verify in a server-side dry-run.

## Affected users and systems

`docs/image-signature-admission.md`, `apps/kyverno-policies/PANIC.sh`,
`apps/aifactory/manifests/manifests.yaml`. The env change rolls the aifactory
Deployment once.

## Constraints

Build Jobs must keep the #727 packed-Job fixes, so the image must be a superset of ccbd0ce.

## Open questions

None.
