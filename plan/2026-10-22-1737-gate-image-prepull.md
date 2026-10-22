---
status: draft
issue: AIFactory#1737
spec: spec/2026-10-22-1737-gate-image-prepull.md
---

# Plan: gate-image-prepull DaemonSet

Decisions (from the approved spec): DaemonSet `gate-image-prepull` in
namespace `factory`; initContainers `sandbox-image` and `build-image` run
`sh -c true`; main container `rancher/mirrored-pause:3.6@sha256:74c4244427b7312c5b901fe0f67cbc53683d06f4f24c6faee65d4182bf0fa893`;
initContainer images filled by kustomize `replacements` from the Deployment
env values `AIFACTORY_SANDBOX_IMAGE` and `AIFACTORY_BUILD_IMAGE` (the
`images:` transformer would otherwise retag the aifactory -nix ref);
non-root 65532, RO root fs, drop ALL, RuntimeDefault, no SA token,
`ghcr-pull`, requests 1m/4Mi, limits 10m/16Mi.

## Steps

1. apps/aifactory/manifests/manifests.yaml: append the DaemonSet after the
   last document; add a one-line comment above each of the two env values
   (~lines 421 and 675) → verify by `kustomize build apps/aifactory/manifests`.
   Traps: literal image strings in the DaemonSet get rewritten by `images:`.
2. apps/aifactory/manifests/kustomization.yaml: add two `replacements` (env
   value → initContainer image) → verify by
   `kustomize build apps/aifactory/manifests | yq 'select(.kind=="DaemonSet") | .spec.template.spec.initContainers[].image'`
   equals the two env values.
   Traps: CI runs `kustomize edit set image` on this file; leave `images:` alone.

## Tests

- Rendered DaemonSet images equal the env values (step 2 command).
- Renaming one env var makes `kustomize build` fail (regression guard).
- CI `manifest validation (blocking)` green.

## Rollback

Revert the commit; ArgoCD prunes the DaemonSet. Images stay cached until GC.
