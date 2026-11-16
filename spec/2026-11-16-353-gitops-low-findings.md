---
status: approved
issue: 353
intent: intent/2026-11-16-353-gitops-low-findings.md
---

# Spec: four LOW findings

## Design

1. `report.py`: `alert()` takes `(name, status, age, max_age)` and handles `overdue` and `missing`
   (own title and body, same per-name dedup marker). Exit code stays 0 for `missing`. Add
   `'missing'` to the pager filter list in `docs/security-alerts.md`. Test: 404 with a token opens
   one issue.
2. `fetch.sh`: capture `mc find` into a variable first (`list="$(mc find ...)" || fail fetch_list_failed`),
   then sort and tail. `test-fetch.sh`: the fake mc returns find output newest-first (so no-sort
   picks the oldest), and `FAIL_FIND` / `FAIL_CP` make find or cp exit 1; assert
   `fetch_list_failed` and `fetch_copy_failed`.
3. `job-health-watchdog.md`: replace `status != 'ok'` with the explicit non-healthy list, explain why.
4. `docs/restore.md`: section explaining the Progressing state and the one-line remedy.

## Alternatives rejected

- `set -o pipefail` in fetch.sh: not POSIX sh in the pinned image. Capture-first is portable.
- Exit 1 on `missing`: would make the report job red for a finding; against the watchdog rule.
- Immediate-binding class or a dummy consumer for the PVC: changes storage behaviour for cosmetics.
- Custom Argo health check in argocd-cm: bootstrap-only, not managed by Argo here.

## Risks

An issue per missing Secret per rename until POLICY is updated (deduped while open). Low.

## Verification

`python3 apps/secret-rotation/manifests/test_report.py`; `sh apps/backups/drill/test-fetch.sh`
(needs the pinned mc image; run here with a stub mc, plus a mutation without `sort` must fail).
