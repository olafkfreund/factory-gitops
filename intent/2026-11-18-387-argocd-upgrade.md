---
status: draft
issue: 387
author: olafkfreund
---

# Intent: upgrade ArgoCD from v2.13.1 to a release that supports Kubernetes 1.35

## Problem

The p620 factory cluster has run k3s v1.35.10 since olafkfreund/nixos_config#3071. ArgoCD is still pinned at
v2.13.1 in `bootstrap/kustomization.yaml`, a release made long before 1.35 and never tested against it.

1.35 has already caused one failure. After the upgrade, keda, kyverno and coredns-upstream failed to compare. Their
typed-schema comparison didn't know Deployment's new `.status.terminatingReplicas` field. #377 works around that by
setting `resource.compareoptions: ignoreResourceStatusField: all`. That stops status from counting in sync
comparisons for every app, though health checks still read it. Four apps use `ServerSideApply=true`: keda, kyverno,
coredns-upstream and kubevirt.

Current releases are v3.6.1 (2026-11-04) and v3.5.7 (2026-11-02). Moving to 3.x is a major upgrade. These points
of 3.0 apply to this repo (taken from the 3.0 upgrade notes as remembered; the spec checks them against the current
docs):

- **Resource tracking** moves from the instance label to an annotation. The root Application and most child apps run
  `prune: true` with a cascading finalizer (`bootstrap/argocd-root-app.yaml`). The kyverno dry-run policy relies on
  the label to make ArgoCD adopt a resource
  (`apps/kyverno-policies/manifests/deploy-dryrun-sa-dryrun-only.yaml`, line 43).
- **Default resource exclusions** now include `coordination.k8s.io/Lease`, but `apps/rfactory-desktops` manages
  `Lease/rfactory-runner` (`application.yaml`, line 34).
- **`ignoreResourceStatusField: all`** becomes the default. Removing #377's patch would then only remove a duplicate
  setting; it wouldn't show that the schema problem is fixed.
- **The bundled Helm and kustomize** move to new versions. fides-reporter renders an external Helm chart, and skillai
  uses external manifests.
- ArgoCD's own RBAC (update/delete on sub-resources, logs) changes, but the repo has no custom ArgoCD RBAC
  policies. Live roles still need a check.

Nothing reconciles `bootstrap/`. The Nix `k3d-cluster-bootstrap` unit applies it only when the cluster is created.
A plain `kubectl apply -k` is client-side, and ArgoCD's CRDs can exceed the 256 KiB `last-applied-configuration`
annotation limit, the same reason keda uses server-side apply (`apps/keda/application.yaml`, line 42).

## Proposed outcome

- ArgoCD in the factory cluster runs a 3.x release that supports Kubernetes 1.35, with its images pinned by digest
  as now (#161). Its patches still apply: `--insecure` and compare options.
- All 45 Applications (root plus 44) are Synced and Healthy afterwards, and nothing is deleted, re-created or pruned
  by mistake.
- Resource tracking and resource exclusions are set on purpose, not left to new defaults. `Lease/rfactory-runner`
  stays under ArgoCD unless the spec decides otherwise.
- #377's patch is either kept with a reason or removed, and the spec records which.
- A cluster recreate (`k3d-cluster-bootstrap`) installs the same version, the same way.

## Affected users and systems

- The p620 factory cluster (`k3d-factory`) and every project deployed from it. Another project depends on this
  cluster right now (nixos_config#3071).
- `bootstrap/` (install URL, digest pins, patches, `argocd-cm`). Possibly app manifests that depend on 2.x
  behaviour, and the Nix bootstrap unit's apply command (`modules/containers/k3d.nix` in nixos_config).

## Constraints

- No data loss and no unplanned pruning.
- Before touching anything, have a restore source for ArgoCD's state, including secret values, not just their
  metadata: `argocd-secret` holds signing material (`docs/secrets-management.md`, line 94). The cluster backups from
  the #3071 runbook stay in force.
- A written rollback to v2.13.1 that covers the CRDs and the tracking metadata.
- Server-side apply for the CRDs, and CRDs in place before the controllers that use them.
- Pin to a released tag and digest, never `stable` or a branch.
- Announce on the agent bus before touching the cluster, and agree a window with the dependent project.

## Open questions

1. Which target? Choose by Kubernetes 1.35 support in the release's own support matrix and by how long the line is
   maintained: v3.6.x or v3.5.x.
2. One jump, or one minor version at a time? Either way the spec reads every upgrade guide between 2.13 and the
   target.
3. Tracking: keep label tracking for this upgrade and move to annotations in a separate task (smaller, recommended),
   or migrate now?
4. Rehearse on a throwaway k3d cluster with the same apps before the in-place upgrade, or upgrade in place directly?
5. When? It needs a window with the dependent project.
