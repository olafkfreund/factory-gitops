---
status: draft
issue: 387
author: olafkfreund
---

# Intent: upgrade ArgoCD from v2.13.1 to a release that supports Kubernetes 1.35

## Problem

The p620 factory cluster has run k3s v1.35.10 since olafkfreund/nixos_config#3071. ArgoCD is still pinned at
v2.13.1 in `bootstrap/kustomization.yaml`, a release made long before 1.35 and never tested against it.

1.35 has already caused one failure. The four apps that use `ServerSideApply=true` failed to compare on the
`.status.terminatingReplicas` field. #377 works around that by setting `resource.compareoptions:
ignoreResourceStatusField: all` in `argocd-cm`, which hides status drift for every app, not just those four.

Current releases are v3.6.1 (2026-11-04) and v3.5.7 (2026-11-02). The move to 3.x is a major upgrade: 3.0 changed
defaults (resource tracking, RBAC, and others) that the 45 apps rely on without saying so.

Nothing reconciles `bootstrap/`. The Nix `k3d-cluster-bootstrap` unit applies it only when the cluster is created,
so an edit here changes nothing on the running cluster until someone applies it by hand.

## Proposed outcome

- ArgoCD in the factory cluster runs a 3.x release that supports Kubernetes 1.35, with its images pinned by digest
  as now (#161).
- All 45 Applications are Synced and Healthy afterwards, with no app deleted, re-created, or pruned by mistake.
- The #377 workaround is removed if the new release no longer needs it, or narrowed to the fields that still need it.
- A cluster recreate (`k3d-cluster-bootstrap`) installs the same version.

## Affected users and systems

- The p620 factory cluster (`k3d-factory`), and every project deployed from it. Another project depends on this
  cluster right now (nixos_config#3071).
- `bootstrap/` (install URL, digest pins, patches) and possibly app manifests that rely on 2.x defaults.
- The ArgoCD UI behind cloudflared (`argocd-server --insecure` patch), the dex image pin, and redis.

## Constraints

- No data loss and no unplanned pruning. Back up the ArgoCD state (Applications, AppProjects, `argocd-cm`,
  `argocd-rbac-cm`, secrets metadata) first. The cluster backups from the #3071 runbook stay in force.
- Pin to a released tag and digest, never `stable` or a branch.
- Announce on the agent bus before touching the cluster. Pick a window the dependent project can live with.
- A rollback path back to v2.13.1 must exist and be written down before the upgrade.

## Open questions

1. Target: the newest, v3.6.1 (released two weeks ago), or the older, more patched v3.5.7?
2. One jump from 2.13 to 3.x, or through the 2.14 line first? ArgoCD's upgrade notes go version by version.
3. Apply in place (`kubectl apply -k bootstrap/`, a short ArgoCD outage, apps keep running), or test first on a
   throwaway k3d cluster with the same apps?
4. When? It needs a window with the dependent project.
