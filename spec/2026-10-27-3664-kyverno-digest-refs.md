---
status: approved
issue: 3664
repo-issue: olafkfreund/Factory#3664
intent: intent/2026-10-27-3664-kyverno-digest-refs.md
---

# Spec: first-party digest references bypass image-signature admission

## Design

1. **Globs** (`apps/kyverno-policies/manifests/verify-factory-image-signatures.yaml`).
   Beside every `ghcr.io/olafkfreund/<repo>:*` glob add
   `ghcr.io/olafkfreund/<repo>@*`: aifactory, pfactory, tfactory, cfactory,
   cfactory-frontend, skillai, skillai-migrator, odin, fides-server,
   fides-k8s-reporter. Kyverno normalises `repo:tag@sha256:x` to
   `repo@sha256:x`, so this one glob covers both digest forms. `<repo>@*`, not
   `<repo>*`: the latter would pull `aifactory-worker` under AIFactory's
   identity (the widening the existing negative suite guards against). The
   `-*` runner globs already match every form and are unchanged.

2. **Fail closed** (`require-first-party-signature-coverage.yaml`).
   - `validationFailureAction: Audit` → `Enforce`.
   - First-party selector `^ghcr\.io/olafkfreund/` →
     `(?i)^ghcr\.io(:[0-9]+)?/olafkfreund/`, so `ghcr.io:443/…` and case
     variants count as first-party.
   - Covered alternation gains `<repo>@` beside each `<repo>:` (same ten repos),
     so the mirror stays equal to the glob set (assert-signature-lists-agree.py
     normalises `X*` → `X`). Anything first-party not matching it — port form,
     uppercase, untagged, an unknown repo — is denied.
   - Message reworded from "reported" to "denied", keeping the remediation order.
   - Scope stays `namespaces: [factory]`. In `gateway`/`fides*` only one or two
     repos are verified, and a single mirror would claim false coverage there;
     per-namespace fail-closed is a follow-up issue. The glob fix (1) still
     closes the digest bypass in those namespaces.

3. **PANIC.sh** level 1 sets BOTH policies to Audit (level 1 must undo
   every Enforce it can be blamed for).

4. **Offline tests** (required gate):
   - `tests/resources.yaml` + `kyverno-test.yaml`: `uncovered-digest-pinned`
     becomes `covered-digest-pinned` (skip); add `covered-tag-digest` (skip),
     `uncovered-port443` (fail), `uncovered-uppercase-registry` (fail),
     `uncovered-untagged` (fail).
   - `tests/resources-verify-factory-image-signatures.yaml`: the
     `digest-pinned-first-party` fixture now matches the aifactory rule (needs
     the network), so it is replaced by `near-aifactory-worker-digest`
     (`aifactory-worker@sha256:…`) and `near-aifactory-worker-tag-digest`
     (`aifactory-worker:v1@sha256:…`), which no rule may match.

5. **Online check** (by hand, not in CI): `apps/kyverno-policies/check-digest-forms.sh`
   runs `kyverno apply` with an empty keychain on the eight forms of
   aifactory and factory-runner-nix and asserts: signed tag / digest / tag@digest
   → pass; unsigned tag / digest / tag@digest → fail. Not a `cli.kyverno.io`
   Test file, so CI discovery does not pick it up.

## Alternatives rejected

- `<repo>*` globs: widens into sibling repos (breaks the negative suite, wrong signer).
- A validate rule denying every first-party `@sha256` reference: blocks the
  three live tag@digest pins (factory-runner-nix, tfactory-runner-portal-ui),
  which are signed and verified today — an outage for no security gain.
- Reading the `kyverno.io/verify-images` annotation in a validate rule: it is
  keyed by the normalised reference and written by the same engine; brittle.
- New separate Enforce policy: duplicates the mirror the CI script compares.

## Risks

- Enforce on coverage denies a first-party image in `factory` with no rule.
  Live today: zero non-pass coverage results; every first-party image in
  `factory` is named. Rollback: `./PANIC.sh 1`.
- tag@digest pins newly verified: factory-runner-nix@e2e4… and
  tfactory-runner-portal-ui@e9c2… both `cosign verify` with the anchored
  identity (and were already matched by the `-*` globs).
- `failurePolicy: Ignore` stays: a webhook timeout still admits (unchanged, out of scope).

## Verification

- CI: manifest-validate green (offline suites, glob-agreement script).
- Local: `check-digest-forms.sh` all expected verdicts with Kyverno v1.18.2.
- After Argo sync: server-side dry-runs (`kubectl create --dry-run=server`) of
  the six aifactory forms, port443 and untagged: signed pass, unsigned/odd denied.
- `gate-image-prepull-*` next Pod carries `verify-images` pass.
