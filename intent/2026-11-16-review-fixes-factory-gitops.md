---
status: approved
issue: 347
author: olafkfreund
---

# Intent: fix three defects found by the cross-PR review (#347, #345)

## Problem

1. The nightly MinIO snapshot (`apps/backups/minio-local/minio-local.sh`) mirrors a live
   bucket, then lists and hashes the same live bucket. Any object written or overwritten
   between the mirror and the verify loop fails the run and deletes `.tmp-`. With
   `backoffLimit: 1` the same race can hit the retry; after 25 h the restore drill goes red.
2. The MinIO restore drill (`apps/backups/drill/minio-drill.sh`) restores the same 20
   alphabetically first objects of each bucket every night. Recent objects are never restored,
   so a restore or encryption fault limited to newer objects is never seen.
3. `apps/security-alerts/manifests/alerts.py`: a 404 on the `audit_chain` stream gives status
   `no_source` and exit 0. No issue, no page, and job-watchdog sees a healthy CronJob, so the
   auth-failure rule is silently dead.

## Proposed outcome

1. A write during the snapshot cannot fail the run. The snapshot is one copy and
   its MANIFEST describes exactly what was copied. Each object is a valid version; the snapshot
   is not a cross-object point in time (it never was).
2. The drill sample changes from night to night and so covers all objects over time.
3. A missing auth stream makes the CronJob fail, so job-watchdog reports it.

Each fix has a regression test that fails before the fix.

## Affected users and systems

`apps/backups` (minio-backup-local, minio-restore-drill CronJobs), `apps/security-alerts`
(security-alerts CronJob), `docs/security-alerts.md`. Argo CD syncs the CronJob scripts on merge.

## Constraints

- Smallest change per script; no new image, dependency or manifest field.
- The drill keeps checking restored bytes against the snapshot MANIFEST, never live data.
- The optional egress rule keeps `no_source` as a non-error (by design).
- No live cluster action.

## Open questions

None.
