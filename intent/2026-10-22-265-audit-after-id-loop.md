---
status: approved
issue: 265
author: olafkfreund
---

# Intent: audit-siem-forward pages the audit chain from its high-water mark

## Problem

`audit-siem-forward` reads only the newest 100 rows of CFactory
`GET /api/audit`. Since #288 it alerts (exit 6) when rows are hidden behind
that page, but it still cannot catch up: after a backlog of more than 100 rows
it stalls and alerts until someone backfills by hand. CFactory#491 (merged)
added `GET /api/audit?after_id=N&limit=M` (rows `id > N`, ascending,
`limit` 1..500), so the forwarder can now read every row.

## Proposed outcome

Each run reads from its high-water mark in pages of 500 until a short page,
forwarding each page in id order. A backlog is drained over one or a few runs
instead of raising a permanent gap alert. Against a CFactory without #491 the
run behaves exactly as today, including the #288 gap alert.

## Affected users and systems

- `apps/audit-siem-forward` CronJob (namespace `factory`) and its embedded
  `forward.py`.
- The `audit_chain` OpenObserve stream.
- CI `job-watchdog-test.yml`, which already runs this selftest.

## Constraints

- Stdlib-only, inside the existing ConfigMap script.
- Never skip rows silently; never advance the hwm past a row not yet seen.
- Must stay safe against an older CFactory that ignores the query params.
- Bounded run time: cap the pages per run.
- Out of scope: the backfill comparison below `hwm=14282` (issue step 3, needs
  the cluster) and failed-pod log retention (step 4).

## Open questions

None. Decision taken: page with `after_id`, fall back to the single read on an
old CFactory.
