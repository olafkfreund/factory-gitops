---
status: draft
issue: 3665
repo-issue: olafkfreund/Factory#3665
author: olafkfreund
---

# Intent: first-party images that no rule for their namespace verifies are admitted

## Problem

`require-first-party-signature-coverage` has one rule with one mirror of the
glob set in `verify-factory-image-signatures`. Since #316 that rule is
Enforce, and it matches `factory` and `gateway`. The verify rules, however,
are scoped per namespace:

| namespace | verify rules that run there |
|---|---|
| `factory` | every rule except `verify-fides-signature` |
| `gateway` | `verify-aifactory-signature` only |
| `fides`, `fides-reporter` | `verify-fides-signature` only |

Because there is only one mirror, a repo counts as "covered" wherever any rule
names it, even in a namespace where that rule does not run. Measured with
Kyverno CLI v1.18.2 (the cluster's version), on main at 9b2d322. These six Pods
each get **0 results** from both policies, so admission lets them through
unverified:

| namespace | image |
|---|---|
| `gateway` | `pfactory@sha256:e812…` |
| `gateway` | `factory-runner-nix:x@sha256:e812…` |
| `factory` | `fides-server@sha256:e812…` |
| `fides` | `pfactory:x` |
| `fides` | `future:x` (a repo no rule names) |
| `fides-reporter` | `odin@sha256:e812…` |

The first three are covered by the mirror but have no verify rule in their
namespace. The last three are in namespaces the coverage rule does not match at
all.

A read-only listing of live Pods shows first-party images in exactly
`factory`, `gateway`, `fides` and `fides-reporter`.

## Proposed outcome

In each of those four namespaces, a Pod is denied at admission if it carries a
first-party image that no verify rule **for that namespace** checks. A covered
image is still verified exactly as it is today. CI fails if a namespace's
coverage mirror drifts from the globs of the verify rules that actually run in
that namespace.

## Affected users and systems

- factory-gitops `apps/kyverno-policies` (the coverage policy, its CLI suite,
  `assert-signature-lists-agree.py`) and `docs/image-signature-admission.md`.
- Live admission in `factory`, `gateway`, `fides` and `fides-reporter` on the
  k3d-factory cluster. Pods only; the coverage policy has autogen off, so a
  denial appears as `FailedCreate` on the owning ReplicaSet/Job.

## Constraints

- Must not deny anything that runs today. Before merging, check every live Pod
  in the four namespaces against the new policy (0 denials) and cosign-verify
  every pinned digest.
- Do not touch secrets. No `--admin` and no force-push. Post on the agent bus
  before merging an admission change.
- Keep the validate/deny shape. #564 measured why `verifyImages` cannot be used
  for coverage, and that has not changed.
- Do not merge while the AIFactory 3.10.11 deploy is in progress. Wait for the
  lead to confirm cluster access.
- `./PANIC.sh 1` stays the rollback; it already acts on the whole policy.

## Out of scope, reported separately

- `Pod/ephemeralcontainers` (`kubectl debug`). Neither policy matches that
  subresource. Fixing it means changing the kinds on the verify rules, and
  Kyverno's autogen and image mutation behave differently on subresources.
  Both need a live test of their own, so it is a separate slice.
- Namespaces that run no first-party image today. A first-party image placed in
  one of them is still unverified. The follow-up is a catch-all rule that
  excludes the namespaces that have a group.

## Open questions

None.
