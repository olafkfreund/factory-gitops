---
status: approved
issue: 3665
intent: intent/2026-10-27-3665-per-namespace-coverage.md
---

# Spec: one coverage rule per namespace group

## Design

1. **`require-first-party-signature-coverage` gets one rule per namespace
   group.** Each rule has its own `uncovered` mirror, listing only the globs of
   the verify rules that run in that group:

   | rule | namespaces | mirror |
   |---|---|---|
   | `first-party-image-must-be-covered-by-a-signature-rule` (name kept) | `factory` | every current entry except `fides-server:/@` and `fides-k8s-reporter:/@` |
   | `first-party-image-must-be-covered-in-gateway` | `gateway` | `aifactory:`, `aifactory@` |
   | `first-party-image-must-be-covered-in-fides` | `fides`, `fides-reporter` | `fides-server:`, `fides-server@`, `fides-k8s-reporter:`, `fides-k8s-reporter@` |

   All three keep today's shape: the same case-insensitive, port-tolerant
   first-party selector, the same precondition, the same message and
   `deny: {}`, Pods only, and the policy-level Enforce. The `factory` rule keeps
   its name, so existing PolicyReport rows and test references stay valid.
   Removing fides from the `factory` mirror is itself part of the fix: fides
   images are not verified in `factory`.

2. **`assert-signature-lists-agree.py` compares each group separately.**
   - For every coverage rule with an `uncovered` variable, its mirror must
     equal the normalised glob prefixes of the verify rules that apply in
     **every** namespace of that rule. A verify rule with no `namespaces`
     applies everywhere.
   - Every namespace that any verify rule names must be matched by some
     coverage rule. Otherwise a new namespace given a verify rule would have
     no fail-closed coverage, and CI says so.
   - Checks B (each probe image is named by some glob) and C (the canary is
     named by none) use the union of all globs, as they do today.
   - The checker stays offline and uses yq only.

3. **The CLI suite (`tests/kyverno-test.yaml`, `tests/resources.yaml`) gains
   cases for each new rule.**
   - Must fail: the six Pods from the intent, plus a Pod in `gateway` running
     `odin:x`.
   - Must skip: `aifactory:x` and `aifactory@sha256:…` in `gateway`,
     `fides-server:x` in `fides`, `fides-k8s-reporter:latest` in
     `fides-reporter`, and a third-party image in `fides`.

   Each new rule has at least one expected `fail`. Guard 5 in CI (an Excluded
   row cannot satisfy `fail`) therefore proves each rule actually evaluates in
   its namespaces.

4. **Docs.** Update the policy header and annotation description, and the
   coverage section of `docs/image-signature-admission.md` (around lines
   573–650), to describe the per-namespace groups and list the two
   out-of-scope items.

## Alternatives rejected

- **One rule whose mirror depends on `request.namespace`.** A JMESPath
  conditional for each namespace is unreadable, and the CI checker would have
  to parse it.
- **Widen the verify rules to every namespace instead.** The fides rule would
  then also run in `factory`, and the aifactory rule in `fides`. The tables
  would look aligned, but the namespace scoping the verify rules chose on
  purpose (the gateway rule in #313, fides#395) would be gone, and the per-rule
  registry cost would grow. It also leaves the mirror unable to say what runs
  where.
- **A separate policy per group.** The checker would then have to discover
  three policies, and `PANIC.sh` (which names the policy) would need editing.
  Rules within one policy give the same isolation.
- **A catch-all rule for every other namespace.** Wanted, but it is a separate
  slice (see the intent); its blast radius covers namespaces nobody has
  inventoried for this change.
- **Matching `Pod/ephemeralcontainers` here.** That would only make coverage
  speak for `kubectl debug`. A covered-but-unsigned debug image would still go
  unverified unless the verify rules also match the subresource, and that
  needs a live test of autogen and mutation. It is a separate slice.

## Risks

- **A live workload is denied.** Specifically: a non-fides first-party image in
  `fides`/`fides-reporter`, a non-aifactory one in `gateway`, or a fides image
  in `factory`. Today's read-only listing shows none. Before merging, re-check
  every live Pod in the four namespaces against the new policy with the CLI and
  require 0 `fail`. Rollback: `./PANIC.sh 1`, then revert.
- **Kyverno rejects the policy, so ArgoCD keeps serving the old version while
  reporting healthy (Factory#430).** Mitigation: a server-side dry-run of the
  policy file before merging, and after the sync, read back the live object's
  rule names.
- **Background scan.** Pods admitted before the policy (if any) show `fail` on
  the board rather than being evicted. That is the intended signal.

## Verification

- `kyverno test apps/kyverno-policies/tests/` with v1.18.2: every new case
  gets its expected result.
- `python3 apps/kyverno-policies/assert-signature-lists-agree.py` passes. It
  goes red if: (a) fides is added back to the `factory` mirror, (b)
  `pfactory:` is added to the gateway mirror, or (c) `gateway` is dropped from
  every coverage rule. All three are mutation-checked by hand.
- The intent's repro run again with the CLI: all six Pods now `fail`.
- Live, once cluster access is confirmed:
  - server-side dry-run of the six Pods before the sync (admitted) and after
    it (denied by coverage);
  - a server-side dry-run of the gateway aifactory Pod still passes;
  - 0 `fail` over every live Pod in the four namespaces;
  - `cosign verify` of every pinned digest there;
  - no `FailedCreate` events in the four namespaces after the sync.
- CI green on the PR.
