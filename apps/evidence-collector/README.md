# evidence-collector — automated, timestamped compliance evidence (Factory#324)

Auditors need a durable, dated evidence trail, not evidence gathered on demand
the week before an assessment. This app runs a daily Kubernetes CronJob that
snapshots the evidence the cluster can produce on its own into a dedicated,
versioned and lifecycled `factory-evidence` MinIO bucket, one dated prefix per
run: `factory-evidence/<YYYY-MM-DD>/`.

Full operator/assessor guide: `docs/evidence-collection.md`.

## What it snapshots each day

- `audit-anchor.json` — the CFactory tamper-evident audit-chain head hash, entry
  count, newest timestamp, and a structural-integrity verdict (same check as
  `apps/audit-anchor-alert`). The daily sequence of head hashes is itself a
  notarization trail. Maps to audit-logging (#313).
- `config-baseline-images.json` — the `image@sha256` digests of the containers
  actually running in the `factory` namespace, read from the Kubernetes API.
  The true "what is deployed" baseline. Maps to change-management (#316) and
  runtime-isolation (#322).
- `backups-index.json` — the Postgres backup objects that exist in
  `factory-backups` (apps/backups). Proves the daily backup ran; an empty list
  is itself recorded as evidence of a gap. Maps to business-continuity-dr (#321).
- `run-manifest.json` — what this run collected and what the control plane is
  expected to push (see below).

## Why a CronJob

Same reasoning as `apps/audit-anchor-alert`: the cluster has no Prometheus/
Alertmanager and no external evidence pipeline. The smallest thing that produces
a durable, dated trail is a scheduled Job that writes into the object store that
already exists. Security model is copied verbatim from `apps/cred-broker` and
`apps/backups`: a dedicated ServiceAccount with least-privilege RBAC (read pods
only), non-root, `readOnlyRootFilesystem`, all capabilities dropped, resource
limits, in-memory scratch.

Self-test the pure chain logic without a cluster:

```bash
python3 <(kubectl -n factory get cm evidence-collector-script -o jsonpath='{.data.collect\.py}') selftest
```

## Honest scope — what must be PUSHED by the control plane

Two evidence classes cannot be pulled from the cluster:

- Access-review NDJSON is behind AIFactory admin auth and needs an org id
  (`access_review.py`, `GET /api/admin/access-review?org=...`).
- Trivy / CodeQL scan results are produced in GitHub Actions, off-cluster.

Both must be pushed into `factory-evidence/control-plane-push/<source>/`. The
collector records their expected drop paths in `run-manifest.json` but does not
fetch them. See `docs/evidence-collection.md` for the push contract.
