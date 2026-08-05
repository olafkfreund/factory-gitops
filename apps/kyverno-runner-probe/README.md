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
synthetic Pod carrying all eleven images plus a canary through the real
admission path and records the per-image verdict.

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

## Current verdict

9 of 11 pass. `tfactory-runner-nix` and `tfactory-runner-portal-ui` fail with
`registry_auth` — private GHCR packages, Kyverno reads ghcr.io anonymously
(Factory#563). That is a real gap, not a probe artefact, and **Factory#522 must
not read the at-rest board as evidence while it stands**: at Enforce this denies
every build and verify Job in the fleet.

## Cost

12 cosign verifications per run x 4 runs a day = ~48 registry+Rekor round trips
a day, ~2/hour. Factory#444 measured the existing background scan at ~50/hour.
This adds roughly 4%. Runs are 6h apart and Kyverno's image-verify cache TTL is
60m, so every run is cold — those are fresh calls, not cache hits.

## Self-test

The classifier and the verdict fold are pure and testable without a cluster:

```
kubectl -n factory get cm kyverno-runner-probe-script -o jsonpath='{.data.probe\.py}' > probe.py
python3 probe.py selftest
```

It asserts, among other things, that Factory#430's verbatim DNS-outage message
classifies as `transport` and never as a signature verdict.
