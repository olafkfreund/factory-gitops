---
status: approved
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

## Blocked (2026-09-29, owner decision)

Before the spec, an audit of per-process state in PFactory found that the
shared session store fixes only part of #755's class of bug. With 2 replicas
these would still be wrong in production:

- olafkfreund/PFactory#804: WebSocket, log and progress events reach only
  clients on the emitting pod.
- olafkfreund/PFactory#805: running-task registries (agent runs, insights,
  changelog, PR review) are per pod, so status, stop and the duplicate-run
  guard break.
- olafkfreund/PFactory#806: the audit hash chain forks under concurrent
  writers (no FOR UPDATE on the head).
- olafkfreund/PFactory#807: email OAuth connect state and the GitHub device
  flow are held in memory.
- olafkfreund/PFactory#808: ingested-but-never-processed sessions sit in
  `queued` forever and inflate the KEDA metric.
- Related, already open: olafkfreund/PFactory#795 (the post-migration store
  attach has one retry).

The following are already fine in production (the gitops manifest differs
from the chart): `~/.pfactory` is on the PVC, `APP_API_TOKEN` comes from the
Secret, the OIDC session cookie is signed with the shared secret, and MCP
remote SSE is off.

The owner chose to pause: `maxReplicaCount` stays 1, and the spec is written
once #804-#807 have shipped. #808 should ship first, or the stale rows be
cleaned. The approved answers to the open questions below still stand.

## Open questions

Resolved 2026-09-29 (approved): 1 = 2 first, then 4 after a week without anomalies; 2 = yes, set PFACTORY_REQUIRE_SHARED_STORE=1; 3 = (a) a temporary minReplicaCount: 2, as its own commit and revert.

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
