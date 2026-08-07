# kyverno-runner-probe — runner-image signature coverage, measured (Factory#562)

`verify-tfactory-runner-signature` (in `apps/kyverno-policies`) covers the
eleven `ghcr.io/olafkfreund/tfactory-runner-*` images — the sandbox in which
AI-generated code is built and executed. Runner Pods are ephemeral Job Pods, so
the rule contributes **zero** standing PolicyReport results:

```
namespace factory: 65 results, 65 pass, 0 fail
results attributable to verify-tfactory-runner-signature: 0
```

The board is green because the rule has nothing to report on. Two of the eleven
are provably unverifiable at admission today. **Green means absent, not
covered.**

This CronJob turns that into a measurement. Every six hours it dry-runs one
synthetic Pod carrying all eleven images plus two canaries through the real
admission path and records the per-image verdict.

It answers two questions per image, and keeps them apart:

1. **Does it verify?** — the signature verdict, from Kyverno's `Warning` headers.
2. **Did anything look?** — the coverage verdict (Factory#574), from the
   `kyverno.io/verify-images` annotation on the same response. An image no rule
   *names* is silent in every reporting channel, and silence must not read as a
   pass.

## Reading it

```
kubectl -n factory logs job/<most recent kyverno-runner-probe job>
```

OpenObserve, stream `image_signature_probe`:

```sql
SELECT status, passed, failed, canary_ok, reasons
FROM "image_signature_probe" ORDER BY _timestamp DESC
```

Three statuses, and the third is the one this app exists for:

| `status`      | Meaning | Exit |
|---------------|---------|------|
| `pass`        | Every image verified, and the canary proved the rule ran. | 0 |
| `fail`        | The rule ran and found unverifiable images. `reasons` says why. | 0 |
| `not_checked` | **No verdict was established.** The canary did not come back red, so the rule did not run or ran degraded. Every `pass` in that record is an artefact. | 2 or 3 |

`fail` exits 0 on purpose: the exit code answers "is this evidence
trustworthy", not "is the fleet healthy". A probe that goes red on its findings
is indistinguishable from a probe that is itself broken — the same reasoning as
`apps/job-watchdog`, which already watches this CronJob for failure and for
staleness and needs no wiring here.

## The two distinctions it refuses to blur

**Verified vs not checked.** Silence for an image means "passed" only if the
rule demonstrably ran. The probe carries a twelfth image whose verdict is known
and must be red — an old, public, genuinely unsigned tag of
`tfactory-runner-pytest`, published before TFactory#947/#949 added signing. Its
sibling `tfactory-runner-pytest:latest` is in the list and must pass in the same
run. If the canary comes back silent, the whole run reports `not_checked`.

**Bad signature vs cannot read the registry.** Kyverno writes `unverified
image` for both, and that ambiguity hid a fleet-wide DNS outage for weeks behind
what looked like a signing problem (Factory#430). Every failure is classified
from the message text into `signature`, `registry_auth`, `registry_missing`,
`transport`, or — never guessed — `unknown`. `transport` is matched first, so a
Sigstore outage can never be misread as a signature verdict.

**Unsigned vs unexamined (Factory#574).** An image that no `imageReferences`
glob *names* is not verified, it is unlooked-at — and it is silent in both
reporting channels, so the probe used to report it `pass`. Kyverno mutates the
object it admits with `kyverno.io/verify-images`, a map of every image a rule
actually examined, and a dry-run create returns that mutated object. Anything
missing from the map is reported `not_covered`, never `pass`.

```
{"ghcr.io/olafkfreund/skillai:5ecfd51ba504":"pass",
 "ghcr.io/olafkfreund/tfactory-runner-nix:latest":"fail",
 "ghcr.io/olafkfreund/tfactory-runner-pytest:latest":"pass"}
```

Present, either value, means a rule named it — covered, with its signature
verdict as the separate axis above. This is why `require-first-party-signature-
coverage` can stay a `validate` rule: that rule holds the board for long-running
Pods, and this holds the ephemeral Job Pods it cannot see.

## The two canaries

| canary | must report | catches |
|---|---|---|
| `tfactory-runner-pytest:<pre-signing sha>` | `signature` | the rule did not run; **and** the `tfactory-runner-*` glob being deleted, which would flip it to `not_covered` |
| `kyverno-coverage-canary-never-covered:v0` | `not_covered` | a glob widened to match everything, manufacturing coverage |

Neither is sufficient alone. Running the probe into a namespace no rule matches
satisfies the coverage canary — `not_covered`, exactly as demanded — while the
signature canary correctly voids the run.

## Current verdict

9 pass, 3 fail, both canaries holding.

- `tfactory-runner-nix`, `tfactory-runner-portal-ui` — `registry_auth`. Private
  GHCR packages, Kyverno reads ghcr.io anonymously (Factory#563).
- `odin` — was `not_covered`; **closed by Factory#572** on 2026-08-07. The GHCR
  package was made public, `verify-odin-signature` landed in
  `verify-factory-image-signatures`, and odin now reports `pass` here on its
  own. It stays in the probe's image list — removing it would drop a real
  signature verification for no gain. One caveat that did not apply while it was
  uncovered: its pinned tag is now actually fetched and verified, so a stale pin
  still passes while describing a HISTORICAL image. The standing PolicyReport,
  not this row, is the channel that follows the running Pod.

**Factory#522 must not read the at-rest board as evidence while these stand**:
at Enforce this denies every build and verify Job in the fleet.

### The #522 gate has a third term now

Factory#562 defined the Enforce criterion as `status=pass AND canary_ok=true`
on a recent `image_signature_probe` record. There are two canaries, so it is:

```sql
status = 'pass' AND canary.ok AND coverage_canary.ok
```

`status=pass` alone is not enough and never was — a run where nothing executed
reports `not_checked`, but a run where the coverage half was fooled could
otherwise report `pass` on images nobody looked at.

## Cost

12 cosign verifications per run x 4 runs a day = ~48 registry+Rekor round trips
a day, ~2/hour. Factory#444 measured the existing background scan at ~50/hour.
This adds roughly 4%. Runs are 6h apart and Kyverno's image-verify cache TTL is
60m, so every run is cold — those are fresh calls, not cache hits.

The coverage check adds **zero** to that. It reads a field of a response the
probe already receives, and the two images added for it (`odin` and the coverage
canary) are named by no rule, so Kyverno fetches nothing for them — being
unexamined is the entire point of carrying them.

## Self-test

The classifier and the verdict fold are pure and testable without a cluster:

```
kubectl -n factory get cm kyverno-runner-probe-script -o jsonpath='{.data.probe\.py}' > probe.py
python3 probe.py selftest
```

It asserts, among other things, that Factory#430's verbatim DNS-outage message
classifies as `transport` and never as a signature verdict, and that an image
absent from the verify-images annotation reports `not_covered` and never `pass`.

The suite can fail. Removing the coverage guard turns
`assert v[ok]["reason"] == "not_covered"` red; dropping the `FIRST_PARTY` scope
turns the `postgres:16` out-of-scope case red.
