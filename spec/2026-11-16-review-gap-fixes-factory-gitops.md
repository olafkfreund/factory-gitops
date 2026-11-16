---
status: approved
issue: 0
intent: intent/2026-11-16-review-gap-fixes-factory-gitops.md
---

# Spec: review-gap fixes in factory-gitops

## Design

1. Invert the documented Alert to `status NOT IN ('ok','due_soon','unstamped','not_configured','no_field','no_source')`:
   new failing codes page by default. `apps/security-alerts/manifests/test_alert_filter.py` parses the doc
   and the watchdog `CRITICAL_CODES` and asserts no failing status is in the healthy list; added to
   `.github/workflows/security-alerts-test.yml`.
2. `test_alerts.py`: reload `alerts`, stub only `urlopen`; assert the SQL, window, `n` parsing and `failed` handling via `main()`.
3. `test_emit.py`: stub answers a configurable `failed`; assert `source`, `namespace`, and exit 1 on reject.
4. `test_report.py`: reload `report`, stub `urlopen`; assert Accept header, refusal of `data`/`stringData`, `emit()` result, `cronjob` field.
5. Reword the suite header and `docs/image-signature-admission.md`; the live `kubectl debug` check stays manual.

## Alternatives rejected

- Keep the IN list and extend it: goes stale with each new code.
- Make the Kyverno suite prove routing: needs a live webhook; out of scope.

## Risks

`no_source` is excluded from the pager because the auth-stream case already fails the CronJob and is reported by job-watchdog.

## Verification

Run the four Python tests; mutation checks (empty where clause, `if False` on the guard, `if failed` removal) fail them.
