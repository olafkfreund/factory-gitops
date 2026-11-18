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

### Order

1. Merge and deploy change 5 (nixos_config) on p620. The bootstrap unit is a oneshot started at boot, so a switch
   doesn't run it.
2. Run the rehearsal (below) against the factory-gitops branch.
3. Back up. The owner runs the one secret-holding command (below).
4. Agree the window, announce on the bus, merge the factory-gitops PR, and apply it to the live cluster.

### Rehearsal (throwaway cluster)

- A k3d cluster `argocd-rehearsal` on p620: k3s v1.35.10, one server, no port mappings, no volumes, a separate
  kubeconfig context.
- Install ArgoCD from `bootstrap/` on `main` (v2.13.1), without the root Application.
- Create the 44 child Applications with `syncPolicy.automated` removed. ArgoCD then renders and compares all of them
  but deploys nothing. So no second cloudflared connector, CronJob or runner starts against the live services.
- Really sync four apps that have no outside effects and cover the risky changes: keda (SSA, large CRDs), kyverno
  and kyverno-policies (adoption by label), and coredns-upstream.
- Record per app: sync status, health, comparison errors, and the list of rendered resources (`.status.resources`:
  group, kind, namespace, name). For the four synced apps, also record the UID of every managed resource.
- Upgrade with the branch: `kubectl apply --server-side --force-conflicts -k <branch>/bootstrap`. Wait for the
  ArgoCD rollouts.
- It passes when:
  - no app has a comparison error;
  - every app renders the same resource list as on v2.13.1;
  - rfactory-desktops still lists `Lease/rfactory-runner`;
  - the four synced apps are Synced and Healthy, with unchanged UIDs, so nothing was pruned or re-created;
  - the tracking label is still on their resources.
- Then the rollback: apply `main`'s `bootstrap/` (v2.13.1) the same way. The same checks pass.
- Delete the cluster.

### Live upgrade

- **Before:**
  - 45 Applications Synced and Healthy;
  - a dated record of every managed resource's UID (from every app's `.status.resources`);
  - a backup of Applications, AppProjects, and the configmaps `argocd-cm`, `argocd-rbac-cm` and
    `argocd-cmd-params-cm` under `/var/lib/k3d-backups/argocd-<date>/`.
- **Secret backup:** `argocd-secret` (server key, admin hash) is not changed by the upgrade. The owner backs it up
  with one command that writes it straight to a `0600` file in the same directory. The agent never reads it and
  checks only that the file exists.
- **Apply:** `kubectl apply --server-side --force-conflicts -k` from factory-gitops `main` after the merge, the same
  command the bootstrap unit runs.
- **After:**
  - 45 Synced and Healthy;
  - no managed resource UID changed;
  - the UI loads through cloudflared;
  - `Lease/rfactory-runner` is still listed;
  - images run at the pinned digests.

### Rollback

Revert the factory-gitops merge and apply `bootstrap/` the same way. The rehearsal proves this restores v2.13.1. Label
tracking never changed, so there is no tracking metadata to undo. Change 5 stays, because it works with both
versions.

## Alternatives rejected

- **v3.6.1:** only its second patch. It can follow later as a minor upgrade.
- **One minor at a time:** about eight applies on the live cluster, each a short ArgoCD outage. The guides don't
  require it, and the rehearsal covers the jump.
- **Annotation tracking now:** the owner chose label for this task.
- **Upgrade in place without a rehearsal:** the owner chose to rehearse.
- **Rehearsal with auto-sync:** it would start real cloudflared connectors on the live tunnel, CronJobs that report
  to fides, and the RFactory runner against shared services.
- **Leave Leases excluded:** rfactory-desktops manages one. A recreate would no longer create it.

## Risks

- **The bootstrap unit runs between the two merges.** If p620 reboots after the factory-gitops merge but before
  change 5 is deployed, the client-side apply fails. That leaves a warning and the old version running, because
  the unit only warns on failure. The order above prevents it.
- **Helm 4 renders fides-reporter differently.** The rehearsal compares resource lists, not every field. A changed
  field shows up as OutOfSync after the upgrade, and selfHeal then applies the new render.
- **The exclusions list goes stale** at the next upgrade. The comment in the patch says to recopy it.
- **The ArgoCD controller restarts during the apply.** Apps keep running, and only reconciliation pauses, for about
  a minute.
- **SSA with `--force-conflicts`** takes over ownership of the ArgoCD fields from the client-side field manager.
  This is expected, and the guide requires it.

## Verification

- The rehearsal passes every check, including the rollback.
- `kustomize build bootstrap/` renders. Every image in it carries a digest, and none still points at the old redis
  name.
- The nixos_config change builds for p620. `systemctl cat k3d-cluster-bootstrap` shows the server-side apply.
- The live "after" checks pass.
