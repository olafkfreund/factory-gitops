---
status: draft
issue: 265
spec: spec/2026-10-22-265-audit-after-id-loop.md
---

# Plan: audit-siem-forward after_id page loop

Approved decisions (from the spec):

- `read_audit(base, api_key, after_id)` calls
  `/api/audit?after_id=<n>&limit=500` (`LIMIT = 500`).
- Pure `is_paged(entries, after_id)`: all ids `> after_id` and strictly
  ascending.
- `pump(fetch, send, hwm)` loops at most `MAX_PAGES = 20` times. Not paged →
  old CFactory: `find_gap` → exit 6 with nothing sent, else forward
  `select_new` once and stop. Paged → forward the page, advance `hwm` only
  after `send` succeeds, stop on a page shorter than `LIMIT`. Cap reached →
  `WARN:` line, exit 0. Exit codes unchanged (3 read, 5 ingest, 6 gap).
- `main()` reads the hwm, then calls `pump`.
- Selftest: multi-page paging, old-CFactory fallback (with and without gap),
  page cap, ingest failure on page 2.

## Steps

1. `apps/audit-siem-forward/manifests/manifests.yaml` (embedded `forward.py`):
   add `LIMIT`/`MAX_PAGES` next to `PAGE` (~L71); `is_paged()` after
   `find_gap()` (~L94); `after_id` param on `read_audit()` (~L124); new
   `pump()` before `main()`; `main()` (~L201-236) reads hwm then returns
   `pump(...)`; docstring mentions paging; `_selftest()` gains the four cases.
   → verify by `python3 .github/scripts/extract_embedded_script.py apps/audit-siem-forward/manifests/manifests.yaml forward.py /tmp/asf.py && python3 /tmp/asf.py selftest` → `selftest OK`.
   Traps: YAML block scalar, keep the 4-space indent before Python; stdlib only;
   CI already runs this selftest (`job-watchdog-test.yml`), no workflow change.

## Tests

- Step 1 command prints `selftest OK`; with `is_paged` forced to `True` the
  old-CFactory case fails.
- CI `job-watchdog-test.yml` green.

## Rollback

Revert the PR commit; the forwarder returns to the single 100-row read with
the #288 gap alert.
