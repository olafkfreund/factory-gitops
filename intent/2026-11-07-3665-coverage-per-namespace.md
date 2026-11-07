---
status: approved
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
4. The factory-gitops#316 review suspected that `kinds: [Pod]` misses the
   `Pod/ephemeralcontainers` subresource, so `kubectl debug` would bypass both
   policies. Checked 2026-11-07 and refuted: Kyverno v1.18.2 matches Pod rules
   on that subresource for backward compatibility
   (`pkg/utils/match/kind.go` `CheckKind`, `pkg/policycache/store.go:145`), and
   the live `kyverno-resource-{validating,mutating}-webhook-cfg` both register
   `pods/ephemeralcontainers`. The coverage jmesPath already reads
   `ephemeralContainers`. What is missing is a test that pins this.

`assert-signature-lists-agree.py` compares one flat glob set with one flat
mirror, so it cannot see cases 1–3.

## Proposed outcome

- In each of `factory`, `gateway`, `fides`, `fides-reporter`, a Pod carrying a
  first-party image that no signature rule *running in that namespace* names is
  denied at admission and reported `fail` in background scans.
- A test pins that an uncovered first-party image in `ephemeralContainers`
  fails coverage, so case 4 stays closed.
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

## Out of scope (pre-existing, reviewer-raised, unchanged by this task)

- `failurePolicy: Ignore`: admission fails open while Kyverno is down (stated
  in both policy headers).
- `allowExistingViolations` defaults to true: a Pod admitted with a violation
  (during an outage or under Audit) can be updated without denial.
- Mutable tags with `mutateDigest: false`, and image volumes
  (`spec.volumes[].image`), which neither policy inspects.
- A tagless `ghcr.io/olafkfreund/<repo>` fails coverage; that is the existing,
  tested fail-closed behaviour (`uncovered-untagged`).

## Open questions

None.
