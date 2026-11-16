---
status: approved
issue: 0
author: olafkfreund
---

# Intent: review-gap fixes in factory-gitops

## Problem

A review pass found five gaps (no tracking issue; found by the review-gaps pass):
1. `docs/security-alerts.md` documents a pager Alert on a hand-picked failing-status list that omits
   `reconcile_stalled`, `restore_failed`, `job_failed`, `missing` and others, so they would never page.
2. `apps/security-alerts/manifests/test_alerts.py` mocks `count()` and `emit()`, so a dropped auth.failure
   filter, window arithmetic, hits parsing or the failed-count check are untested.
3. `apps/backups/drill/test_emit.py` always answers `failed: 0`, so the "record rejected" exit is untested.
4. `apps/secret-rotation/manifests/test_report.py` stubs `k8s_meta()` and `emit()`, so the metadata-only
   Accept header and the no-values guard are untested.
5. The ephemeralcontainers Kyverno suite header and doc claim it pins subresource matching; the
   `values.subresources` block has no effect on `kinds: [Pod]` rules.

## Proposed outcome

1. The Alert filters on `NOT IN (healthy statuses)`; a test checks every known failing status matches.
2-4. Tests exercise the real functions with only the transport stubbed; each mutation named above fails.
5. Header and doc state what the suite proves; no behaviour change.

## Affected users and systems

Docs, tests and one CI workflow step. No runtime or cluster change.

## Constraints

No production code change. CI workflows keep running without a paths filter.

## Open questions

None.
