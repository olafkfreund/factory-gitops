---
status: draft
issue: 353
spec: spec/2026-11-16-353-gitops-low-findings.md
coders:
  1: lead
  2: lead
  3: lead
reviewers:
  - codex
---

# Plan: four LOW findings

Spec decisions carried over: surface `missing` by issue plus pager filter (exit stays 0);
capture-first in fetch.sh and a failing-capable test; explicit status list in the watchdog doc;
document the Progressing PVC, no manifest change. Coders: the lead does all steps (each is a
small edit; a handoff costs more than it saves).

## Steps

1. `apps/secret-rotation/manifests/report.py` (alert, main) and `test_report.py`: handle `missing`
   -> `python3 apps/secret-rotation/manifests/test_report.py`. Traps: do not touch apps/security-alerts.
2. `apps/backups/drill/fetch.sh` and `test-fetch.sh`: capture-first, failing-capable test
   -> `sh test-fetch.sh` with a stub mc; removing `sort` must fail it.
3. `docs/security-alerts.md`, `docs/job-health-watchdog.md`, `docs/restore.md`.

## Tests

As in steps; CI: secret-rotation-test, backup-drill-test (real mc image).

## Rollback

Revert the PR; nothing is deployed outside Argo syncing the unchanged manifests.
