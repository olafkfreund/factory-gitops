---
status: draft
issue: olafkfreund/Factory#3665
author: olafkfreund
---

# Intent: fail closed on unverified first-party images in every signed namespace

## Problem

`require-first-party-signature-coverage` (Enforce since Factory#3664) uses one
mirror of covered repos for `factory` and `gateway`, and does not run in `fides`
or `fides-reporter` at all. The mirror is the union of every signature rule's
globs, but those rules are scoped per namespace. So:

1. `gateway`: only `verify-aifactory-signature` runs, yet `pfactory:`, `odin:`,
   etc. count as covered. An unsigned `ghcr.io/olafkfreund/pfactory@sha256:...`
   is admitted with no signature check.
2. `factory`: `fides-server`/`fides-k8s-reporter` count as covered, but
   `verify-fides-signature` only runs in `fides`/`fides-reporter`. Same hole.
3. `fides`/`fides-reporter`: no coverage rule, so any other first-party image
   (another repo, or `ghcr.io:443/...`) is admitted unverified.
4. Both policies match `kinds: [Pod]`. `kubectl debug` goes through the
   `Pod/ephemeralcontainers` subresource, which neither policy matches, so an
   unsigned first-party image added as an ephemeral container bypasses both
   (from the factory-gitops#316 review; not reproduced).

`assert-signature-lists-agree.py` compares one flat glob set with one flat
mirror, so it cannot see cases 1–3.

## Proposed outcome

- In each of `factory`, `gateway`, `fides`, `fides-reporter`, a Pod carrying a
  first-party image that no signature rule *running in that namespace* names is
  denied at admission and reported `fail` in background scans.
- An ephemeral container with a first-party image cannot be added in those
  namespaces without the same guarantee.
- CI (`assert-signature-lists-agree.py`) fails if a namespace's mirror drifts
  from the globs of the rules scoped to that namespace, or if a namespace a
  signature rule runs in has no coverage rule.

## Affected users and systems

- factory-gitops: `apps/kyverno-policies/manifests/require-first-party-signature-coverage.yaml`,
  `apps/kyverno-policies/assert-signature-lists-agree.py`, `apps/kyverno-policies/tests/`.
- k3d-factory cluster (Kyverno v1.18.2) via ArgoCD: namespaces `factory`,
  `gateway`, `fides`, `fides-reporter`.
- Operators using `kubectl debug` in those namespaces.

## Constraints

- Must not deny any Pod running today. Read-only check on 2026-11-07: `factory`
  runs aifactory, cfactory, cfactory-frontend, factory-runner-nix, odin,
  pfactory, skillai, tfactory; `gateway` aifactory; `fides` fides-server;
  `fides-reporter` fides-k8s-reporter. All named by a rule scoped to their namespace.
- No registry calls from the coverage policy (its header explains why).
- Keep `./PANIC.sh 1` able to return everything to Audit.
- Kyverno v1.18.2 semantics; tests must run offline in CI.
- No live cluster changes from this task.

## Open questions

None. (Approved unseen by user 2026-11-07, bulk run, if approved.)
