---
status: draft
issue: 313
spec: spec/2026-10-24-313-openobserve-retention.md
---

# Plan: pin OpenObserve retention

Decisions: pin `ZO_COMPACT_DATA_RETENTION_DAYS=3650` (confirmed v0.90.3 default, never below it); post a bus heads-up before landing; doc follow-up in Factory.

## Steps

1. `apps/observe/manifests/manifests.yaml` after the `ZO_INGEST_ALLOWED_UPTO` line (~151): add the env var with a comment on why it must stay at least the backfill window. Verify: the repo's manifest validation (kubeconform/CI) passes; `grep -n ZO_COMPACT_DATA_RETENTION_DAYS`.
2. Post the heads-up on the agent bus before merge. Verify: message appears in `recent`.
3. After merge, Factory PR updates `audit-logging.md` (separate PR).
   Traps: never set below 3650 while `ZO_INGEST_ALLOWED_UPTO` is 87600; no merge by the coder.

## Tests

CI manifest validation green.

## Rollback

Revert the commit; the default of 3650 applies again.
