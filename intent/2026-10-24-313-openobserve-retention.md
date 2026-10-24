---
status: draft
issue: 313
author: olafkfreund
---
# Intent: pin an explicit OpenObserve retention of at least 395 days

**Problem:** `apps/observe/manifests/manifests.yaml` sets no `ZO_COMPACT_DATA_RETENTION_DAYS`, so audit_chain retention in OpenObserve is an unstated default, and Factory `audit-logging.md` has no per-framework window (Factory#313).
**Outcome:** The Deployment pins the retention explicitly (>= 395 days), and `audit-logging.md` maps PCI 12m/3m hot and AU-11 to Postgres 395d, OpenObserve and MinIO.
**Affected:** factory-gitops `apps/observe`; Factory `docs/compliance/policies/audit-logging.md`; the observe pod restarts once.
**Constraints:** Must not shorten current retention: `ZO_INGEST_ALLOWED_UPTO` backfills 10 years by event time, so a 395 pin could delete older audit rows. Post a heads-up on the agent bus before landing.
**Open questions:** Pin the upstream default (3650, to confirm for v0.90.3) or exactly 395? Default: pin the confirmed default.
