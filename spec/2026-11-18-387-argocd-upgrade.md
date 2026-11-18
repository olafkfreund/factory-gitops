---
status: draft
issue: 387
intent: intent/2026-11-18-387-argocd-upgrade.md
---

# Spec: upgrade ArgoCD from v2.13.1 to v3.5.7

## Design

### Target: v3.5.7, in one jump

ArgoCD's tested-versions table (`docs/operator-manual/tested-kubernetes-versions.md` at v3.6.1) lists:

| ArgoCD | Kubernetes |
| --- | --- |
| 3.6 | 1.34 to 1.37 |
| 3.5 | 1.33 to 1.36 |
| 3.4 | 1.32 to 1.35 |

v3.5.7 is tested on 1.35 and on the next k3s minor, 1.36. It is the eighth patch of its line, released 2026-11-02.
v3.6.1 is only the second patch of 3.6.

The upgrade overview (`upgrading/overview.md`) asks for every guide between the two versions to be read, not for
one minor at a time. A rehearsal proves the single jump before the live cluster gets it. The guides read for this
spec are 2.13→2.14, 2.14→3.0, and each minor up to 3.4→3.5.

### What the guides change for this repo

| Guide | Change | Handling |
| --- | --- | --- |
| 2.14→3.0 | Tracking default moves from label to annotation | Set `application.resourceTrackingMethod: label` explicitly (owner decision). No app uses `ApplyOutOfSyncOnly`, the case the guide warns about. |
| 2.14→3.0 | Default `resource.exclusions` includes `coordination.k8s.io/Lease` | rfactory-desktops manages `Lease/rfactory-runner` (with `ignoreDifferences` on `/spec`). Set `resource.exclusions` to v3.5.7's default list without the Lease entry. |
| 2.14→3.0 | `ignoreResourceStatusField` defaults to `all` | Keep #377's patch: it matches the new default, and keeps a rollback to 2.13.1 working. |
| 2.14→3.0 | Fine-grained RBAC, logs RBAC, Dex RBAC, removed metrics, legacy repo config, ApplicationSet selectors | None used here: no custom ArgoCD RBAC, no `dex.config`, no repository secrets (all five source repos are public), no ApplicationSets. |
| 3.2→3.3 | ApplicationSet CRD too big for client-side apply | Every apply uses `--server-side --force-conflicts`, as the guide requires. |
| 3.0→3.5 | Helm 3.18, 3.19, then 4.2.0; Kustomize 5.7, 5.8 | fides-reporter renders a Helm chart from git (not OCI), and the rest are plain or kustomize. The rehearsal compares every app's rendered resources. |
| 3.3→3.4 | `Missing` health only when all resources are missing | Health may read differently. The rehearsal records it. |

### Changes

**factory-gitops (`bootstrap/`):**

1. `kustomization.yaml`:
   - The install URL moves to `v3.5.7`.
   - The three `images:` pins become v3.5.7's images with digests: `quay.io/argoproj/argocd:v3.5.7`,
     `ghcr.io/dexidp/dex:v2.45.1`, and redis `8.2.3-alpine`.
   - The redis image name changes to `public.ecr.aws/docker/library/redis`. The old `name: redis` entry would no
     longer match anything, and the pin would silently lapse.
2. New `argocd-cm-tracking-exclusions-patch.yaml`. It sets `application.resourceTrackingMethod: label` and
   `resource.exclusions`, which is v3.5.7's default without the Lease entry. A comment says to recopy the list from
   the new release's `install.yaml` at the next upgrade.
3. `argocd-server-insecure-patch.yaml` doesn't change. v3.5.7's `argocd-server` args are still
   `[/usr/local/bin/argocd-server]`, so the patch's list still applies.
4. The kustomization header says bootstrap is never re-applied. That is wrong: the bootstrap unit applies it on
   every run. The header is corrected.

**nixos_config (`modules/containers/k3d.nix`, line 606):**

1. `kubectl apply -k "$BOOTSTRAP_URL"` becomes `kubectl apply --server-side --force-conflicts -k "$BOOTSTRAP_URL"`.
   It works with v2.13.1 too. It must be deployed to p620 before change 1 reaches factory-gitops `main`. The unit
   applies `main` on every run (at each boot), and a client-side apply of the v3.5.7 CRDs fails.

