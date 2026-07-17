# KEDA ScaledObjects — admission-queue autoscaling (RFC-0016 #192)

These ScaledObjects scale the PARR control-plane Deployments on **admission-queue
depth**: the count of durable `job_states` rows in `lifecycle_state = 'queued'`
(Factory `apis/job-state.schema.json`), via KEDA's **PostgreSQL scaler**. No
Redis broker is needed — the queue is already durable in Postgres, so KEDA scales
on a `SELECT count(*)` against it.

KEDA moves *replicas*; the in-app **global concurrency cap**
(`MAX_CONCURRENT_TASKS` / `PFACTORY_MAX_CONCURRENT_PLANS`, granted under a
`SELECT ... FOR UPDATE` transaction so it holds across replicas) bounds the
*actual* concurrency. See Factory `apis/concurrency-conventions.md` §1.

## Why these are GATED (not in app-of-apps)

The root Application syncs `apps/**/application.yaml`. These files live under
`apps/keda/scaledobjects/` (no `application.yaml`) **on purpose**: a postgres-
scaler ScaledObject pointing at a database/table that does not exist makes KEDA
log a perpetual scaler error and the ScaledObject's `Ready` condition stays
False — it is not a clean no-op. So we do not auto-sync them until the
prerequisites below are real on the cluster.

### Prerequisite chain (RFC-0016 Phase 1 → Phase 3)

1. **Shared Postgres deployed** in the `factory` namespace with a `job_states`
   table. A StatefulSet draft exists at `deploy-live/postgres.yaml` (per-service
   DBs); it is not yet wired into app-of-apps. As of this commit the cluster runs
   the services on **pod-local SQLite** (`data.db`) with `DATABASE_URL` unset.
2. **Services externalize state to Postgres** and write `job_states` rows:
   PFactory #217, AIFactory #668, TFactory #465. Until merged + deployed, the
   table has no `queued` rows to scale on.
3. **`DATABASE_URL` set on the service pods** (the in-memory/SQLite path is the
   single-pod fallback) **and** the `factory-secrets` Secret has a
   `POSTGRES_PASSWORD` key in the `factory` namespace, which the shared
   `factory-postgres` TriggerAuthentication reads.

   The scaler needs NO per-service Secret: host/port/userName/dbName/sslmode are
   plain trigger metadata in each ScaledObject, and the password comes from
   `factory-secrets`. This is deliberate (PFactory #265) — the scaler used to
   need a libpq `connection` key in an out-of-band `factory-db-<svc>` Secret,
   and a cluster rebuild recreated those Secrets with only `DATABASE_URL` (the
   key this README used to name), which made KEDA fail every scaler with
   "no host given" and silently pinned all three services to 1 replica.

When 1-3 are true, enable autoscaling:

```bash
kubectl apply -k apps/keda/scaledobjects/
kubectl get scaledobject -n factory
kubectl describe scaledobject pfactory -n factory   # trigger should be reachable/active
```

(Or, to put them under ArgoCD, add an `application.yaml` here pointing at this
path — once they are known-good.)

## Which services can actually scale >1 today

| Service   | maxReplicaCount | Can scale >1 once Postgres lands? | Blocker for >1 |
|-----------|-----------------|-----------------------------------|----------------|
| pfactory  | 4               | Yes                               | none (no WS fan-out) |
| tfactory  | 4               | Yes                               | none (no WS fan-out) |
| aifactory | **1** (capped)  | No — capped at 1                  | rmux WebSocket fan-out (`AIFACTORY_RMUX_ENABLED=true`, pod-local panes PVC) needs Redis pub/sub for multi-replica WS — out of scope for #192 |

`minReplicaCount: 1` everywhere — we never scale to zero, so there is no
cold-start disruption to the always-on APIs.

## What remains for true autoscaling

- Deploy Postgres + create `job_states` (Phase 1 platform work).
- Merge + deploy the per-service Postgres externalization (#217 / #668 / #465).
- Set `DATABASE_URL` on the pods (the scaler itself needs only
  `factory-secrets/POSTGRES_PASSWORD`; see the prerequisite chain above).
- For AIFactory >1: move rmux WS fan-out onto a shared bus (Redis pub/sub), then
  raise its `maxReplicaCount`.
- ~~Remove the `replicas: 1` pin from the pfactory/tfactory Deployments~~ DONE —
  no Deployment pins `replicas:` any more, so the HPA KEDA creates owns the
  replica count. Keep it that way: a hard pin in gitops + selfHeal fights the
  HPA and silently caps concurrency.
