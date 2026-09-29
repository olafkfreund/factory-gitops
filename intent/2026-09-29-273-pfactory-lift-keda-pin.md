---
status: draft
issue: 273
author: Olaf Krasicki-Freund
---

# Intent: lift the PFactory KEDA one-replica pin

## Problem

`apps/keda/scaledobjects/pfactory.yaml` pins PFactory to
`maxReplicaCount: 1` (#268, 2026-09-23). The pin was a stop-gap for
PFactory#755: plan sessions were cached per process, so with 4 replicas a
discard, approve or reject returned 200 but was visible only on the pod that
took it.

That cause is fixed and running in production. PFactory 0.6.22 (2026-09-28)
logs "plan sessions are SHARED" and "plan state is DURABLE", with:

- the shared Postgres session store (PFactory#755, #757);
- the emit lease and compare-and-set (#758);
- the store attaching after boot migrations (#774, #777);
- the shared-store stale reads fixed (#779).

While the pin stays:

- **No scale-out:** the admission-queue autoscaler (RFC-0016) cannot add
  capacity. Queued plans wait behind one pod even though the durable admission
  cap (`PFACTORY_MAX_CONCURRENT_PLANS`, FOR UPDATE) is safe across replicas.
- **No failover:** there is no second pod during a restart or a crash.
- **No guard:** the pod has no `PFACTORY_REPLICA_COUNT`, so PFactory's
  per-process guard (#755) cannot tell it runs with more than one replica. If
  a future pod ever came up without the shared store while scaled out, it
  would split-brain silently instead of refusing to start.

## Proposed outcome

- KEDA may scale PFactory above one replica on queue depth again.
- Every PFactory pod knows the replica ceiling, and refuses to start rather
  than run per-process when more than one replica is possible.
- Verified in production with more than one pod: a write on one pod (approve,
  discard) is visible on every pod, without a restart.

## Affected users and systems

- `apps/keda/scaledobjects/pfactory.yaml` (the ScaledObject).
- `apps/pfactory/manifests/manifests.yaml` (Deployment env).
- PFactory in production; CFactory's cockpit, CFactory's MCP tools and the
  PFactory MCP read it across whichever pod the Service picks.
- The single k3d node: its `local-path` PVC is ReadWriteOnce, which is
  per node, so extra pods on the same node can mount it. About 250 GiB of
  allocatable memory against an 8 GiB limit per pod.

## Constraints

- Change only gitops; no PFactory code change.
- `minReplicaCount` stays 1 (no scale to zero).
- Reversible by one revert.
- Do not merge while factory-gitops #272 (the plan-review comment flag) is
  mid-rollout. Both change the PFactory Deployment, so their verifications
  would overlap.
- Verification must check each pod separately (`port-forward pod/<name>`),
  not only through the Service.

## Open questions

1. **Ceiling:** go back to `maxReplicaCount: 4` (the pre-#268 value), or step
   up to 2 first? **Recommended: 2 first, then 4** after a week without
   anomalies. Two pods prove the cross-pod behaviour; four only adds capacity.
2. **Fail closed:** also set `PFACTORY_REQUIRE_SHARED_STORE=1`, so that a pod
   without the shared store refuses to start instead of logging an ERROR and
   running? **Recommended: yes.** With more than one replica, a per-process
   pod is the #755 split brain. A crash loop is visible; a split brain is not.
3. **Forcing a second pod for verification:** the queue is rarely deep enough
   to trigger a scale-out. Options:
   - (a) temporarily set `minReplicaCount: 2` for the verification, then back
     to 1;
   - (b) queue enough plans to trigger KEDA;
   - (c) scale by hand, which ArgoCD and the HPA would fight.

   **Recommended: (a),** as its own commit and revert.
