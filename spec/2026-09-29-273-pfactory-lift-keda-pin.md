---
status: approved
issue: 273
intent: intent/2026-09-29-273-pfactory-lift-keda-pin.md
---

# Spec: lift the PFactory KEDA one-replica pin

## Unblocked

The intent paused this until PFactory's per-process state was shared. Every blocker it named is now closed and in production:

| PFactory issue | Fix |
| --- | --- |
| #804 | WebSocket, log and progress events relayed between pods through Postgres (0.6.30) |
| #805, #806, #807 | Run leases, the audit chain head under FOR UPDATE, OAuth and device-flow state (2026-09-29) |
| #808 | Stale `queued` sessions are discarded after a TTL, so they no longer inflate the KEDA metric (0.6.30) |
| #795 | Post-migration store attach retries (2026-10-21) |
| #829, #905 | Task logs and board status in Postgres, found after the intent was written (0.6.31, `sha-ea3ce26`, 2026-10-23) |

factory-gitops #272 has merged, so there is no overlapping rollout.

## Design

The approved answers to the intent's open questions decide the design.

### 1. The ceiling and the guard (commit 1; stays)

- `apps/keda/scaledobjects/pfactory.yaml`:
  - set `maxReplicaCount: 1` → `2`;
  - replace the "Pinned to 1 (PFactory#755)" comment with one that points at #273 and says the step to 4 comes only after a week with no anomalies;
  - fix the header comment's stale "PFactory has NO WebSocket fan-out" (it has one since #804).
- `apps/pfactory/manifests/manifests.yaml`, Deployment env:
  - `PFACTORY_REPLICA_COUNT: "2"`. It must equal `maxReplicaCount`. A comment on each says they move together.
  - `PFACTORY_REQUIRE_SHARED_STORE: "1"`.

  `apps/backend/plan/service.py:_warn_if_multi_replica_without_store` reads both. With a replica count above 1 and no shared session store, the pod refuses to start (a visible crash loop) instead of running per-process (an invisible split brain). `routes/github.py:788` reads the same count for the device flow.
- `minReplicaCount` stays 1.

### 2. Forcing a second pod for verification (commit 2; reverted by commit 3)

`minReplicaCount: 2` is a commit of its own, made only for the verification. A revert commit puts it back to 1 afterwards.

### Scheduling

The `pfactory-data` PVC is a `local-path` volume. Its PV has node affinity to `k3d-factory-server-0`, so the scheduler places every PFactory pod on that node. RWO is per node, so both pods mount the same volume. That node has room for a second 8 GiB limit.

## Alternatives rejected

- **Straight to `maxReplicaCount: 4`:** rejected by the owner (open question 1). Two pods prove the cross-pod behaviour; four only add capacity.
- **Warn instead of fail closed:** rejected by the owner (open question 2). The ERROR log ran unnoticed through the #755 incident.
- **Trigger a scale-out by queueing plans, or by `kubectl scale`:** rejected (open question 3). Queueing is slow and not repeatable. ArgoCD and the HPA would undo a manual scale.
- **One commit for both the ceiling and the temporary minimum:** rejected. Reverting the minimum must not revert the ceiling.

## Risks

- **Scale-down stops a pod that is running a coding task.** When the queue drains, the HPA removes a pod after the 120 s stabilization window. Plan sessions survive this: their leases are reclaimed by the other pod (`plan/service.py:1372`). An agent task's run on the removed pod is marked failed by `_fail_interrupted_run`, the same as on any pod restart today. With 2 replicas this happens only after a scale-out, which needs more than 2 queued plans. Accepted for the 2-replica step. If it shows up during the week, add a drain (preStop wait or a longer stabilization window) before going to 4.
- **A pod without the shared store now crash-loops.** This is intended (fail closed). Rollback is one revert.
- **A per-process state holder not yet found.** The verification below checks every board, session and task path that was fixed. A miss shows up as a pod disagreeing with its peer. Mitigation: the week at 2 before 4.
- **Memory on `server-0`.** A second pod may use up to 8 GiB more. That node has about 250 GiB allocatable.

## Verification

Run after commit 2 rolls out. Each step hits each pod directly with `kubectl port-forward pod/<name>`, not through the Service.

1. Two `pfactory` pods are Ready on `k3d-factory-server-0`. Both log "plan sessions are SHARED" and "plan state is DURABLE". Neither logs the #755 per-process ERROR.
2. Each pod's env has `PFACTORY_REPLICA_COUNT=2` and `PFACTORY_REQUIRE_SHARED_STORE=1`.
3. **Sessions (#755):** ingest a plan on pod A, then discard it on pod B. Pod A returns it as discarded, without a restart.
4. **Board and logs (#829, #905):** for one existing task, `GET /api/projects/{id}/tasks` and `GET /api/tasks/{id}/logs` return the same status, phase, subtasks, progress and log phases from both pods.
5. **Events (#804):** a WebSocket client on pod B receives a task event raised on pod A.
6. The ScaledObject is Ready, and its HPA shows min 2, max 2.

Then commit 3 (minimum back to 1). Check that the HPA shows min 1, max 2 and that one pod is stopped cleanly.

Comment the per-pod results on #273. Close it after a week with no anomalies, together with a follow-up issue for the step to 4.
