# Automated compliance-evidence collection

Implements Factory#324 (evidence and audit-readiness). Before this, compliance
evidence was gathered on demand, the week an assessor asked for it. This gives
the fleet a durable, timestamped evidence trail: a daily Kubernetes CronJob
(`apps/evidence-collector`) snapshots the evidence the cluster can produce on its
own into a dedicated, versioned and lifecycled MinIO bucket, one dated prefix per
run. Control-plane services push the evidence the cluster cannot pull into a
documented drop path in the same bucket.

This document is what an assessor reads to know what exists, where it lands, how
long it is kept, and how to retrieve the evidence for a specific control.

## Where evidence lands

Bucket `factory-evidence`, created, versioned, and lifecycled by the MinIO
bucket-init Job (`apps/minio/manifests/manifests.yaml`), same place the
`factory-artifacts` and `factory-backups` lifecycles live.

```
factory-evidence/
  <YYYY-MM-DD>/                        one prefix per daily collector run
    audit-anchor.json                  CFactory audit-chain head + verdict
    config-baseline-images.json        running image@sha256 digests
    backups-index.json                 postgres backup objects that exist
    run-manifest.json                  what this run collected + push expectations
  control-plane-push/                  evidence the cluster cannot pull (see below)
    access-review/<org>-<YYYY-MM-DD>.ndjson
    trivy/<repo>-<YYYY-MM-DD>.json
    codeql/<repo>-<YYYY-MM-DD>.sarif
```

The dated prefix and the object's own last-modified timestamp both date every
artifact. Object versioning means an overwrite or delete leaves a recoverable
prior version.

## Schedule

- Collector CronJob: daily at 03:00 UTC (`apps/evidence-collector`). It runs
  after the 02:15 UTC Postgres backup (`apps/backups`) so the same run's
  `backups-index.json` reflects that morning's backup.
- One skipped run loses one daily snapshot; retention tolerates gaps.

## Retention

- Bucket-wide lifecycle rule: expire objects after 90 days, expire noncurrent
  (versioned) copies 30 days after they become noncurrent
  (`apps/minio/manifests/manifests.yaml`).
