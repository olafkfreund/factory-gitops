---
status: draft
issue: 3681
intent: intent/2026-11-14-3681-offsite-backup-copy.md
---

# Spec: off-cluster copy of the postgres backups (Factory#3681)

## Design

### What ships

A second kustomization, `apps/backups/offsite/`, holding:

- `cronjob.yaml`: CronJob `postgres-backup-offsite`, namespace `factory`,
  schedule `15 3 * * *` (one hour after `postgres-backup` at 02:15 UTC).
- `offsite-copy.sh`: the job's script, as a real file so it can be tested.
- `kustomization.yaml`: `namespace: factory`, `resources: [cronjob.yaml]`, and a
  `configMapGenerator` that turns `offsite-copy.sh` into the ConfigMap
  `postgres-backup-offsite-script` the CronJob mounts, with
  `disableNameSuffixHash: true`. A hashed name would make Argo CD prune the old
  ConfigMap on a script change while a Job created earlier may still need it
  for a retry pod.
- `test.sh`: runs `offsite-copy.sh` against a stub `mc` (no network).

`apps/backups/manifests/kustomization.yaml` is **not** changed, so nothing in
`apps/backups/offsite/` reaches the cluster. The root app discovers only
`**/application.yaml` (`bootstrap/argocd-root-app.yaml:24`), so the new
directory is not picked up on its own either.

### How "Secret still missing" is handled

The CronJob is not deployed until the owner enables it. Enabling is one line in
git, after the Secret exists: add `- ../offsite` to `resources:` in
`apps/backups/manifests/kustomization.yaml`.

Until then: Argo CD's `backups` app renders exactly what it renders today
(Synced, Healthy), no CronJob exists, so no pod is created and `job-watchdog`
has nothing to report. CI still builds and schema-checks the new directory,
because `manifest-validate.yml` builds every directory with a
`kustomization.yaml`.

Why not `suspend: true`: `job-watchdog` reports a suspended CronJob as a
warning, and one that has not succeeded within tolerance (about 48h for a daily
job) as `never_succeeded`, which is critical and re-commented every 24h
(`apps/job-watchdog/manifests/manifests.yaml`, `assess()`: the `suspended` and
`never_succeeded` checks are independent). A suspended placeholder would nag
daily until the owner acts. The gap stays tracked by Factory#3681 instead.

### The job

One container, the image `postgres-backup` already uses for its upload step:
`cgr.dev/chainguard/minio-client:latest-dev@sha256:b056b795…` (same digest;
checked locally that it has `mc`, `sha256sum`, `gzip`, `awk`, `sort`, `date`,
`cmp`, and `/bin/sh` with `pipefail`). No new image, no Kyverno change.

