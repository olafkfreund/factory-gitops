---
status: draft
issue: 323
repo-issue: olafkfreund/factory-gitops#323
spec: spec/2026-10-31-323-startup-probe.md
---

# Plan: a startupProbe so liveness doesn't cut the boot migration lock wait

Decisions (from the spec): add `startupProbe` on each web container's
liveness path and port with `periodSeconds: 10`, `timeoutSeconds: 5` and
`failureThreshold: 36` (360 s). Liveness and readiness are unchanged, and
liveness `initialDelaySeconds` stays 30 because there is no repo precedent
for 0.

## Steps

1. `apps/pfactory/manifests/manifests.yaml` (after the livenessProbe, L445):
   add `startupProbe: { httpGet: { path: /api/health, port: 3114 }, periodSeconds: 10, timeoutSeconds: 5, failureThreshold: 36 }`,
   with a one-line comment naming #323.
2. `apps/aifactory/manifests/manifests.yaml` (after L776): the same, port 3101.
3. `apps/tfactory/manifests/manifests.yaml` (after L780): the same, port 3103.

These are three one-line edits, so they are below the coder handoff
threshold in practice and done inline.

## Tests

CI manifest-validate passes. `kubectl apply --dry-run=server -n factory` on
the three files passes.

## Rollback

Revert the PR. Argo restores the previous probes.
