---
status: draft
issue: 3664
repo-issue: olafkfreund/Factory#3664
author: olafkfreund
---

# Intent: first-party digest references bypass image-signature admission

## Problem

Kyverno v1.18.2 rewrites an image reference that carries a digest
(`repo@sha256:…` or `repo:tag@sha256:…`) to `repo@sha256:…` before it matches
`imageReferences`. Every rule in `verify-factory-image-signatures` whose glob is
`ghcr.io/olafkfreund/<repo>:*` therefore never sees a digest reference. Measured
with the CLI against the live registry (empty keychain):

| reference to `aifactory` | before |
|---|---|
| `:sha-ec354c0-nix` (signed) | pass 2 |
| `@sha256:b22c…` (same signed image) | **0 results** |
| `:sha-ec354c0-nix@sha256:b22c…` | **0 results** |
| `:sha256-b22c….sig` (unsigned) | fail 2 |
| `@sha256:e812…` (unsigned) | **0 results — admitted under Enforce** |
| `:sha256-b22c….sig@sha256:e812…` (unsigned) | **0 results — admitted** |
| `ghcr.io:443/olafkfreund/aifactory:…` | **0 results — admitted** |

So any unsigned image pushed under a first-party repo name runs unverified when
it is referenced by digest. `require-first-party-signature-coverage` does not
catch the tag@digest form (its regex sees `aifactory:`), does not see the
`ghcr.io:443` form at all, and is Audit only.

The `-*` globs (`tfactory-runner-*`, `factory-runner-*`) already match the
normalised form: the live `gate-image-prepull-*` Pods running
`factory-runner-nix:sha-47900d1@sha256:e2e4…` carry
`kyverno.io/verify-images: …"pass"`.

## Proposed outcome

- Every first-party verify rule matches its repo in every reference form: tag,
  digest, tag@digest. Signed passes, unsigned is denied.
- In namespace `factory`, a first-party image reference that no verify rule
  names, in any spelling (`ghcr.io:443/…`, untagged, a new repo), is DENIED at
  admission instead of reported. Fail closed.
- Every tag@digest pin in this repo is confirmed signed before the change lands.

## Affected users and systems

k3d-factory on p620: Kyverno policies `verify-factory-image-signatures` and
`require-first-party-signature-coverage`; every Pod in `factory`, `gateway`,
`fides`, `fides-reporter`. Manifests pinning tag@digest:
`apps/aifactory` (AIFACTORY_SANDBOX_IMAGE), `apps/tfactory`
(TFACTORY_VAL3_K8S_JOB_IMAGE, TFACTORY_NIX_RUNNER_IMAGE, PORTAL_UI_IMAGE).

## Constraints

- No currently running workload may be denied on its next restart.
- No network inside the required CI gate (#148/#149 trade stays).
- No secrets; no --admin/force-push; bus post before merge.

## Open questions

None. (Pre-approved lane; fides/gateway fail-closed scope is a follow-up, see spec.)