Pod and CronJob settings copy `postgres-backup`: `concurrencyPolicy: Forbid`,
`successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 10`, no
`ttlSecondsAfterFinished`, `backoffLimit: 2`, `restartPolicy: Never`,
`enableServiceLinks: false`, `runAsNonRoot` (uid 65532, the image's `nonroot`),
`seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`,
`readOnlyRootFilesystem: true`, all capabilities dropped, resource limits,
`emptyDir` scratch with `sizeLimit: 5Gi`, `automountServiceAccountToken: false`.

Environment, all from Secrets by name:

| Env | Secret / key |
| --- | --- |
| `S3_ACCESS_KEY`, `S3_SECRET_KEY` | `minio-creds` (existing) |
| `OFFSITE_S3_ENDPOINT` | `offsite-s3-creds` / `OFFSITE_S3_ENDPOINT` |
| `OFFSITE_S3_BUCKET` | `offsite-s3-creds` / `OFFSITE_S3_BUCKET` |
| `OFFSITE_S3_ACCESS_KEY` | `offsite-s3-creds` / `OFFSITE_S3_ACCESS_KEY` |
| `OFFSITE_S3_SECRET_KEY` | `offsite-s3-creds` / `OFFSITE_S3_SECRET_KEY` |

The key names are the ones factory-gitops#70 used.

`offsite-copy.sh`, in order; any failure exits non-zero:

1. Refuse an `OFFSITE_S3_ENDPOINT` that does not start with `https://`.
2. Set the two `mc` aliases (config dir on the scratch volume).
3. Find the newest source dump: the last name, sorted, matching
   `factory-cluster-*.sql.gz` under `factory-backups/postgres/`. The names carry
   a UTC timestamp, so name order is age order. None found: fail.
4. Freshness: parse the timestamp from the name; fail if it does not parse,
   if it is more than 300s in the future, or if it is older than
   `MAX_AGE_SECONDS` (default 43200, 12h). This job runs an hour after the
   dump, so tonight's dump is about 1h old and last night's is about 25h old:
   the limit has to sit below 25h, or a night where `postgres-backup` failed
   would still "verify" yesterday's dump. A future-dated name is rejected
   because it would sort last and win the selection on every later run.
5. `mc mirror` source prefix to `<bucket>/postgres/` at the destination, without
   `--remove` and without `--overwrite`: nothing at the destination is deleted
   or replaced, and dumps the local 14-day lifecycle expires stay there.
6. Verify the newest dump: download the destination object to scratch, then
   require that it is not empty, that `gzip -t` passes, and that its SHA-256
   equals the SHA-256 of the source object streamed from MinIO.
7. Print one line: object name, bytes, sha256, age in seconds.

The job only reads from the source bucket.

### How the copy is verifiable

- Per run: steps 4 and 6. A success means tonight's dump is at the
  destination, byte-identical and a valid gzip.
- Over time: `job-watchdog` already records every CronJob in `factory` to the
  `job_health` stream and opens an issue on `failing`, `stale` or
  `never_succeeded`. Once enabled, the new CronJob is covered with no change to
  the watchdog. That is the metric; no second check job.

This proves currency and integrity of the copy. It is not a restore test.

### Docs

`docs/restore.md`, "Off-cluster follow-up" is rewritten to say: what exists and
that it is off until enabled; what the destination must provide (below); the
Secret name and keys; the enable step; how to restore from the off-cluster copy
(fetch the object with `mc` from the destination, then the existing Postgres
procedure); and that `factory-artifacts` still has no off-cluster copy. The
"Whole-bucket loss" and backup-verification entries are updated to match.
The header comment in `apps/backups/manifests/manifests.yaml` ("RESIDUAL DR
GAP") points at the new directory.

### Destination (owner's decision; recommendation)

Recommended: a bucket at an S3-compatible provider outside the house, in the
EU (for example Backblaze B2 or Hetzner Object Storage). It must be:

- private, with encryption at rest switched on;
- versioned or object-locked, with a lifecycle rule (suggest 90 days);
- reached with a key scoped to that one bucket that can list, read and write
  but not delete.

A MinIO on a second machine at home (p510) also takes the copy off the cluster
host and keeps the data in the owner's hands, but it does not survive losing
the site. It is the fallback if no external provider is wanted.

### Client-side encryption

Not in this change. The dumps go to the destination as they are in MinIO
(gzip of plain SQL, including role password hashes), protected in transit by
TLS and at rest by the destination's own encryption. The pinned image has no
`openssl`, `gpg` or `age`, so encrypting before upload means another image and
a key to manage and to have at hand during a restore. If the owner wants it,
that is a follow-up. A destination on the owner's own machine keeps the stored
copy in the owner's custody, but whether plain dumps are acceptable there is
still the owner's decision.

## Alternatives rejected

- **`suspend: true` in the synced manifests.** Syncs cleanly but makes the
  watchdog raise a critical issue that re-comments daily (see above).
- **`optional: true` Secret refs and exit 0 when unset.** A skipped run would
  look like a successful backup copy in `job_health`.
- **restic or rclone.** Neither image is in this repo today. `mc` is, and a
  plain mirror keeps the restore a single `gunzip | psql`.
- **MinIO bucket replication.** Needs a remote MinIO and admin configuration on
  the live server; `mc mirror` works with any S3 target.
- **A separate verify CronJob.** It would need the same credentials and would
  check the same thing; the watchdog already covers "the job stopped running".
- **Script inline in the CronJob, as `postgres-backup` does.** Then the test
  would have to extract it from YAML; `configMapGenerator` avoids that.
- **Mirroring `factory-artifacts` too.** Different size and retention; out of
  scope (intent).

## Risks

- Until the owner enables it, nothing is copied. The gap stays open on
  Factory#3681; the docs say so.
- The enable PR merged before the Secret exists would leave a pod in
  `CreateContainerConfigError`; the docs put seeding first.
- Read-back downloads the newest dump every night. Dumps are tens of KiB today
  (34 KiB in the 2026-08-10 drill); at GB size this costs egress and scratch,
  and the check should move to a provider checksum. Noted in the script.
- `mc mirror` skips an object that already exists at the destination. A dump
  that changed after it was copied would not be re-copied, but dump names are
  unique per run and the verify step compares content for the newest one.
- A cluster compromise exposes the destination key. A key that cannot delete,
  plus versioning or object lock, keeps the old copies safe; that is on the
  destination's configuration, not this job.
- With a fixed ConfigMap name, a script change reaches a retry pod of a Job
  that started under the old script. Both are the same job's script, a day
  apart at most; accepted.

## Verification

- `apps/backups/offsite/test.sh` passes: happy path; stale dump (25h old);
  future-dated name; unparsable name; no dump; corrupt destination copy; empty
  destination copy; `http://` endpoint. It runs **inside the pinned image**
  (`docker run`, image reference read from `cronjob.yaml`), locally and in a
  small CI workflow, so the shell and `date` under test are the ones the job
  uses, not the runner's.
- `kustomize build apps/backups/offsite` renders a CronJob and a ConfigMap, and
  `kubeconform` accepts them (also done by `manifest-validate.yml`).
- `kustomize build apps/backups/manifests` output is byte-identical before and
  after the change. That is the proof Argo CD has nothing new to sync.
- With `- ../offsite` added locally (not committed), `kustomize build
  apps/backups/manifests` renders the CronJob and the ConfigMap.
- After the owner enables it: first run succeeds, the log line shows the
  verified object, and `job_health` reports `ok` for `postgres-backup-offsite`.
  A restore from the off-cluster copy is then recorded on Factory#3681.
