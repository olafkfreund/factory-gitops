---
status: approved
issue: 353
author: olafkfreund
---

# Intent: four LOW findings in secret-rotation, backup drill, watchdog doc and the backups app

## Problem

1. `apps/secret-rotation/manifests/report.py`: a 404 on a Secret gives status `missing`, exit 0,
   and `alert()` handles only `overdue`. A deleted or renamed Secret is never surfaced, and the
   pager filter in `docs/security-alerts.md` (#352) does not list `missing`.
2. `apps/backups/drill/fetch.sh`: `latest="$(mc find ... | sort | tail -n 1)" || fail fetch_list_failed`
   tests only `tail`, so `fetch_list_failed` can never fire (a failed `mc find` reads as
   `no_dump_found`). `test-fetch.sh` cannot tell sort from no sort (the fake find returns files in
   directory order) and has no failed-list or failed-copy case.
3. `docs/job-health-watchdog.md` says `WHERE status != 'ok'` covers job health, but the stream now
   carries non-failure statuses from several writers.
4. Argo CD app `backups` is Synced but Progressing for hours.

## Verified against main (0ec1310)

All of 1 to 3 confirmed in the files above. 4: the only non-healthy resource is PVC
`minio-backup-local` (Pending, `WaitForFirstConsumer`, event "waiting for first consumer"); no hook
is involved. The CronJob that mounts it first runs at 03:30. Not a manifest bug.

## Proposed outcome

A missing Secret opens an issue and is paged; the fetch error path and its test can fail; the doc
tells the truth; the Progressing state is documented as expected, with the one-command remedy.

## Affected users and systems

Owner (pager, restore drill). No live-cluster change.

## Constraints

Do not touch `apps/security-alerts`. Exit codes keep the watchdog rule: findings go in the stream
and issues, not the exit code.

## Open questions

None. Decision (owner delegation 2026-11-16): for 4, document instead of adding a throwaway
consumer or changing the storage class (least risky; self-heals at 03:30).
