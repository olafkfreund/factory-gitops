---
status: draft
issue: 3665
spec: spec/2026-10-27-3665-per-namespace-coverage.md
---

# Plan: one coverage rule per namespace group

Decisions carried over from the approved spec:

- `require-first-party-signature-coverage` gets three rules, one per namespace
  group, each with its own `uncovered` mirror:
  - `first-party-image-must-be-covered-by-a-signature-rule` (name kept),
    `namespaces: [factory]`. Its mirror is today's list **without**
    `fides-server:|fides-server@|fides-k8s-reporter:|fides-k8s-reporter@`.
  - `first-party-image-must-be-covered-in-gateway`, `namespaces: [gateway]`.
    Mirror: `aifactory:|aifactory@`.
  - `first-party-image-must-be-covered-in-fides`,
    `namespaces: [fides, fides-reporter]`. Mirror:
    `fides-server:|fides-server@|fides-k8s-reporter:|fides-k8s-reporter@`.

  Everything else is identical in all three: `kinds: [Pod]`, the selector
  `(?i)^ghcr\.io(:[0-9]+)?/olafkfreund/`, the precondition, the message and
  `deny: {}`. The policy-level `validationFailureAction: Enforce`,
  `failurePolicy: Ignore`, `background: true` and
  `autogen-controllers: none` stay as they are.
- The checker compares each group: rule mirror == the glob prefixes of the
  verify rules whose namespaces include every namespace of that rule (no
  `namespaces` = everywhere). Every namespace named by a verify rule must be
  matched by some coverage rule. Checks B and C use the union of globs. No
  network.
- Validate/deny only, never `verifyImages`.
- Out of scope: `Pod/ephemeralcontainers`, and namespaces that have no group
  (a catch-all rule).

## Steps

1. `apps/kyverno-policies/manifests/require-first-party-signature-coverage.yaml`
   (rule at ~line 224 to the end): turn the one rule into the three above.
   Remove the fides entries from the `factory` mirror. Update the
   `policies.kyverno.io/description` annotation and the comment above `match`
   (which says `factory, gateway`) to describe the groups. Add one short header
   paragraph (Factory#3665) explaining why there is a mirror per group: a repo
   counts as covered only where its verify rule runs.
   → verify by `yq '.spec.rules[].name' <file>` (3 names) and
   `kyverno apply <file> --resource <scratch pods>`.
   Traps: the jmesPath stays a single `>-` folded scalar per rule, because the
   checker regex reads `!regex_match('^ghcr\.io/olafkfreund/(…)'`. Keep that
   exact prefix in every rule. Do not add `Pod/ephemeralcontainers`.

2. `apps/kyverno-policies/assert-signature-lists-agree.py`: make `mirror()`
   return `[(rule_name, namespaces, set(entries))]` for every rule with an
   `uncovered` context, and make `globs()` also return each prefix's verify
   rule namespaces (`None` = all). Rewrite check A per group, as described
   above, and add the namespace-coverage check. Checks B and C use the union.
   Update the module docstring (A now reads "per namespace group", Factory#3665).
   Keep the style: `err()`/`die()`, `::error file=` annotations, a hard failure
   when there is nothing to compare.
   → verify by running `python3 apps/kyverno-policies/assert-signature-lists-agree.py`
   from the repo root (ok). Then try three throwaway mutations, each of which
   must go red, and revert each one: fides added back to the `factory` mirror,
   `pfactory:` added to the gateway mirror, and the gateway rule's namespaces
   changed to `[gatewayx]`.
   Traps: `yq` is mikefarah yq v4 (the `-r` flag). The match path is
   `.match.any[].resources.namespaces`. Read both `any` and `all` if present,
   and treat a missing list as all namespaces.

3. `apps/kyverno-policies/tests/resources.yaml` and `tests/kyverno-test.yaml`:
   add Pods, each with a one-line comment saying why it exists.
   - Expected `fail`, gateway rule: `gw-uncovered-pfactory-digest`
     (`pfactory@sha256:e81259eb…306c`), `gw-uncovered-runner-tag-digest`
     (`factory-runner-nix:x@sha256:e81259eb…`), `gw-uncovered-odin` (`odin:x`).
   - Expected `fail`, fides rule: `fides-uncovered-pfactory` (`pfactory:x`,
     ns `fides`), `fides-uncovered-future` (`some-future-service:v1`, ns
     `fides`), `fidesreporter-uncovered-odin-digest` (`odin@sha256:e81259eb…`,
     ns `fides-reporter`).
   - Expected `fail`, factory rule: `uncovered-fides-in-factory`
     (`fides-server@sha256:e81259eb…`).
   - Expected `skip`, gateway rule: `gw-covered-aifactory`
     (`aifactory:sha-ec354c0-gateway`), `gw-covered-aifactory-digest`
     (`aifactory@sha256:e81259eb…`).
   - Expected `skip`, fides rule: `fides-covered-server` (`fides-server:x`),
     `fidesreporter-covered-reporter` (`fides-k8s-reporter:latest`),
     `fides-thirdparty` (`postgres:15-alpine`).
   Use the full digest
   `sha256:e81259ebb9c4863d4952d9822ba60ae80c05bef6841e213d8fa6835944ef306c`.
   Every existing `factory` case keeps its expected result.
   → verify by `kyverno test apps/kyverno-policies/tests/` with v1.18.2 (all
   pass), plus a hand check that each new rule shows a real `fail` row,
   not Excluded.
   Traps: in this CLI, an Excluded row satisfies any expected result, so each
   rule must have at least one `fail` case. The suite is offline; no case may
   be one `verify-factory-image-signatures` is tested against.

4. `docs/image-signature-admission.md` (~lines 573–660, the coverage section,
   including the sentence at ~581 "in `factory` or `gateway`"): describe the
   three groups in a small table, why there is one mirror per group
   (Factory#3665), and the two out-of-scope items. Update any other line in
   this doc that states the coverage scope (grep `factory\` or \`gateway`).
   → verify by `grep -n "gateway" docs/image-signature-admission.md` and reading
   the section.
   Traps: none.

5. Lane (not the coder), once the lead confirms cluster access. Offline:
   rerun the intent's six-Pod repro (all `fail`). Live and read-only: export
   every Pod in the four namespaces, run the new policy plus the verify policy
   over them with the CLI (0 `fail` from coverage), and `cosign verify` every
   pinned digest with the anchored identity. Server-side dry-run the policy
   file and the six Pods. Then open the PR, get CI green, post on the bus,
   merge with land.sh, sync Argo, repeat the dry-runs (denied), and check
   there are no `FailedCreate` events.
   Traps: the AIFactory deploy must be finished first. Never `--admin` or
   force-push.

## Tests

- `kyverno test apps/kyverno-policies/tests/` (v1.18.2): 0 failed.
- `python3 apps/kyverno-policies/assert-signature-lists-agree.py`: ok, and red
  on each of the three mutations.
- `python3 apps/kyverno-policies/assert-mutate-idempotent.py`, if CI runs it on
  this directory: unchanged.
- CI `manifest-validate` green.

## Rollback

`./apps/kyverno-policies/PANIC.sh 1` (both policies to Audit and Argo
auto-sync suspended), then revert the PR.
