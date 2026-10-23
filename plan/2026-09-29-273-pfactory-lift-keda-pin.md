---
status: approved
issue: 273
spec: spec/2026-09-29-273-pfactory-lift-keda-pin.md
---

# Plan: lift the PFactory KEDA one-replica pin

## Approved decisions

- Step the ceiling from 1 to **2** now. Step to 4 only after a week at 2 with no anomalies, as a follow-up issue.
- Set `PFACTORY_REPLICA_COUNT: "2"` (equal to `maxReplicaCount`) and `PFACTORY_REQUIRE_SHARED_STORE: "1"`. A pod without the shared session store refuses to start.
- `minReplicaCount` stays 1. For the verification only, a commit of its own sets it to 2, and a revert commit sets it back.
- Gitops only. No PFactory code change. The PV's node affinity keeps both pods on `k3d-factory-server-0`, sharing the RWO volume.
- Verify per pod with `kubectl port-forward pod/<name>`, not through the Service.

## Steps

1. `apps/keda/scaledobjects/pfactory.yaml`:
   - change `maxReplicaCount: 1` to `2`, and replace the "Pinned to 1 (PFactory#755)" comment with a #273 comment saying it moves with `PFACTORY_REPLICA_COUNT`;
   - in the header, replace "PFactory has NO WebSocket fan-out" with a note that cross-pod events go through the Postgres relay (PFactory#804).

   Check: `yq '.spec.maxReplicaCount, .spec.minReplicaCount' apps/keda/scaledobjects/pfactory.yaml` prints `2` and `1`.
   Traps: none.
2. `apps/pfactory/manifests/manifests.yaml`, the Deployment env next to `PFACTORY_PLAN_PERSIST` (about line 347): add `PFACTORY_REPLICA_COUNT: "2"` and `PFACTORY_REQUIRE_SHARED_STORE: "1"`, with a comment saying the count must equal the ScaledObject's `maxReplicaCount`.

   Check: `yq` over the Deployment env lists both names exactly once, and `kubectl apply --dry-run=client -f` on both files passes.
   Traps:
   - Env values must be quoted strings.
   - Keep the flow-mapping style (`- { name: …, value: "…" }`) the file uses.
3. Open PR A into `main` with the intent, spec, plan and steps 1–2. Merge it after review and green CI. Then wait for ArgoCD to sync and confirm that the running pod has both env vars and still logs "plan sessions are SHARED".

   Check: `kubectl -n factory get scaledobject pfactory -o jsonpath='{.spec.maxReplicaCount}'` prints `2`.
   Traps: announce on the agent bus before the merge, because the PFactory pod restarts.
4. PR B: in `apps/keda/scaledobjects/pfactory.yaml`, set `minReplicaCount: 1` to `2`, with a "TEMPORARY (#273 verification)" comment. Merge it.

   Check: two `pfactory` pods are Ready, both on `k3d-factory-server-0`.
   Traps: announce on the bus first.
5. Run the spec's verification steps 1–6 against each pod.

   Check: each step's result is recorded for both pods.
   Traps:
   - Use one existing task and one throwaway plan.
   - Discard the throwaway plan afterwards.
6. PR C: revert PR B (`git revert`), so `minReplicaCount` is 1 again. Merge it.

   Check: the HPA shows min 1 and max 2, and one pod terminates cleanly.
   Traps: none.
7. Comment the per-pod results on factory-gitops #273. File a follow-up issue for the step to 4, due after a week with no anomalies. Leave #273 open until that week passes.

## Tests

- `kubectl apply --dry-run=client -f apps/keda/scaledobjects/pfactory.yaml -f apps/pfactory/manifests/manifests.yaml`
- The repo's own CI on each PR.
- The runtime checks in steps 3–6.

## Rollback

- Revert PR A. This sets `maxReplicaCount` back to 1 and drops both env vars.
- If step 5 fails, merge PR C at once, then revert PR A. Either way it is one revert per PR.
