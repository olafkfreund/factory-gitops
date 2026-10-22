---
status: draft
issue: 265
spec: spec/2026-10-22-265-audit-gap-alert.md
---

# Plan: audit-siem-forward gap alert

Approved decisions (from the spec):

- Pure `find_gap(entries, hwm)` returns `(hwm + 1, min_id - 1)` when
  `len(entries) >= PAGE` (`PAGE = 100`, CFactory's `AuditStore.list` limit) and
  `min(id) > hwm + 1`, else `None`.
- `main()` checks it after the hwm query and before `select_new`; on a gap it
  prints `ALERT: gap ids A..B not visible via /api/audit (hwm=H, page oldest=M)`
  and returns 6 **without forwarding**, so the hwm never skips the hole.
- The selftest covers gap, contiguous full page, and short page.
- CI runs this selftest. Paging, backfill and pod-log retention are out of scope.

## Steps

1. `apps/audit-siem-forward/manifests/manifests.yaml` (embedded `forward.py`):
   - add `PAGE = 100` and `find_gap()` next to `select_new()` (~L83);
   - in `main()` (~L200), after the hwm `try` block, call it and return 6 with
     the ALERT line;
   - document exit 6 in the module docstring;
   - `_selftest()`: 100 rows with ids 201..300 and hwm=150 → `(151, 200)`;
     ids 151..250 with hwm=150 → `None`; 3 rows ids 201..203 with hwm=0 → `None`.
   → verify by `python3 .github/scripts/extract_embedded_script.py apps/audit-siem-forward/manifests/manifests.yaml forward.py /tmp/asf.py && python3 /tmp/asf.py selftest` → `selftest OK`.
   Traps: YAML block scalar, keep 4-space YAML indent before Python; stdlib only.
2. `.github/workflows/job-watchdog-test.yml`: append an extract + `Selftest (audit-siem-forward)` step in the same shape as the fleet-match one, and update the header count.
   → verify by `python3 -c "import yaml,sys;yaml.safe_load(open('.github/workflows/job-watchdog-test.yml'))"`.
   Traps: keep the job name (required check).

## Tests

- Step 1 command prints `selftest OK`; with the `find_gap` call/body reverted, the gap assertion fails.
- CI `watchdog.py selftest` green.

## Rollback

Revert the PR commit; the forwarder goes back to silent behaviour.
