---
status: approved
issue: 387
spec: spec/2026-11-18-387-argocd-upgrade.md
coders:
  1: coder   # kustomization edits: URL, three digest pins, redis name, header text; mechanical
  2: coder   # one new patch file copied from the upstream manifest; mechanical
  3: coder   # one line in nixos_config's k3d.nix
  5: codex   # the rehearsal script: two-phase apply, pinned sources, normalised manifest diff, UID and managedFields records; tricky
reviewers:
  - codex    # read-only review of each diff and of the rehearsal script; agy is out of use (#2748)
---

# Plan: upgrade ArgoCD from v2.13.1 to v3.5.7

Self-contained: the approved decisions from the intent and spec, then the steps. factory-gitops branch
`chore/387-argocd-upgrade` (worktree `~/Projects/factory-gitops-387`). nixos_config branch
`fix/387-k3d-bootstrap-ssa` (worktree `~/.config/nixos-387`, created in step 3).

## Approved decisions

- **Target and method.** v3.5.7, in one jump (tested on Kubernetes 1.33 to 1.36). Use label tracking, set
  explicitly, with `application.resourceTrackingMethod: label`.
- **Leases.** `resource.exclusions` is v3.5.7's default list without the `coordination.k8s.io` Lease entry, so
  `Lease/rfactory-runner` stays managed.
- **Status field.** Keep #377's compare-options patch (`ignoreResourceStatusField: all`). It is the 3.x default, and
  it keeps a rollback to 2.13.1 working.
- **Image pins**, by digest:
  - `quay.io/argoproj/argocd:v3.5.7@sha256:16df57da6f223808d204cd94c67c929b931fa01670b91b0b3a2298c4647de0db`
  - `ghcr.io/dexidp/dex:v2.45.1@sha256:8499afd690c437f52301efd2b05b2455da5bd2dfc20332cd697dc9937f808462`
  - `public.ecr.aws/docker/library/redis:8.2.3-alpine@sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba`

  The redis image name changes, so the pin entry's `name:` changes too. Digests were resolved with `crane digest` on
  2026-11-18.
- **Every apply runs in two phases.** `B` is the bootstrap build: `kustomize build <bootstrap dir>`, with the root
  Application filtered out in the rehearsal.
  1. **CRDs.** Apply `B | yq 'select(.kind == "CustomResourceDefinition")'` with
     `kubectl apply --server-side --force-conflicts -f -`. Then wait:
     `kubectl wait --for condition=established --timeout=120s crd/applications.argoproj.io
     crd/applicationsets.argoproj.io crd/appprojects.argoproj.io`.
     **If the apply or the wait exits non-zero, stop.** Phase 2 does not run, and nothing else is changed.
  2. **The rest.** Apply `B | yq 'select(.kind != "CustomResourceDefinition")'` the same way. Then run
     `kubectl -n argocd rollout status --timeout=300s` on each workload:
     - the Deployments `argocd-server`, `argocd-repo-server`, `argocd-redis`, `argocd-dex-server`,
       `argocd-applicationset-controller` and `argocd-notifications-controller`;
     - the StatefulSet `argocd-application-controller`.

     If any check fails, stop and report. Don't retry blindly.

  CRDs are never deleted. These names are the same in v2.13.1 and v3.5.7.
- **Order:**
  1. The nixos_config change, so the bootstrap unit uses server-side apply, is deployed on p620 first.
  2. The rehearsal passes.
  3. Backup.
  4. In an agreed window: announce, merge factory-gitops, two-phase apply.
- **The rehearsal:**
  - It runs on a throwaway k3d cluster, `argocd-rehearsal`. The root Application is never applied.
  - It creates 44 child Applications without auto-sync, with sources pinned to recorded commits.
  - Four apps are synced by hand (keda, kyverno, kyverno-policies, coredns-upstream), plus two test apps
    (`cronjob-health`, `label-adoption`).
  - For every app it compares the full normalised desired manifests, UIDs read from the live objects, CRD specs and
    managedFields. That covers the upgrade, then the rollback.
- The owner runs the one command that backs up `argocd-secret`. The agent never reads it.

## Steps

1. **`bootstrap/kustomization.yaml`** (factory-gitops):
   - the install URL: `v2.13.1` → `v3.5.7`;
   - the three `images:` entries become the pins above, with the redis entry's `name:` set to
     `public.ecr.aws/docker/library/redis`;
   - the header comment that says bootstrap is "never re-applied" is replaced. The Nix bootstrap unit applies it on
     every run, at each boot of p620.

   **Verify:** `kustomize build bootstrap/ | grep -E 'image: '` shows only digest-pinned images, and none of them is
   plain `redis`.

   **Traps:** `newTag: "tag@sha256:…"`, not `digest:`. The reason is in `apps/keda/manifests/kustomization.yaml`.

