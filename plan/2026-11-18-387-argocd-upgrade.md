---
status: draft
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
- **Every apply runs in two phases:**
  1. CRDs only, server-side with `--force-conflicts`, then `kubectl wait --for condition=established` on all three;
  2. the rest, then a rollout status check of every ArgoCD workload.

  CRDs are never deleted.
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

   **Verify:** `systemctl cat k3d-cluster-bootstrap` shows `--server-side --force-conflicts`.

5. **The rehearsal script**, kept in the scratchpad and not committed: `rehearse-387.sh`, with every `kubectl` and
   `argocd` call taking `--context k3d-argocd-rehearsal`.
   1. Create the k3d cluster (k3s `rancher/k3s:v1.35.10-k3s1`, one server, no ports, no volumes).
   2. Install from `main`'s `bootstrap/`, in two phases, without the root Application.
   3. Record each child app's branch head, then create the 44 child Applications with `syncPolicy.automated` deleted
      and `targetRevision` set to that commit.
   4. Create the two test apps from a scratch directory that is never committed.
   5. Sync the four apps and the two test apps by hand.
   6. Record, for every app:
      - sync status, health, and conditions;
      - the normalised `argocd --core app manifests --source git`;
      - UIDs, read from the live objects listed in `.status.resources` (fail if any is missing).

      Also record the three CRDs' `.spec`, and the `managedFields` managers of the CRDs and of `argocd-cm`.
   7. Upgrade with the branch's `bootstrap/` (two phases, root filtered out), sync the six apps again, and record
      again.
   8. Run the adoption check: apply a second ConfigMap by hand with `label-adoption`'s instance label, sync, and
      expect it to be pruned. Run this on both versions.
   9. Roll back with `main`'s `bootstrap/` (two phases), sync again, and record again.
   10. Diff the records and print a pass or fail for each spec check.
   11. Delete the cluster.

   **Verify:** `bash -n` and `shellcheck` are clean. Codex has reviewed the script. Its dry-run mode prints every
   command without running any.

   **Traps:**
   - A missing `--context` would hit the live cluster: the script refuses to start unless the current context is
     the rehearsal one.
   - Never apply the root Application.
   - The four synced apps were checked by the lead for outbound calls to live services before this step: keda,
     kyverno, kyverno-policies, coredns-upstream.

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
