---
status: approved
issue: 265
intent: intent/2026-10-22-265-audit-gap-alert.md
---

# Spec: audit-siem-forward gap alert

## Design

Chosen (the user's decision for this wave, issue step 1): detect the gap in the
forwarder and fail loudly, without forwarding anything on that run.

- New pure function `find_gap(entries, hwm) -> tuple[int, int] | None` in the
  embedded `forward.py` (`apps/audit-siem-forward/manifests/manifests.yaml`).
  It returns `(hwm + 1, min_id - 1)` when `len(entries) >= PAGE` (100, the
  CFactory `AuditStore.list` limit) and `min_id > hwm + 1`; else `None`.
  A page shorter than 100 is the whole chain, so it cannot hide rows.
- `main()`: after reading the high-water mark and before `select_new`, if
  `find_gap` returns a range, `eprint("ALERT: gap ids A..B not visible via
  /api/audit (hwm=..., page oldest=...)")` and return 6. Nothing is forwarded,
  so the hwm stays below the hole and every later run alerts again until the
  hole is backfilled (or paging lands in CFactory).
- `_selftest()` gains a gap case and two no-gap cases (contiguous full page;
  short page).
- `.github/workflows/job-watchdog-test.yml` gains a step that extracts and runs
  this selftest. Today nothing runs it in CI; the workflow header asks that
  every embedded script be added there.

## Alternatives rejected

- **Forward the visible rows, then alert.** The hwm would move past the hole,
  so the next run sees no gap: the alert fires once and the hole goes silent.
- **`after_id` paging on CFactory `/api/audit` plus a forwarder page loop.** The
  real fix, but a cross-repo CFactory change; it belongs in its own CFactory
  issue (issue step 2).
- **Log a warning and exit 0.** Nobody reads successful Job logs; the fleet
  alert path is a failed Job.

## Risks

- After a long outage the forwarder stops forwarding until someone acts. This
  is intended: a stalled, alerting forwarder is better than a silent hole.
- A first run against an empty stream (`hwm=0`) with more than 100 rows alerts
  permanently. Correct: the history really is not reachable.
- An id skipped by a rolled-back transaction exactly at `hwm+1` with 100+ new
  rows would be a false alarm. Rare; the alert message names the range to check.

## Verification

- `python3 .github/scripts/extract_embedded_script.py apps/audit-siem-forward/manifests/manifests.yaml forward.py /tmp/asf.py && python3 /tmp/asf.py selftest` prints `selftest OK`, and fails with the `find_gap` check removed.
- CI `job-watchdog selftest` runs the new step green.
- Runtime check (blocked while the cluster is down): next CronJob run logs `OK` at `hwm=14282`.