### Two-phase apply (every apply: rehearsal, live, rollback)

A multi-object apply is not atomic. Without a barrier, the controllers can be updated even when a CRD failed. So
every ArgoCD apply in this task runs in two phases:

1. `kustomize build <bootstrap> | yq 'select(.kind == "CustomResourceDefinition")'`, applied with
   `--server-side --force-conflicts`. Then `kubectl wait --for condition=established` on the three CRDs. If the
   apply or the wait fails, stop.
2. The rest of the build, without the root Application in the rehearsal, applied the same way. Then
   `kubectl rollout status` for `argocd-server`, `argocd-repo-server`, `argocd-redis` and `argocd-dex-server`, and for
   the `argocd-application-controller` StatefulSet.

The bootstrap unit (change 5) keeps a single server-side apply. It runs on a fresh cluster or as an idempotent
re-apply, and it already retries through a restart.

The CRDs are never deleted and re-created, not even in a rollback, because deleting a CRD deletes every Application.
Both versions serve and store their CRDs as `v1alpha1`, so there is no storage migration to undo.

### Order

1. Merge and deploy change 5 (nixos_config) on p620. The bootstrap unit is a oneshot started at boot, so a switch
   doesn't run it.
2. Run the rehearsal (below) against the factory-gitops branch.
3. Back up (below). The owner runs the one secret-holding command.
4. Agree the window, announce on the bus, merge the factory-gitops PR, and apply it to the live cluster in two
   phases.

### Rehearsal (throwaway cluster)

**Setup:**

- A k3d cluster `argocd-rehearsal` on p620: k3s v1.35.10, one server, no port mappings, no volumes. Every command
  names its context explicitly (`--context k3d-argocd-rehearsal`), never the default one.
- The root Application is never applied: not at install, not at the upgrade, not at the rollback. Each apply is the
  bootstrap build with root filtered out. That way nothing can turn auto-sync back on for the children.
- Install ArgoCD v2.13.1 from `main`'s `bootstrap/`, in two phases.
- **Pinned sources.** Create the 44 child Applications with `syncPolicy.automated` removed. Set each one's
  `targetRevision` to the commit its branch points at when the rehearsal starts, recorded in a file. Both versions
  then render the same source, so a difference comes from the renderer and not from an upstream commit.
  - Without auto-sync, ArgoCD renders and compares every app but deploys nothing. The apps that would talk to live
    services (cloudflared, fides-reporter, the host probe to `host.k3d.internal:11434`, the RFactory runner) create
    no workload.
- **Synced apps.** Sync four apps by hand: keda (SSA, large CRDs), kyverno and kyverno-policies (adoption by label),
  and coredns-upstream. These four run only in-cluster controllers and configuration. The plan confirms from their
  manifests that none of them calls out to a live service.
