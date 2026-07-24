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

- Not true disaster recovery yet. MinIO runs on the same cluster as Postgres, on
  an RWO `local-path` PVC pinned to one node (`apps/minio/manifests.yaml`). A node
  or cluster loss takes the backups with the source. The off-cluster copy is the
  required next step (see below).
- No point-in-time recovery. These are daily logical snapshots, not WAL
  archiving; you can only restore to a backup boundary, not an arbitrary moment.
- Restore is not yet automated. The `restore.sh` helper is run deliberately by a
  human; there is no self-service restore.

## Off-cluster follow-up (required to call this DR)

Pick one and schedule it off the cluster's failure domain:

- `mc mirror --watch` (or a second CronJob) replicating `factory-backups` and
  `factory-artifacts` to an external S3 target (AWS S3, Backblaze B2, another
  MinIO on a different node/site).
- MinIO bucket replication to a remote MinIO once a second site exists.
- `restic`/`rclone` of the gzip objects to remote storage with its own retention.

Until one of these is live, treat the "backups" as protection against accidental
deletion and logical corruption only, not against losing the node.

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

- Whole-bucket loss (node gone): only recoverable from the off-cluster copy once
  that follow-up is implemented. Until then, this case is unrecoverable — call it
  out honestly in any DR sign-off.

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
- [ ] Restore drill on a scratch namespace/database at least quarterly — an
      untested backup is not a backup.
