# HA Postgres and Point-in-Time Recovery (design)

Design-only proposal (Factory#321, compliance program #310). Nothing here is
applied to the cluster. The live database remains the single-replica StatefulSet
in `apps/postgres/manifests/manifests.yaml`. This document proposes migrating it
to a replicated, self-healing Postgres with continuous WAL archiving, which gives
both high availability (automatic failover) and point-in-time recovery (restore
to an arbitrary moment, not just a daily backup boundary).

## Why the current setup is not enough

Two independent gaps, only the first of which the daily backups + off-cluster
mirror (`apps/backups`, `docs/restore.md`) address:

- Durability / DR — mostly solved. `pg_dumpall` daily -> `factory-backups` MinIO
  bucket, now mirrored off-cluster by `offsite-backup-mirror`. Worst-case data
  loss (RPO) is still up to ~24h, and there is no automatic failover.
- Availability — not solved. `apps/postgres` is `replicas: 1` on an RWO
  `local-path` PVC pinned to one node. If that node or pod dies, every PARR
  service that externalized its job-state to Postgres (PFactory #217/#220,
  TFactory #465/#468, AIFactory #668/#673, per the `apps/postgres` header) is
  down until the pod reschedules and the volume is reattached — and the local
  PVC cannot move to another node, so a node loss is a manual restore, not a
  reschedule.

The daily logical dump can only restore to a backup boundary. A bad migration or
an erroneous bulk `DELETE` at 14:00 is unrecoverable to 13:59 — the best you have
is last night's 02:15 dump. Closing both gaps needs streaming replication (for
HA) plus continuous WAL archiving (for PITR).

## Proposal: CloudNativePG

Adopt [CloudNativePG](https://cloudnative-pg.io/) (CNPG), the CNCF Postgres
operator, to replace the hand-rolled StatefulSet with a managed `Cluster`.

Why CNPG over the alternatives:

- Purpose-built Kubernetes operator: it manages the StatefulSet, services,
  streaming replication, failover, and PVCs declaratively — no Patroni + etcd +
  HAProxy stack to assemble and babysit.
- Built-in continuous WAL archiving and PITR to S3-compatible object storage via
  the Barman Cloud plugin — the exact "WAL archiving to object storage" this
  program needs, and it can target the same MinIO the fleet already runs
  (`apps/minio`), plus the off-cluster S3 target (`offsite-s3-creds`) for the DR
  copy.
- GitOps-native: a single `Cluster` CR fits the existing app-of-apps model
  (`apps/**/application.yaml`), the same way `apps/postgres` is synced today.
- Rolling minor-version upgrades, automated failover with a stable read/write
  service endpoint, and a `Backup`/`ScheduledBackup` CRD that supersedes the
  `pg_dumpall` CronJob.

Patroni is the credible alternative (more control, storage-engine-agnostic) but
carries a heavier operational surface (DCS quorum, template management) for no
benefit this fleet needs. CNPG is the lazier correct choice.

### Target shape

- A CNPG `Cluster` named `postgres` in the `factory` namespace, `instances: 2`
  (one primary + one hot-standby) to start, `instances: 3` if a second worker
  node is reliably available (the fleet is storage-bound, not node-bound — see
  the cluster-storage memory). Each instance gets its own PVC; the standby
  streams from the primary, so a node/pod loss triggers automatic failover to
  the standby with the read/write service repointed by the operator.
- WAL archiving + base backups to object storage using the Barman Cloud plugin,
  targeting a dedicated bucket (e.g. `factory-pg-wal`) in MinIO, and mirrored
  off-cluster by the same `offsite-backup-mirror` pattern (add the WAL bucket to
  the mirror list). Continuous WAL shipping means RPO drops from ~24h to the WAL
  archive interval (seconds-to-minutes).
- `ScheduledBackup` for periodic base backups; PITR = restore the nearest base
  backup + replay WAL to the chosen timestamp.
- The connection contract is preserved: services keep using `DATABASE_URL`
  pointing at a `postgres` service name. CNPG exposes `-rw` (read/write, always
  the primary) and `-ro` (read-only replicas) services; the `postgres` service
  the apps use today maps to the `-rw` endpoint, so no application change beyond
  the service target.

## Migration path (single StatefulSet -> CNPG)

Staged and reversible; the current StatefulSet stays the source of truth until
the final cutover.

1. Install the operator. Add `apps/cnpg-operator/` (Helm or the published
   install manifest, pinned) as its own app-of-apps Application. The operator is
   namespace-scoped-safe and touches nothing until a `Cluster` CR exists.
2. Stand up an empty CNPG `Cluster` alongside the existing StatefulSet, under a
   distinct name/service (e.g. `postgres-cnpg`) so the running fleet is
   untouched. Wire its WAL archiving to the new bucket and confirm base backups +
   WAL land in object storage and mirror off-cluster.
3. Load the data. Two options, pick per acceptable downtime:
   - Logical (simplest, matches today's tooling): quiesce writers (the same
     `scale deploy ... --replicas=0` step from `docs/restore.md`), take a final
     `pg_dumpall`, restore it into the CNPG cluster, verify with the existing
     restore-verification checklist.
   - CNPG `import` (bootstrap `initdb.import`): CNPG can pg_dump/pg_restore the
     source databases into the new cluster in one declarative step; still needs a
     brief write freeze for a consistent cutover.
4. Cutover. Repoint the `postgres` service (or `DATABASE_URL`) at the CNPG `-rw`
   endpoint, scale writers back up, run the restore-verification checklist
   (`pg_isready`, per-database row sanity, alembic head, a smoke PARR run).
5. Decommission. After a soak period with the CNPG cluster healthy and backups
   verified, retire the old StatefulSet and the `pg_dumpall` CronJob
   (`apps/backups` postgres-backup) — CNPG's scheduled base backup + WAL archive
   replaces it. Keep the off-cluster mirror; just point it at the WAL/backup
   bucket.

Rollback at any step before (5): the original StatefulSet is untouched, so revert
the service target and scale writers back to it.

## RTO / RPO improvement

Baseline is the current single StatefulSet + daily logical dump
(`docs/restore.md`):

| Scenario | Today (StatefulSet + daily dump) | With CNPG (HA + WAL/PITR) |
|---|---|---|
| Pod/node failure (availability) | Manual: reschedule pod, reattach RWO PVC; on node loss, restore from backup. RTO ~1h+, worse if the node is gone. | Automatic failover to the hot standby. RTO seconds-to-low-minutes, no data loss. |
| Data loss window (RPO) | Up to ~24h (last daily dump). | Seconds-to-minutes (continuous WAL archiving). |
| Logical error / bad migration | Restore last daily dump only — lose everything since 02:15. | PITR: restore to the second before the bad statement. |
| Whole-cluster loss (DR) | Rebuild + restore last off-cluster dump. RPO ~24h. | Rebuild CNPG from base backup + WAL in object storage (mirrored off-cluster). RPO down to the last archived WAL. |

Net: availability goes from manual-recovery to automatic-failover; RPO improves
from ~24h to minutes; and logical/point-in-time mistakes become recoverable
instead of costing up to a day of control-plane state.

## Scope and non-goals

- Design-only. No operator is installed and the live DB is not migrated here.
- Storage reality: CNPG replicas need PVCs on distinct nodes to survive a node
  loss; the fleet's ceiling is RWO `local-path` storage, not node count (see the
  cluster-storage-not-nodes memory). Landing real HA likely pairs this with the
  RWX/`nfs` storage already available on the cluster (see the rwx-nfs-storage
  memory) or a replicated storage class — a prerequisite to call step (2)
  production-HA rather than same-node redundancy.
- Follow-up work (separate tickets): choose the WAL bucket + retention, extend
  `offsite-backup-mirror` to cover it, pick the storage class for replica PVCs,
  and schedule the cutover drill.
