---
status: approved
issue: 265
author: olafkfreund
---

# Intent: audit-siem-forward must notice when it cannot see older audit rows

## Problem

`audit-siem-forward` reads CFactory `GET /api/audit`, which returns only the
newest 100 rows (newest first, no paging). It forwards rows with `id > hwm`
from that one page. If more than 100 rows are written between two successful
runs (a failure window, or a busy 15 minutes), rows `hwm+1 .. oldest-1` are
never forwarded, and the run still logs `OK` and exits 0. The SIEM copy of the
audit chain can have holes that nothing reports.

## Proposed outcome

When the page is full and its oldest id is above `hwm + 1`, the run fails with
`ALERT: gap ids <hwm+1>..<min-1> not visible via /api/audit`. The failed Job is
picked up by job-watchdog like every other `ALERT:` exit, and it keeps failing
on every run until the gap is dealt with.

## Affected users and systems

- `apps/audit-siem-forward` CronJob (namespace `factory`).
- The `audit_chain` OpenObserve stream and whoever reads it.
- job-watchdog (no change; it already reports failed Jobs).

## Constraints

- Stay stdlib-only, inside the existing ConfigMap script.
- Must not advance the high-water mark past a hole.
- Out of scope (need a CFactory change or the live cluster): `after_id` paging
  on `/api/audit` and a forwarder page loop (issue step 2), the backfill
  comparison below `hwm=14282` (step 3), failed-pod log retention (step 4).

## Open questions

None. Decision taken: alert without forwarding the visible rows.
