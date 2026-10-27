---
status: draft
issue: 3664
repo-issue: olafkfreund/Factory#3664
spec: spec/2026-10-27-3664-digest-followup.md
---

# Plan: follow-ups to the digest-reference admission fix (#316)

Decisions: repin `AIFACTORY_IMAGE` to `aifactory:sha-ec354c0-nix` (== `AIFACTORY_BUILD_IMAGE`,
a superset of ccbd0ce with the #727 fixes; keep the variable because the fallback cannot
run builds), and add a runbook and PANIC note on admission-time registry/Sigstore
dependence and the FailedCreate / stalled-Progressing signals.

## Steps

1. `apps/aifactory/manifests/manifests.yaml` L562 (and its comment above): set the
   value to `ghcr.io/olafkfreund/aifactory:sha-ec354c0-nix`, and note why
   (Factory#3664: ccbd0ce is unsigned).
   Verify by a server-side dry-run Pod giving `pass`.
2. `docs/image-signature-admission.md` escape-hatch section and the
   `apps/kyverno-policies/PANIC.sh` header: add the runbook note.
   Verify by reading the diff.

## Tests

CI manifest-validate green; dry-run `pass`; post-merge aifactory rollout healthy.

## Rollback

Revert the PR; Argo restores the previous env.
