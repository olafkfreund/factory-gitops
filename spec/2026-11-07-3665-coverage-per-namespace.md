---
status: draft
issue: olafkfreund/Factory#3665
intent: intent/2026-11-07-3665-coverage-per-namespace.md
---

# Spec: one coverage rule per namespace group

## Design

### 1. `apps/kyverno-policies/manifests/require-first-party-signature-coverage.yaml`

Replace the single rule, scoped `[factory, gateway]` with the union mirror,
by three rules. Each mirrors exactly the globs of the
`verify-factory-image-signatures` rules that run in its namespaces:

| Rule | `namespaces` | Mirror alternation |
| ---- | ------------ | ------------------ |
| `first-party-image-must-be-covered-by-a-signature-rule` (name kept, so the existing test suite and history still refer to it) | `[factory]` | today's list minus `fides-server:` `fides-server@` `fides-k8s-reporter:` `fides-k8s-reporter@` |
| `first-party-image-must-be-covered-in-gateway` | `[gateway]` | `aifactory:` `aifactory@` |
| `first-party-image-must-be-covered-in-fides` | `[fides, fides-reporter]` | `fides-server:` `fides-server@` `fides-k8s-reporter:` `fides-k8s-reporter@` |

The context variable stays named `uncovered`, the first-party filter and
jmesPath shape stay byte-identical except for the alternation, and the
preconditions and `validate` block are shared through a YAML anchor
(`&covered-validate` / `*covered-validate`), so the deny message cannot drift
between rules. The file already relies on yq for parsing, and yq and Kyverno
(via ArgoCD's YAML decode) both resolve anchors.

Policy-level fields are unchanged: `Enforce`, `failurePolicy: Ignore`,
`background: true`, `autogen-controllers: none`, `kinds: [Pod]`. The
`description` annotation and the header's scope sentences are updated to name
all four namespaces and the per-namespace pairing.

`kinds: [Pod]` stays. Kyverno v1.18.2 already sends
`pods/ephemeralcontainers` requests to Pod rules (`CheckKind`
`allowEphemeralContainers`; live webhook configs list the subresource), and
the jmesPath already reads `ephemeralContainers`.

### 2. `apps/kyverno-policies/assert-signature-lists-agree.py`

Model namespaces instead of one flat set:

- `globs()` returns, per signature rule, `(rule name, namespaces, {prefix: glob})`.
  A rule whose match is not exactly `match.any[].resources` with non-empty
  `namespaces`, or that has `exclude` or `preconditions`, is an error: the
  script cannot say which namespaces it really covers.
- `mirror()` returns, per coverage rule that has an `uncovered` context,
  `(rule name, namespaces, alternation set)`, parsing each rule's jmesPath on
  its own (today it concatenates them and reads only the first match).
- Assertion A becomes, for every coverage rule and every namespace `n` it
  matches: mirror == union of prefixes of signature rules whose namespaces
  contain `n`. Errors name the rule and the namespace.
- New assertion D: every namespace any signature rule names is matched by
  some coverage rule. Without it, adding a signature rule in a new namespace
  silently leaves that namespace fail-open (the `fides` case in this issue).
- B (probed images named by some glob) and C (canary named by none) keep
  using the union of all globs, unchanged.

### 3. `apps/kyverno-policies/tests/` (`kyverno-test.yaml`, `resources.yaml`)

Add Pods:

- `gateway-uncovered-pfactory` (gateway, `pfactory@sha256:...`) → `fail` on the gateway rule. Case 1.
- `factory-uncovered-fides-server` (factory, `fides-server@sha256:...`) → `fail` on the factory rule. Case 2.
- `fides-uncovered-aifactory` (fides, `aifactory:sha-x`) and
  `fides-reporter-uncovered-port443` (fides-reporter, `ghcr.io:443/olafkfreund/fides-k8s-reporter:latest`) → `fail` on the fides rule. Case 3.
- `gateway-covered-aifactory`, `fides-covered-server`,
  `fides-reporter-covered-reporter` → `skip` on their rules.
- `uncovered-in-ephemeralcontainer` (factory, uncovered image only in
  `ephemeralContainers`) → `fail`. Case 4 pin.

## Alternatives rejected

- **Widen the existing rule to all four namespaces with the union mirror.**
  Reports `pfactory:` as covered in `gateway` — the defect itself.
- **Widen the signature rules to all four namespaces.** Bigger blast radius:
  each extra namespace adds registry/Rekor calls and changes the signature
  board; and it does not stop the next rule from being scoped narrowly.
- **A JMESPath branch on `request.namespace` inside one rule.** One rule, but
  the mirror becomes a nested map the script must parse; three flat rules
  reuse the existing regex shape.
- **Add `Pod/ephemeralcontainers` to `kinds`.** Unneeded (already matched);
  on the signature policy it would also change autogen.
- **Set `allowExistingViolations: false`.** Out of scope per the intent;
  would also block every update of a Pod admitted during an outage.

## Risks

- A legitimate first-party Pod in `gateway`/`fides`/`fides-reporter` with an
  image whose rule is not scoped there is now denied. Mitigated: read-only
  inventory on 2026-11-07 shows none (aifactory in gateway, fides-server in
  fides, fides-k8s-reporter in fides-reporter). `factory` loses only the
  fides entries; no fides image runs there. Rollback: `./PANIC.sh 1`.
- `failurePolicy: Ignore` means a policy Kyverno rejects is not enforced and
  ArgoCD keeps the old one (Factory#430). Mitigated by CI's `kyverno apply`
  validation step and a local run with the v1.18.2 CLI.
- YAML anchors: if any consumer did not resolve them, the rule would lose its
  validate block. Mitigated: CI's `kyverno apply`/`kyverno test` read the same
  file; a local `kyverno test` proves the anchored rules fire.

## Verification

- `python3 apps/kyverno-policies/assert-signature-lists-agree.py` prints `ok`.
- Mutation checks (not committed): drop `aifactory@` from the gateway mirror;
  add `pfactory:` to it; remove the fides rule; scope a signature rule to a
  new namespace — each must fail the script with a message naming rule and
  namespace.
- `kyverno test apps/kyverno-policies/tests -f kyverno-test.yaml` with CLI
  v1.18.2: all old and new cases pass.
- `kyverno apply` on the policy (CI's validation step) succeeds.
- The repo's other kyverno suites and `manifest-validate` steps still pass
  (run what is runnable locally; CI on the PR).
