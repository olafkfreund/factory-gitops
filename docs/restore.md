# Backup and Restore Runbook

Covers the fleet's Postgres logical backups and MinIO object durability, and the
exact steps to restore either. This is the first backup/DR capability for the
Factory control plane (Factory#321, tracked under the compliance program #310).

## What exists

- Daily Postgres backup: `apps/backups/manifests/manifests.yaml` (CronJob
  `postgres-backup`, 02:15 UTC). It runs `pg_dumpall --clean` against the shared
  Postgres StatefulSet (`apps/postgres`), gzips the plain-SQL dump, and uploads
  it to `s3://factory-backups/postgres/factory-cluster-<UTC timestamp>.sql.gz`.
- Backup bucket: `factory-backups` in MinIO (`apps/minio`), created with object
  versioning enabled and a lifecycle rule that keeps roughly 14 dailies
  (`--expire-days 14`, noncurrent versions reaped after 7 days).
- Artifact/evidence durability: object versioning is enabled on the
  `factory-artifacts` bucket too, so an overwrite or delete of an evidence object
  leaves a recoverable prior version.

The dump is a single plain-SQL file covering every database
(`pfactory`, `tfactory`, `aifactory`, `cfactory`, `factory`) plus global roles,
so a full restore is one `psql` feed.

## RTO / RPO

- RPO (max data loss): <= 24h. Backups run once daily; a failure between two runs
  loses at most one day of control-plane state (job_states and the per-service
  tables). Tighten by increasing the CronJob frequency or adding WAL archiving
  (not implemented).
- RTO (time to restore): target <= 1h for the Postgres restore below on the
  current single-node cluster (download + gunzip + psql of a few-GB dump). Actual
  time scales with dump size; measure it during the drill.

## Current gaps (read before relying on this)

- MinIO runs on the same cluster as Postgres, on an RWO `local-path` PVC pinned
  to one node (`apps/minio/manifests.yaml`), so the in-cluster backup shares the
  source's failure domain. The `offsite-backup-mirror` CronJob (see "Off-cluster
  copy" below) closes this by mirroring the backups to an external S3 target —
  once the operator supplies `offsite-s3-creds`, this is true DR.
- No point-in-time recovery. These are daily logical snapshots, not WAL
  archiving; you can only restore to a backup boundary, not an arbitrary moment.
  A CloudNativePG migration adding continuous WAL archiving for PITR is designed
  in `docs/ha-postgres-and-pitr.md` (design-only, not yet applied).
- Restore is not yet automated. The `restore.sh` helper is run deliberately by a
  human; there is no self-service restore.

## Off-cluster copy (implemented — this is what makes it DR)

Implemented as a second CronJob in `apps/backups/manifests/manifests.yaml`:
`offsite-backup-mirror` (03:15 UTC daily, an hour after the dump). It runs
`mc mirror --overwrite` from the in-cluster `factory-backups` bucket to an
EXTERNAL S3 target off this cluster's failure domain. `--remove` is deliberately
omitted, so dailies the local 14-day lifecycle expires survive off-cluster (the
external target keeps its own, typically longer, retention).

The external target is entirely operator-supplied via a Secret — the CronJob is
inert until you create it:

```
kubectl -n factory create secret generic offsite-s3-creds \
  --from-literal=OFFSITE_S3_ENDPOINT="https://s3.eu-west-1.amazonaws.com" \
  --from-literal=OFFSITE_S3_ACCESS_KEY="<external access key>" \
  --from-literal=OFFSITE_S3_SECRET_KEY="<external secret key>" \
  --from-literal=OFFSITE_S3_BUCKET="my-org-factory-dr"
```

Endpoint examples: AWS `https://s3.<region>.amazonaws.com`, Backblaze B2
`https://s3.<region>.backblazeb2.com`, remote MinIO `https://minio.dr.example.com`.
Create the target bucket at the remote first (with its own versioning/retention);
the job does not create it. The local source side reuses the existing
`minio-creds` Secret — no new in-cluster credential.

To also mirror `factory-artifacts` (evidence objects), add a second
`mc mirror ... fac/factory-artifacts offsite/<bucket-or-prefix>` line to the same
job; the failure-domain argument is identical.

Alternatives not used (documented for the record): MinIO server-side bucket
replication once a second site exists; `restic`/`rclone` of the gzip objects with
independent retention. `mc mirror` was chosen because it needs no second MinIO and
reuses the image and credential conventions already in this file.

### Point-in-time recovery (design)

These logical dumps + the off-cluster mirror still only restore to a backup
boundary (RPO <= 24h). Continuous WAL archiving for arbitrary-moment PITR — via a
migration to CloudNativePG — is designed in `docs/ha-postgres-and-pitr.md`. It is
design-only; the live DB is still the single StatefulSet in `apps/postgres`.

## Restore: Postgres

Prerequisites: `kubectl` access to the `factory` namespace, and the MinIO
credentials (Secret `minio-creds`). The helper `apps/backups/restore.sh` wraps
these steps with guards; the manual procedure is below so you can do it by hand.

1. List available backups:

   ```
   kubectl -n factory run mc-restore --rm -it --restart=Never \
     --image=quay.io/minio/mc:RELEASE.2025-04-03T17-07-56Z \
     --env=S3_ACCESS_KEY="$(kubectl -n factory get secret minio-creds -o jsonpath='{.data.S3_ACCESS_KEY}' | base64 -d)" \
     --env=S3_SECRET_KEY="$(kubectl -n factory get secret minio-creds -o jsonpath='{.data.S3_SECRET_KEY}' | base64 -d)" \
     --command -- /bin/sh -c '
       mc alias set fac http://minio.factory.svc.cluster.local:9000 "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null &&
       mc ls fac/factory-backups/postgres/'
   ```

2. Choose the object to restore (usually the newest, or a specific
   `factory-cluster-<ts>.sql.gz`).

3. Restore into Postgres. `pg_dumpall --clean` DROPs and recreates each database,
   so this overwrites current state. Stop the fleet writers first (scale the
   PARR services to 0) so nothing races the restore:

   ```
   # Quiesce writers (adjust to the deployments/statefulsets in use).
   kubectl -n factory scale deploy pfactory aifactory tfactory cfactory --replicas=0

   # Stream the chosen backup straight from MinIO into psql, inside a throwaway
   # pod that has both mc and (via the postgres image) psql is NOT in mc — so run
   # the download and the psql feed as two steps, or use restore.sh which handles it.
   ```

   The scripted path (`restore.sh`) does: download the gz from MinIO to an
   emptyDir, then `gunzip -c dump.sql.gz | psql -h postgres -U factory -d postgres`.
   `postgres` is the safe entry database because the dump DROPs the others.

4. Re-enable auto-migration and bring writers back:

   ```
   kubectl -n factory scale deploy pfactory aifactory tfactory cfactory --replicas=1
   ```

   Each service runs `alembic upgrade head` on startup, which is a no-op if the
   restored schema is already at head.

## Restore: MinIO objects

Versioning is enabled on `factory-artifacts` and `factory-backups`, so recovery
depends on what happened:

- Accidental delete: the object gains a delete marker; the prior version is still
  there. Restore it:

  ```
  mc alias set fac http://minio.factory.svc.cluster.local:9000 "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
  mc ls --versions fac/factory-artifacts/<prefix>/<object>     # find the version id
  mc cp --version-id <id> fac/factory-artifacts/<prefix>/<object> fac/factory-artifacts/<prefix>/<object>
  ```

  (Copying an old version onto the key makes it current again.)

- Overwrite: same as above — list versions, copy the good version-id back over
  the key.

- Whole-bucket loss (node gone): recover from the off-cluster mirror
  (`offsite-backup-mirror`, above). Point `mc` at the external target and copy the
  needed objects back into a rebuilt `factory-backups`, then follow the Postgres
  restore. This path is only as good as the last mirror run (RPO <= ~24h + the
  gap between dump and mirror); verify the external bucket has recent objects as
  part of the periodic backup-verification below.

## Restore-verification checklist

Run after any Postgres restore, before returning the fleet to service:

- [ ] `pg_isready -h postgres -U factory` returns ready.
- [ ] Databases exist: `psql -h postgres -U factory -l` lists `pfactory`,
      `tfactory`, `aifactory`, `cfactory`, `factory`.
- [ ] Row sanity: each service's core table is present and non-empty, e.g.
      `psql -h postgres -U factory -d pfactory -c 'select count(*) from job_states;'`
      (repeat per database; a zero count on a cluster that had work is a red flag).
- [ ] Alembic head matches code: `psql -h postgres -U factory -d aifactory -c
      'select version_num from alembic_version;'` equals the app's current head.
- [ ] Services report healthy after scale-up (readiness probes green, no
      `no pg_hba.conf entry` or auth errors in logs).
- [ ] A fresh PARR run (or smallest available smoke test) completes end to end.
- [ ] Record the drill: date, backup object restored, measured RTO, who ran it.

## Backup-verification (do this periodically, not only during an incident)

- [ ] The CronJob is succeeding: `kubectl -n factory get cronjob postgres-backup`
      and recent `jobs`/`pods` show completions, not failures.
- [ ] Today's object exists and is non-trivial in size:
      `mc ls fac/factory-backups/postgres/`.
- [ ] The off-cluster mirror is succeeding:
      `kubectl -n factory get cronjob offsite-backup-mirror` shows recent
      completions, and the external bucket has today's object
      (`mc ls offsite/<bucket>/postgres/` from a pod with `offsite-s3-creds`).
- [ ] Restore drill on a scratch namespace/database at least quarterly — an
      untested backup is not a backup.