- **Two test Applications** from a scratch directory in the rehearsal only, never committed to `apps/`:
  - `cronjob-health`: one CronJob that succeeds and one that fails (3.1→3.2's CronJob health change);
  - `label-adoption`: a single ConfigMap, synced with `prune: true`.

**Record, on v2.13.1:**

- for every app: sync status, health, and comparison errors;
- every app's full desired manifests (`argocd --core app manifests <app> --source git`), normalised with sorted keys;
- for the four synced apps: the `metadata.uid` of every managed object, read from the live object for each entry in
  `.status.resources`. A missing object, or a list that can't be collected completely, fails the step;
- the three CRDs' `.spec`, and the `managedFields` managers of the CRDs and of `argocd-cm`.

**Upgrade** to the branch in two phases. Then sync the four apps and the two test apps by hand.

**Pass on v3.5.7 when:**

- no app has a comparison error;
- every app's normalised desired manifests equal the v2.13.1 record, field for field. A difference is either
  explained in the plan and accepted by the owner, or it fails the step;
- rfactory-desktops still lists `Lease/rfactory-runner`;
- the four synced apps are Synced and Healthy after the explicit sync, every recorded UID is unchanged, and their
  resources still carry the tracking label;
- **adoption:** a second ConfigMap applied by hand with `label-adoption`'s instance label is pruned at the next sync,
  just as it is on v2.13.1. This shows label tracking is still in force;
- `cronjob-health` reads `Degraded` because of the failing CronJob. This confirms the new health rule and shows how
  a failed run will look on the live cluster.

**Rollback** to `main`'s `bootstrap/` (v2.13.1) in two phases, then sync the four apps again by hand.

**Pass on the rollback when:**

- the checks above give the v2.13.1 results again;
- the three CRDs' `.spec` equals the v2.13.1 record;
- the `managedFields` managers are back to the recorded set. A field that keeps a 3.5.7-only manager is listed in
  the plan, with whether it matters.

Then delete the cluster.

### Live upgrade

**Before:**

- 45 Applications Synced and Healthy;
- the last run of every CronJob succeeded (true on 2026-11-18: 24 CronJobs, none whose last run failed);
- a dated record, under `/var/lib/k3d-backups/argocd-<date>/`, of the `metadata.uid` of every object listed in
  every app's `.status.resources`, read from the live objects, failing if any is missing;
- a backup of Applications, AppProjects, and the configmaps `argocd-cm`, `argocd-rbac-cm` and
  `argocd-cmd-params-cm`, in the same directory.

**Secret backup:** `argocd-secret` (server key, admin hash) is not changed by the upgrade. The owner backs it up
with one command that writes it straight to a `0600` file in the same directory. The agent never reads it and
checks only that the file exists.

**Apply** from factory-gitops `main` after the merge, in two phases.

**After:**

- 45 Synced. Healthy, except for an app whose CronJob's last run failed after the upgrade started. That one is
  checked against its job's logs, not waived.
- Every recorded UID is unchanged. Controller-created children (Pods, ReplicaSets, Jobs) are not compared, because
  they come and go on their own.
- The UI loads through cloudflared.
- `Lease/rfactory-runner` is still listed.
- The images run at the pinned digests.

### Rollback

Revert the factory-gitops merge and apply `bootstrap/` in two phases. The rehearsal proves this restores v2.13.1:
CRD schemas, ownership, and app behaviour. Label tracking never changed, so there is no tracking metadata to undo.
Change 5 stays, because it works with both versions.

## Alternatives rejected

- **v3.6.1:** only its second patch. It can follow later as a minor upgrade.
- **One minor at a time:** about eight applies on the live cluster, each a short ArgoCD outage. The guides don't
  require it, and the rehearsal covers the jump.
- **Annotation tracking now:** the owner chose label for this task.
- **Upgrade in place without a rehearsal:** the owner chose to rehearse.
- **Rehearsal with auto-sync, or with the root Application:** it would start real cloudflared connectors on the live
  tunnel, CronJobs that report to fides, and the RFactory runner against shared services.
- **Rehearsal comparing only resource names:** a renderer change to an image, a command or RBAC would pass
  unnoticed, and live selfHeal would then apply it.
- **Leave Leases excluded:** rfactory-desktops manages one. A recreate would no longer create it.
- **Delete and re-create the CRDs on rollback:** that deletes every Application.

## Risks

- **The bootstrap unit runs between the two merges.** If p620 reboots after the factory-gitops merge but before
  change 5 is deployed, the unit's client-side apply fails, and it is not atomic. Some objects may be at v3.5.7 and
  others still at v2.13.1. The order above prevents this. If it happens anyway, the fix is the two-phase apply by
  hand.
- **A renderer difference the owner accepts** still reaches the live apps through selfHeal at the upgrade. The
  rehearsal lists every such difference first.
- **The exclusions list goes stale** at the next upgrade. The comment in the patch says to recopy it.
- **The ArgoCD controller restarts during the apply.** Apps keep running, and only reconciliation pauses, for about
  a minute.
- **SSA with `--force-conflicts`** takes over ownership of the ArgoCD fields from the client-side field manager.
  This is expected, and the guide requires it. The rehearsal records what a rollback leaves behind.
- **CronJob health** can now turn an app `Degraded` at any later failed run. That is intended behaviour, not part of
  this upgrade's acceptance.

## Verification

- The rehearsal passes every check, including the rollback.
- `kustomize build bootstrap/` renders. Every image in it carries a digest, and none still points at the old redis
  name.
- The nixos_config change builds for p620. `systemctl cat k3d-cluster-bootstrap` shows the server-side apply.
- The live "after" checks pass.
