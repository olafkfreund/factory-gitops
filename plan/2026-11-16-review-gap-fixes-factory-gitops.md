---
status: draft
issue: 0
spec: spec/2026-11-16-review-gap-fixes-factory-gitops.md
coders:
  1-5: lead (small edits, no handoff; codex is available but a handoff costs more than these)
reviewers:
  - codex
---

# Plan: review-gap fixes in factory-gitops

Decisions as in the spec: NOT IN healthy-status Alert plus a doc-parsing test; real-function tests with only
`urlopen` stubbed for alerts, report and emit; honest wording for the Kyverno suite.

## Steps

1. docs/security-alerts.md (Routing section) and apps/security-alerts/manifests/test_alert_filter.py plus the workflow step → `python3 apps/security-alerts/manifests/test_alert_filter.py`
2. apps/security-alerts/manifests/test_alerts.py end-to-end block → `python3 apps/security-alerts/manifests/test_alerts.py`
3. apps/backups/drill/test_emit.py → `python3 apps/backups/drill/test_emit.py`
4. apps/secret-rotation/manifests/test_report.py → `python3 apps/secret-rotation/manifests/test_report.py`
5. kyverno ephemeralcontainers test header and docs/image-signature-admission.md wording → read-back

## Tests

All four Python scripts print ok; CI workflows green.

## Rollback

Revert the PR; nothing deployed changes.