- 90 days matches the evidence floor already established for the
  `role=evidence` objects in `factory-artifacts` (#313, #321). It is a floor,
  not an aggressive purge: evidence that backs a verification claim or audit
  anchor must outlive the claim.
- Ceiling to know about: SOC 2's typical 12-month observation window wants a
  365-day retention. That is a one-line change to the ILM rule
  (`--expire-days 365`) when an audit period is actually scoped.

## What is collected, and by which side

Be honest about the boundary: a CronJob running inside the cluster can only
snapshot what the cluster exposes to it. Anything behind service auth, scoped to
a tenant, or produced off-cluster in CI must be pushed in by the producer.

### Auto-collected from gitops/cluster alone (the collector pulls these)

| Artifact | Source | How it is collected |
|---|---|---|
| `audit-anchor.json` | CFactory `GET /api/audit` | HTTP fetch, structural chain check (same logic as `apps/audit-anchor-alert/check.py`); records head entry hash, entry count, newest timestamp, verdict |
| `config-baseline-images.json` | Kubernetes API, `factory` namespace pods | ServiceAccount token, RBAC `pods: get,list`; records each container's resolved `imageID` (the `@sha256` digest actually running) |
| `backups-index.json` | MinIO `factory-backups/postgres/` | `mc ls` of the backup bucket; an empty list is recorded, not hidden |
| `run-manifest.json` | the run itself | records which artifacts succeeded and the expected control-plane push paths |

### Must be pushed by the control plane (the collector cannot pull these)

The collector cannot fetch these; it only records in `run-manifest.json` that
they are expected. The producing service or pipeline must write them into
`factory-evidence/control-plane-push/<source>/` using the shared `minio-creds`
S3 credentials (same env contract every service already uses:
`S3_ENDPOINT`/`S3_ACCESS_KEY`/`S3_SECRET_KEY`).

| Artifact | Producer | Why it cannot be auto-pulled | Drop path |
|---|---|---|---|
| Access-review NDJSON | AIFactory `GET /api/admin/access-review?org=<id>` (`access_review.py`) | Behind admin/owner auth and requires a specific org id; the collector has neither an admin token nor the tenant list | `control-plane-push/access-review/<org>-<YYYY-MM-DD>.ndjson` |
| Trivy scan results | GitHub Actions CI (Trivy P0 gate) | Produced off-cluster during CI; never runs in this cluster | `control-plane-push/trivy/<repo>-<YYYY-MM-DD>.json` |
| CodeQL results | GitHub Actions CI (CodeQL x5 repos) | Produced off-cluster during CI | `control-plane-push/codeql/<repo>-<YYYY-MM-DD>.sarif` |

Push contract: one dated object per source per run, written with
`mc cp` / any S3 client to the path above. The path is stable so an assessor
knows where to look and a freshness check can flag a missing or stale push.
Wiring the actual push from AIFactory and from the CI workflows is the
control-plane follow-up (tracked under #324); the drop path and lifecycle are
ready for it now.

## Mapping evidence to control domains

Each artifact maps to a control domain in `Factory/docs/compliance`. This is the
column an assessor uses to trace a control to its evidence.

| Evidence artifact | Control domain (Factory/docs/compliance) | What it demonstrates |
|---|---|---|
| `audit-anchor.json` | `policies/audit-logging.md` (#313) | The tamper-evident audit hash-chain is intact, non-empty, and fresh each day; the daily head-hash sequence is a notarization trail |
| `config-baseline-images.json` | `policies/governance-isms.md` (#311), plus change-management-sod (#316) and runtime-isolation (#322) | A dated baseline of exactly which image digests run in production, for configuration-management and change-detection review |
| `backups-index.json` | `policies/business-continuity-dr.md` (#321) | Daily Postgres backups are actually being produced and retained (backup-success evidence) |
| `control-plane-push/access-review/*` | `policies/iam-access-control.md` (#312) | Periodic access reviews: the current org roster with roles and last-login, per SOC 2 CC6.2 and ISO A.9.2.5 |
| `control-plane-push/trivy/*`, `control-plane-push/codeql/*` | `policies/vuln-patch-management.md` (#317) | Dated vulnerability and static-analysis scan results, for the vuln/patch-management control |
| `run-manifest.json` | `control-matrix.md` (#324) | The evidence-collection control itself: a dated record that collection ran and what it covered |

## How an assessor retrieves a control's evidence

The MinIO console is at the `minio` Service, port 9001; S3 API on port 9000. With
S3 credentials (the `minio-creds` Secret) and `mc`:

```bash
# One-time: point mc at the in-cluster MinIO (or a port-forward of it).
mc alias set fac http://minio.factory.svc.cluster.local:9000 "$S3_ACCESS_KEY" "$S3_SECRET_KEY"

# 1. Audit logging (#313): every daily audit-chain verdict.
mc cat fac/factory-evidence/2026-07-24/audit-anchor.json
#    Trend the head hashes across days to prove continuity:
for d in $(mc ls fac/factory-evidence/ | awk '{print $NF}' | tr -d /); do
  echo -n "$d "; mc cat "fac/factory-evidence/$d/audit-anchor.json" | grep head_entry_hash
done

# 2. Business continuity / DR (#321): backups existed on a given date.
mc cat fac/factory-evidence/2026-07-24/backups-index.json

# 3. Change mgmt (#316) / config baseline: what ran on a date.
mc cat fac/factory-evidence/2026-07-24/config-baseline-images.json

# 4. IAM access review (#312): the pushed roster for an org.
mc ls  fac/factory-evidence/control-plane-push/access-review/
mc cat fac/factory-evidence/control-plane-push/access-review/<org>-2026-07-24.ndjson

# 5. Vuln/patch mgmt (#317): scan results for a repo.
mc ls fac/factory-evidence/control-plane-push/trivy/
mc ls fac/factory-evidence/control-plane-push/codeql/
```

To recover a version that was overwritten or deleted (versioning is on):

```bash
mc ls --versions fac/factory-evidence/2026-07-24/audit-anchor.json
mc cat --version-id <VERSION_ID> fac/factory-evidence/2026-07-24/audit-anchor.json
```

## Residual gaps (honest)

- The MinIO evidence bucket shares a failure domain with the source data it
  attests (single node-local `local-path` PVC, one node — see `docs/restore.md`
  and business-continuity-dr.md). The evidence trail is durable against
  overwrite/delete (versioning) but not against loss of that node. The
  off-cluster copy tracked in `docs/restore.md` covers this bucket too.
- The control-plane push side (access-review, Trivy, CodeQL) has a ready drop
  path and lifecycle but the producers are not yet wired to write to it; until
  they are, those rows are "expected, not yet present" and `run-manifest.json`
  says so.
- Freshness alerting on a missing push is not built here; a missing object is
  visible in the listing and recorded in `run-manifest.json`. Wire it to the
  same failed-Job pattern as `apps/audit-anchor-alert` when that plumbing lands.
