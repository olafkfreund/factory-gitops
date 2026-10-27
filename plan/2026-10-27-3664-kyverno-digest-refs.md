---
status: approved
issue: 3664
repo-issue: olafkfreund/Factory#3664
spec: spec/2026-10-27-3664-kyverno-digest-refs.md
---

# Plan: first-party digest references bypass image-signature admission

## Approved decisions (from the spec)

- Kyverno v1.18.2 normalises `repo:tag@sha256:x` → `repo@sha256:x` before
  matching `imageReferences`; `<repo>:*` globs never match a digest reference.
- Add `ghcr.io/olafkfreund/<repo>@*` beside every `<repo>:*` glob (ten repos).
  NOT `<repo>*` (widens into sibling repos). `-*` runner globs unchanged.
- `require-first-party-signature-coverage` → Enforce (fail closed) in `factory`
  only; selector `(?i)^ghcr\.io(:[0-9]+)?/olafkfreund/`; mirror gains `<repo>@`
  beside each `<repo>:`. gateway/fides fail-closed is a follow-up issue.
- PANIC.sh level 1 sets both policies to Audit.
- No network in the required gate; online form checks live in a script CI
  does not discover.
- Live tag@digest pins (factory-runner-nix@e2e4…, tfactory-runner-portal-ui@e9c2…)
  are signed; cosign-verified with the anchored identities on 2026-10-27.

## Steps

All paths under `apps/kyverno-policies/`.

1. `manifests/verify-factory-image-signatures.yaml` L242, 277, 306, 360-361,
   562-563, 632, 670-671: after each `"ghcr.io/olafkfreund/<repo>:*"` add
   `"ghcr.io/olafkfreund/<repo>@*"` (aifactory, pfactory, tfactory, cfactory,
   cfactory-frontend, skillai, skillai-migrator, odin, fides-server,
   fides-k8s-reporter). Add a short header comment (Factory#3664) saying why:
   normalisation drops the tag, so `:*` alone misses both digest forms.
   → verify: `python3 apps/kyverno-policies/assert-signature-lists-agree.py`
   fails until step 2 (expected drift), then passes.
   Traps: exactly one trailing `*` per glob (the agree script rejects others).

2. `manifests/require-first-party-signature-coverage.yaml`:
   L214 `Audit` → `Enforce`; L198 description and the header "AUDIT mode"
   text → denied; L253 selector → `(?i)^ghcr\.io(:[0-9]+)?/olafkfreund/`;
   L254 alternation: add `<repo>@|` beside each `<repo>:|` (keep the
   `!regex_match('^ghcr\.io/olafkfreund/(` prefix byte-identical — the agree
   script parses it); update the comment block above L253 that says digest
   refs are "genuinely uncovered today"; L264 message: say the Pod is denied.
   → verify: agree script passes; `kyverno test apps/kyverno-policies/tests`.
   Traps: CLI is v1.18.2; YAML folded `>-` keeps single quotes literal.

3. `PANIC.sh` level 1 (L88-94) and its header usage text: patch
   `require-first-party-signature-coverage` to Audit as well as `$POLICY`;
   `status` prints both actions. → verify: `bash -n PANIC.sh`; read the diff.
   Traps: do not run PANIC.sh against the cluster.

4. Offline suites:
   - `tests/resources.yaml` L36-42: rename `uncovered-digest-pinned` →
     `covered-digest-pinned`, fix its comment; add `covered-tag-digest`
     (`tfactory:sha-1@sha256:0…0`), `uncovered-port443`
     (`ghcr.io:443/olafkfreund/aifactory:v1`), `uncovered-uppercase-registry`
     (`GHCR.IO/olafkfreund/aifactory:v1`; drop it if the CLI cannot parse it),
     `uncovered-untagged` (`ghcr.io/olafkfreund/aifactory`).
   - `tests/kyverno-test.yaml`: move/add names to the fail/skip lists.
   - `tests/resources-verify-factory-image-signatures.yaml` L105-110 and
     `tests/kyverno-test-verify-factory-image-signatures.yaml` L162: replace
     `digest-pinned-first-party` with `near-aifactory-worker-digest`
     (`aifactory-worker@sha256:0…0`) and `near-aifactory-worker-tag-digest`
     (`aifactory-worker:v1@sha256:0…0`) in the no-rule-may-match anchor.
   → verify: `kyverno test apps/kyverno-policies/tests` all pass, 0 Excluded
   on pass/fail expectations.

5. New `check-digest-forms.sh` (executable, bash, `set -euo pipefail`):
   empty keychain (`DOCKER_CONFIG` temp dir with `{}`), `kyverno apply` of
   `manifests/verify-factory-image-signatures.yaml` on one Pod per form and
   asserts the `pass:`/`fail:` counts:
   aifactory signed tag/digest/tag@digest → pass>0 fail=0;
   unsigned (`:sha256-b22c….sig`, `@sha256:e812…`, `:sha256-b22c….sig@sha256:e812…`)
   → fail>0; factory-runner-nix `:sha-47900d1@sha256:e2e4…` → pass>0.
   Signed digest `sha256:b22c1c7b8f58a365217e154a411604e8bbe7de49187c9066b2eb458d4639f8ea`
   (aifactory:sha-ec354c0-nix); unsigned `sha256:e81259ebb9c4863d4952d9822ba60ae80c05bef6841e213d8fa6835944ef306c`.
   Header: run by hand, needs network, deliberately not a `cli.kyverno.io`
   Test (CI discovers those). → verify: run it; exit 0.

## Tests

- `python3 apps/kyverno-policies/assert-signature-lists-agree.py` → ok
- `kyverno test apps/kyverno-policies/tests` (v1.18.2) → 0 failed
- `apps/kyverno-policies/check-digest-forms.sh` → exit 0
- CI manifest-validate green.
- Post-merge (lead): Argo sync, server-side dry-runs per form, prepull Pod annotation.

## Rollback

`./PANIC.sh 1` (both policies → Audit, auto-sync off), then revert the PR.
