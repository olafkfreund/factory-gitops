---
status: approved
issue: olafkfreund/Factory#3665
spec: spec/2026-11-07-3665-coverage-per-namespace.md
coders:
  1: coder   # YAML restructure with anchors and comment edits: neither large-mechanical nor tricky logic
  2: codex   # small, tricky logic: per-namespace set comparison and an allow-list parser where a wrong branch reads green
  3: agy     # large mechanical: ~8 near-identical test Pods and result entries
reviewers:
  - codex    # independent read of the checker logic it did not write in step 3's context
  - agy      # independent read of the policy split and tests against the inventory
---

# Plan: one coverage rule per namespace group

Repo: factory-gitops, branch `fix/3665-coverage-per-namespace` off `main`.
Kyverno v1.18.2 (cluster and CLI). CLI for local runs:
`/tmp/claude-1000/-mnt-code-Source-home-GitHub-Factory/157388fb-55f6-470f-a189-e3907c327b71/scratchpad/bin/kyverno`.

## Approved decisions (from spec)

- `require-first-party-signature-coverage` gets three rules, each mirroring
  exactly the `verify-factory-image-signatures` globs whose rule runs in its
  namespaces:
  - `first-party-image-must-be-covered-by-a-signature-rule` → `[factory]`,
    today's alternation minus the four `fides-*` entries.
  - `first-party-image-must-be-covered-in-gateway` → `[gateway]`,
    `aifactory:|aifactory@`.
  - `first-party-image-must-be-covered-in-fides` → `[fides, fides-reporter]`,
    `fides-server:|fides-server@|fides-k8s-reporter:|fides-k8s-reporter@`.
- Context variable stays `uncovered`; jmesPath identical except the
  alternation; preconditions + validate shared via a YAML anchor. Policy-level
  fields unchanged; `kinds: [Pod]` unchanged (Kyverno already routes
  `pods/ephemeralcontainers` to Pod rules).
- `assert-signature-lists-agree.py`: per-rule namespaces; shared match-shape
  allow-list; prefix alphabet `^[a-z0-9-]+[:@]?$`; assertion A per coverage
  rule per namespace; new D (REQUIRED_NAMESPACES floor + every signature
  namespace covered); B and C unchanged on the union.
- Tests: new fail/skip Pods for each namespace group and an ephemeral-container case.

## Steps