2. **New `bootstrap/argocd-cm-tracking-exclusions-patch.yaml`** (factory-gitops), listed under `patches:`:
   - a strategic-merge patch on ConfigMap `argocd-cm`;
   - it sets `application.resourceTrackingMethod: label`;
   - it sets `resource.exclusions` to the v3.5.7 default, copied from that release's `manifests/install.yaml`, with
     the Lease rule (`apiGroups: [coordination.k8s.io]`, `kinds: [Lease]`) removed;
   - a comment says why the Lease rule is gone, and to recopy the list at every upgrade.

   **Verify:** `kustomize build bootstrap/ | yq 'select(.kind=="ConfigMap" and .metadata.name=="argocd-cm") | .data'`
   shows both keys, the compare options, and an exclusions list without Lease.

   **Traps:** `resource.exclusions` is a YAML list held inside a string. Keep the `|` block scalar.

3. **`modules/containers/k3d.nix`** in nixos_config, line 606, on a new worktree and branch from `origin/main`:
   `kubectl apply -k "$BOOTSTRAP_URL"` becomes `kubectl apply --server-side --force-conflicts -k "$BOOTSTRAP_URL"`.
   Update the comment above it with the reason (ArgoCD 3.3+ CRDs are too big for client-side apply, factory-gitops
   #387).

   **Verify:** `nix build .#nixosConfigurations.p620.config.system.build.toplevel`.

   **Traps:**
   - Never on `main` or in `~/.config/nixos`.
   - The PR links this plan in factory-gitops.

4. **Lead: deploy step 3 on p620.**
   - Merge the nixos_config PR after CI passes and Codex has reviewed it.
   - Announce on the bus, then switch p620.
   - Do not restart `k3d-cluster-bootstrap`: it would re-apply main's v2.13.1 bootstrap. That is harmless, but it
     isn't needed.

   **Verify:** the unit's `ExecStart` is a generated script (`k3d.nix` line 940), so check the script, not the unit:
   `grep -- '--server-side --force-conflicts -k' "$(systemctl show -p ExecStart --value k3d-cluster-bootstrap | sed -E 's/.*path=([^ ;]+).*/\1/')"`
   finds the line.

5. **The rehearsal script**, kept in the scratchpad and not committed: `rehearse-387.sh`. Every `kubectl` and
   `argocd` call passes `--context k3d-argocd-rehearsal`.

   **Fixtures**, in a scratch directory that is never committed:
   - `cronjob-health`: an Application on a plain directory holding two CronJobs, both with `schedule: "*/1 * * * *"`
     and `successfulJobsHistoryLimit: 1`. `ok` runs `true` and `fail` runs `false`, both from `busybox:1.36`.
   - `label-adoption`: an Application on a directory holding one ConfigMap, `adoption-keep`, with `syncPolicy:
     {automated: {prune: true}}`. It is the only rehearsal app with auto-sync, and it holds nothing but that
     ConfigMap.

   Both apps' `repoURL` is a local git repo served by the rehearsal only: a `git daemon` container on the k3d
   network. They never use a GitHub repo.

   **Pinned sources.** For each of the 44 child Applications, a `targetRevision` that is already a 40-hex commit
   (as rfactory-desktops has) is kept. A branch or tag is resolved once, with `git ls-remote <repoURL> <ref>`, to
   its commit. The result is written to `revisions.tsv` (app, original ref, commit) and used before and after.

   **The steps:**
   1. Refuse to start unless `kubectl config current-context` is `k3d-argocd-rehearsal`, after the cluster exists.
      Create the cluster with `k3d cluster create argocd-rehearsal --image rancher/k3s:v1.35.10-k3s1 --servers 1
      --agents 0 --no-lb`: no ports, no volumes.
   2. Install from `main`'s `bootstrap/`, in two phases, root filtered out.
   3. Create the 44 child Applications, with `syncPolicy.automated` deleted and `targetRevision` from
      `revisions.tsv`. Then the two fixtures.
   4. Sync keda, kyverno, kyverno-policies, coredns-upstream and `cronjob-health` by hand (`argocd --core app
      sync`). Wait two minutes so both CronJobs run.
   5. **Adoption check, v2.13.1.** Apply ConfigMap `adoption-stray` by hand with label
      `app.kubernetes.io/instance: label-adoption`. Sync `label-adoption`. Expect `adoption-stray` to be gone within
      60 s, and `adoption-keep` to remain.
   6. **Record**, written to `rec-<phase>/`:
      - per app: `.status.sync.status`, `.status.health.status`, and `.status.conditions`;
      - per app: `argocd --core app manifests <app> --source git`, normalised with `yq -P 'sort_keys(..)'`;
      - for the six synced apps only (the four plus both fixtures): `metadata.uid`, read from the live object for each
        `.status.resources` entry. A missing object fails the step. The 38 unsynced apps have no live objects, so they
        get no UID record;
      - `kubectl get crd <name> -o json | jq .spec`, for each of the three CRDs;
      - the sorted `metadata.managedFields[].manager` of the three CRDs and of `argocd-cm`.
   7. Upgrade with the branch's `bootstrap/`, in two phases, root filtered out. Then sync the five apps from step 4
      again.
   8. Adoption check again, as in step 5, on v3.5.7. Record into `rec-upgraded/`.
   9. Roll back with `main`'s `bootstrap/`, in two phases. Sync the five apps again. Adoption check again. Record
      into `rec-rollback/`.
   10. Print pass or fail for each check below, then delete the cluster and the `git daemon` container.

   **Checks on v3.5.7** (`rec-base` against `rec-upgraded`):
   - no app has a condition of type `ComparisonError`;
   - every app's normalised manifests are identical. Each difference is printed in full, and an unexplained one fails
     the check;
   - rfactory-desktops' `.status.resources` contains `coordination.k8s.io/Lease rfactory-desktops/rfactory-runner`;
   - keda, kyverno, kyverno-policies and coredns-upstream are `Synced` and `Healthy`, and every recorded UID is
     unchanged;
   - their recorded objects still carry the `app.kubernetes.io/instance` label, so label tracking is in force;
   - `adoption-stray` was pruned and `adoption-keep` kept, on both versions;
   - `cronjob-health` is `Degraded` on v3.5.7, from the `fail` CronJob, which is the 3.2 health rule. Its v2.13.1
     health is recorded, not judged.

   **Checks on the rollback** (`rec-base` against `rec-rollback`):
   - every check above, with the v2.13.1 results;
   - each CRD's `.spec` is identical to `rec-base`;
   - the managers set equals `rec-base`. A manager that is left over is printed with the fields it owns. It is a
     finding for the owner, not a pass.

   **Verify:** `bash -n` and `shellcheck` are clean, and Codex has reviewed the script. `--dry-run` prints every
   command without running any.

   **Traps:**
   - The context guard in step 1 is the only thing that keeps the script off the live cluster. It runs first, and
     again before every apply.
   - Never apply the root Application.
   - `label-adoption` has auto-sync, but its source is the local fixture repo. Nothing else gets auto-sync.
   - Before writing the script, the lead reads the manifests of keda, kyverno, kyverno-policies and coredns-upstream
     for outbound calls to live services. These are in-cluster controllers and config; any exception is written
     down here.

6. **Lead: run the rehearsal.** Report every check to the owner. A difference in the desired manifests is either
   explained, and then accepted or rejected by the owner, or it fails the step. Do not go on without a full pass,
   rollback included.

7. **Lead: back up.** In `/var/lib/k3d-backups/argocd-<date>/`:
   - Applications, AppProjects, and the configmaps `argocd-cm`, `argocd-rbac-cm` and `argocd-cmd-params-cm`;
   - the UID record for every app;
   - the CronJob last-run record.

   The owner runs, as one `!` command, the backup of `argocd-secret` to a `0600` file in that directory. The agent
   checks only that the file exists and is not empty.

8. **Lead: the live upgrade, in a window agreed with the owner and the dependent project.**
   1. Read the bus and announce the upgrade.
   2. Confirm the baseline: 45 apps Synced and Healthy, and the last run of every CronJob succeeded.
   3. Merge the factory-gitops PR. Codex has reviewed it and the rehearsal has passed.
   4. Run the two-phase apply from `main`.
   5. Run the after checks:
      - 45 apps Synced;
      - Healthy, except for a CronJob that failed after the upgrade, which is checked against its logs;
      - UIDs unchanged;
      - the UI loads through cloudflared;
      - `Lease/rfactory-runner` is still listed;
      - the images run at the pinned digests.
   6. Post the result on the bus and on the issue.

## Tests

| Check | Expected |
| --- | --- |
| `kustomize build bootstrap/` | renders, every image pinned by digest, no old redis name |
| p620 toplevel with step 3 | builds |
| rehearsal | every check passes, the rollback included |
| live after checks | pass |

## Rollback

Revert the factory-gitops merge and apply `bootstrap/` in two phases. The rehearsal proved this restores v2.13.1.
Step 3 stays, because it works with both versions. If a single app misbehaves after the upgrade, disable its
auto-sync first and then decide whether to roll back. Never delete a CRD.
