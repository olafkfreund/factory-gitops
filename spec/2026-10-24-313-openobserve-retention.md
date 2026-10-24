---
status: approved
issue: 313
intent: intent/2026-10-24-313-openobserve-retention.md
---

# Spec: pin OpenObserve retention

## Design

Add `ZO_COMPACT_DATA_RETENTION_DAYS=3650` to the observe Deployment env in `apps/observe/manifests/manifests.yaml`, beside `ZO_INGEST_ALLOWED_UPTO`.
Why 3650: confirmed in upstream source at tag v0.90.3 (`src/config/src/config.rs:1905`, `default = 3650`), the image version pinned at line 131. Pinning the default changes no behaviour and deletes nothing, and 3650 is above the 395-day audit minimum.
`ZO_INGEST_ALLOWED_UPTO` backfills 10 years by event time, so any value below 3650 would delete backfilled audit rows on the next compaction.
The pod restarts once on rollout.
A follow-up Factory doc PR maps the windows in `audit-logging.md`.

## Alternatives rejected

Exactly 395: deletes rows older than 395 days that the forwarder backfilled, irreversible. Leave unset: the window stays an unstated default.

## Risks

A future image bump could change the upstream default; the explicit pin makes that irrelevant. Shortening later is a separate, deliberate change.

## Verification

Manifest validation CI passes; after sync the pod env shows the variable; a bus heads-up is posted before landing.