1. `apps/kyverno-policies/manifests/require-first-party-signature-coverage.yaml`
   - `rules:` (line ~225 to end): replace the one rule with the three above.
     First rule keeps its name and `context` text; set `namespaces: [factory]`
     and drop `fides-server:|fides-server@|fides-k8s-reporter:|fides-k8s-reporter@`
     from its alternation. Put `&covered-preconditions` on its `preconditions`
     and `&covered-validate` on its `validate`; the other two rules use
     `*covered-preconditions` / `*covered-validate` and the same `context`
     block with only the alternation changed. Replace the `# Factory#1959`
     comment with one line saying each rule mirrors only the rules scoped to
     its namespaces (Factory#3665).
   - `policies.kyverno.io/description` (line ~211): name all four namespaces
     and "no verifyImages rule running in that namespace".
   - Header: in "THE COVERED LIST BELOW MIRRORS THE GLOBS" add two sentences:
     there is one mirror per namespace group, each equal to the globs of the
     signature rules scoped to those namespaces, and the agree script checks
     each pairing (Factory#3665). Do not rewrite other history in the header.
   → verify: `yq '.spec.rules[] | [.name, .match.any[0].resources.namespaces, .validate.message != null]' -o json <file>`
     shows three rules each with a message; `kyverno apply <file> --resource <scratch pod: one busybox container in factory>`
     reports `pass: 0, fail: 0, ... skip: 1` and no policy validation error
     (a fixture that is meant to fail would make `apply` exit non-zero, so it
     is not used to check that the policy loads).
   Traps: CI strips `webhookConfiguration.matchConditions` before CLI runs
   (none here). Keep `ghcr\.io` escaping exactly as today inside the folded
   `>-` scalar. Don't touch `verify-factory-image-signatures.yaml`.

2. `apps/kyverno-policies/assert-signature-lists-agree.py`
   - Add `REQUIRED_NAMESPACES = {"factory", "gateway", "fides", "fides-reporter"}`
     and `PREFIX = re.compile(r"^[a-z0-9-]+[:@]?$")`.
   - Add `scope(path, rule, allowed_keys)`: returns the rule's namespace set
     or reports `err` and returns None, allowing only: rule keys ⊆
     `allowed_keys`; `match` keys == {`any`}; each `any[]` keys == {`resources`};
     each `resources` keys == {`kinds`, `namespaces`}, `kinds == ["Pod"]`,
     `namespaces` non-empty list of strings each matching `^[a-z0-9-]+$`
     (Kyverno treats `*`/`?` in namespaces as wildcards; the checker compares
     literal names, so it must refuse them).
   - `globs()` reads `.spec.rules` as JSON (one yq call), returns a list of
     `(name, namespaces, {prefix: glob})` for rules with `verifyImages`
     (allowed keys `name, match, verifyImages`); applies the existing
     trailing-`*` check plus `PREFIX` to each prefix. Dies if no glob found.
   - `mirror()` reads `.spec.rules` as JSON, returns a list of
     `(name, namespaces, set)` for rules whose `context` has a variable named
     `uncovered` (allowed keys `name, match, context, preconditions, validate`),
     running the existing regex on EACH rule's jmesPath separately; entries
     must match `PREFIX`. Dies if none found.
   - `main()`: A — for each coverage rule, each `n` in its namespaces:
     `expected = ∪ prefixes of signature rules with n in namespaces`; report
     `covered - expected` (mirror claims coverage admission never checks) and
     `expected - covered` (drift), naming rule and namespace. D — every
     namespace in `REQUIRED_NAMESPACES ∪ (all signature namespaces)` is in some
     coverage rule's namespaces, else err. B/C on the union of all globs,
     unchanged. Update the module docstring's "WHAT THIS ASSERTS" for A and D,
     state in THE CEILING that it compares lists only (that each rule actually
     denies is proven by `kyverno test`, not here), and update the ok line
     (count rules and namespaces).
   → verify: `python3 apps/kyverno-policies/assert-signature-lists-agree.py`
     from the repo root prints `ok ...` after step 1; before step 1 it must
     FAIL (gateway mirror claims pfactory etc.), proving the check bites.
   Traps: run from repo root (`.git` is a file in a worktree). Keep the
   `::error file=...::` annotation format. yq is mikefarah yq v4 (`-o json`).
   No network.

3. `apps/kyverno-policies/tests/resources.yaml` and `tests/kyverno-test.yaml`
   - Add Pods (same style as existing entries, `{name, namespace}` flow metadata):
     `gateway-uncovered-pfactory` (gateway, `ghcr.io/olafkfreund/pfactory@sha256:` + 64×`a`),
     `factory-uncovered-fides-server` (factory, `ghcr.io/olafkfreund/fides-server@sha256:` + 64×`b`),
     `fides-uncovered-aifactory` (fides, `ghcr.io/olafkfreund/aifactory:sha-1234567`),
     `fides-reporter-uncovered-port443` (fides-reporter, `ghcr.io:443/olafkfreund/fides-k8s-reporter:latest`),
     `gateway-covered-aifactory` (gateway, `ghcr.io/olafkfreund/aifactory:sha-1234567`),
     `fides-covered-server` (fides, `ghcr.io/olafkfreund/fides-server:a7f0738a98c185cecd42c647045c8beade1643ac`),
     `fides-reporter-covered-reporter` (fides-reporter, `ghcr.io/olafkfreund/fides-k8s-reporter:latest`),
     `uncovered-in-ephemeralcontainer` (factory, container `busybox:1.36`,
     ephemeralContainers `[{name: debug, image: ghcr.io/olafkfreund/not-a-rule:1}]`).
   - In `kyverno-test.yaml` add results: factory rule `fail` for
     `factory-uncovered-fides-server`, `uncovered-in-ephemeralcontainer`;
     gateway rule `fail` for `gateway-uncovered-pfactory`, `skip` for
     `gateway-covered-aifactory`; fides rule `fail` for
     `fides-uncovered-aifactory`, `fides-reporter-uncovered-port443`, `skip`
     for `fides-covered-server`, `fides-reporter-covered-reporter`.
     One line of comment per new block citing Factory#3665.
   → verify: `kyverno test apps/kyverno-policies/tests -f kyverno-test.yaml`
     passes every case, and the case count rose by 8.
   Traps: these tests never send the CLI to a registry (coverage rule only);
   do not add `verify-factory-image-signatures` to this suite. Existing
   resources must not change.

4. (lead, no file edits) Tests, mutation checks, and other suites (see Tests).

## Tests

- `python3 apps/kyverno-policies/assert-signature-lists-agree.py` → `ok`.
- Mutation checks on a scratch copy (revert each): drop `aifactory@` from
  gateway mirror; add `pfactory:` to gateway mirror; delete the fides
  coverage rule; delete fides signature + coverage rules; add
  `namespaces: [factory, newns]` to a signature rule; add
  `selector: {matchLabels: {a: b}}` to a signature rule's resources; rename a
  glob to `ghcr.io/olafkfreund/a.b:*`; set a coverage rule's namespaces to
  `[fides*]` → each prints `::error` and exits 1.
- Live (read-only, after merge, for the user): ephemeral-container admission is
  evidenced by Kyverno source and webhook config, not exercised here.
- `kyverno test` on every `apps/kyverno-policies/tests/kyverno-test*.yaml` → pass.
- `kyverno apply` of both policy files against a scratch busybox-only Pod in
  `factory` (third-party, so no registry call) → no policy validation error.
- `python3 apps/kyverno-policies/assert-mutate-idempotent.py` if runnable → unchanged.

## Rollback

Revert the PR. Live emergency: `apps/kyverno-policies/PANIC.sh 1` returns both
policies to Audit.
