---
status: approved
issue: 265
intent: intent/2026-10-22-265-audit-after-id-loop.md
---

# Spec: audit-siem-forward after_id page loop

## Design

Chosen (the user's decision for this wave, issue step 2, forwarder side): page
`/api/audit` with `after_id`, and fall back to the existing single read when
the server ignores the params.

In the embedded `forward.py` (`apps/audit-siem-forward/manifests/manifests.yaml`):

- `read_audit(base, api_key, after_id)` requests
  `/api/audit?after_id=<after_id>&limit=500`.
- New pure `is_paged(entries, after_id)`: true when every id is `> after_id`
  and ids are strictly ascending. CFactory#491 always satisfies this. An old
  CFactory returns newest first, so any reply of two or more rows fails it; a
  reply of 0 or 1 rows passes, and that is still correct because an old
  server returning fewer than 100 rows has returned the whole chain.
- New `pump(fetch, send, hwm)` holds the loop, with `fetch` and `send` injected
  so the selftest can drive it with fake servers. Up to `MAX_PAGES = 20` times:
  fetch after `hwm`;
  - not paged: old CFactory. Run the #288 path on that reply: `find_gap` →
    exit 6 without forwarding; else forward `select_new` and stop.
  - paged: forward the page in id order; only after `send` succeeds, set
    `hwm` to the last forwarded id. A page shorter than 500 means caught up.
  - reaching the cap logs `WARN: page cap ... reached` and exits 0; the next
    run continues from the sink's real max id.
  Exit codes are unchanged: 3 read failure, 5 ingest failure, 6 gap.
- `main()` reads the hwm first, then calls `pump`.
- `_selftest()` adds: multi-page paging over 1200 rows (3 pages, all ids, in
  order), old-CFactory fallback (forward when no gap, exit 6 and nothing sent
  when there is a gap), the page cap (exactly 20 pages, then stop), and an
  ingest failure on page 2 (exit 5, page 1 kept, nothing after it).

## Alternatives rejected

- **Read until empty, no cap.** A huge backlog would run past the 15-minute
  schedule and the Job deadline; the cap gives a bounded run and the next run
  carries on.
- **Detect the server version via a separate probe.** Extra call and coupling;
  the ordering check on the reply itself is enough.
- **Drop the single-read path.** Breaks the forwarder on a CFactory without
  #491 and loses the #288 gap alert there.

## Risks

- A page is accepted only if strictly ascending and above the hwm, so a bad
  reply cannot move the hwm backwards or skip rows; it falls back to #288.
- A partial failure mid-loop leaves earlier pages forwarded; the next run reads
  the real max from the sink and resumes, so no duplicates and no holes.
- 500 rows per ingest request is a bigger body than today's 100; still small.

## Verification

- `python3 .github/scripts/extract_embedded_script.py apps/audit-siem-forward/manifests/manifests.yaml forward.py /tmp/asf.py && python3 /tmp/asf.py selftest` prints `selftest OK`.
- CI `job-watchdog-test.yml` runs the same selftest green.
- Runtime check (blocked while the cluster is down): next CronJob run logs `OK`.
