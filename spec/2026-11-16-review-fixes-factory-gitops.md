---
status: approved
issue: 347
intent: intent/2026-11-16-review-fixes-factory-gitops.md
---

# Spec: review fixes in factory-gitops

## Design

1. `minio-local.sh`: after `mc mirror`, list and hash the files of the snapshot tree
   (`find "$tmp/$bucket" -type f`) and write MANIFEST from those hashes. The live bucket is read
   only by `mc mirror`, which verifies its own transfers. Objects written after the mirror
   appear in the next night's snapshot. The old `source objects == snapshot files` count check
   becomes trivially true and is removed; a failed mirror still fails the run.
2. `minio-drill.sh`: replace `sort -k2` with a deterministic shuffle seeded by the UTC date
   (`SAMPLE_SEED`, default `date -u +%Y%m%d`): `awk` prefixes each line with `rand()`, `sort`,
   `cut`. The seed variable lets the test pin it. Same sample within a day, different across
   days, every object reachable over time. Size cap and `SAMPLE_COUNT` logic unchanged.
3. `alerts.py` `main()`: a `no_source` result for `auth_failure_spike` sets `rc = 1`. The record
   keeps status `no_source`. Egress `no_source` stays rc 0. `docs/security-alerts.md` says so.

## Alternatives rejected

- 1: retry the mirror and verify loop. The race remains and grows with bucket size.
- 1: keep live comparison but ignore mismatches. Gives no signal for a bad copy and keeps the
  per-object `mc cat` load.
- 2: newest-N by mtime. The mirror does not preserve source mtimes, and it would never cover
  old objects. Random rotation covers both.
- 2: random without a seed. Not reproducible when a night fails.
- 3: raise a GitHub issue for `no_source`. The CronJob failure already reaches job-watchdog;
  a second channel adds code and state.

## Risks

- 1: a copy corrupted in transit that `mc mirror` does not detect is no longer caught by the
  live comparison, and the MANIFEST would record the bad bytes (the drill checks restores
  against the MANIFEST, so it would not see it either). Accepted: the live comparison could not
  tell corruption from a concurrent write. A `shortcut:` comment records it.
- 2: a given object may go unsampled for many nights (20 of N objects per night). Coverage
  over time is probabilistic, not complete; full coverage is out of scope.
- 3: a cluster where audit-siem-forward is not yet deployed will now show the CronJob as failed.
  That is the intended signal.

## Verification

- `minio-local/test.sh`: a hook writes a new object and overwrites one right after the mirror;
  the run must succeed and the generation must hold the mirror-time content. Fails before.
  The failed-read case now uses a failing mirror.
- `drill/test-minio.sh`: 10 objects, `SAMPLE_COUNT=3`, seeds 1..6; the union of samples must
  include an object outside the first three by path, each run restores 3, the same seed twice
  gives the same sample, and at least two seeds give different samples. Fails before.
- `test_alerts.py`: a new case, auth 404 gives rc 1 and status `no_source`; the existing egress
  404 case keeps rc 0. Fails before.
- Run: the two mc tests in the pinned image as `backup-drill-test.yml` does; the alerts test
  with python3.
