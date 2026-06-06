# factory-gitops

GitOps source repo for the **k3d cluster on p510**, managed by ArgoCD
using the App-of-Apps pattern.

> The cluster lives in [olafkfreund/nixos_config](https://github.com/olafkfreund/nixos_config).
> The bootstrap unit there (`modules/containers/k3d.nix`) applies the
> `bootstrap/` kustomization from this repo to install ArgoCD and the
> root `Application`. Everything else (apps, infra) reaches the cluster
> via the GitOps loop ArgoCD drives from here.

## Layout

```
factory-gitops/
├── README.md                         ← you are here
├── catalog-info.yaml                 ← Backstage Component for this repo
├── mkdocs.yml + docs/                ← TechDocs source (rendered in Backstage)
├── bootstrap/                        ← Applied ONCE by the Nix bootstrap unit
│   ├── kustomization.yaml
│   ├── argocd-namespace.yaml
│   ├── argocd-install.yaml           ← upstream argo-cd, pinned version
│   ├── argocd-sidecar-patch.yaml     ← Tailscale sidecar patched onto argocd-server
│   └── argocd-root-app.yaml          ← App-of-Apps root Application
└── apps/                             ← One Application per product/service
    ├── README.md
    ├── aifactory/
    │   └── application.yaml          ← placeholder (points at sibling placeholder/)
    ├── pfactory/
    │   └── application.yaml
    ├── tfactory/
    │   └── application.yaml
    └── cfactory/
        └── application.yaml
```

## Tailnet exposure: the sidecar pattern

Each Pod that should be reachable on the freundcloud tailnet runs an
in-pod `tailscale` sidecar container. The sidecar reads `TS_AUTHKEY`
from the `tailscale-auth-key` Secret in its own namespace — seeded
automatically by the k3d-cluster-bootstrap unit on p510 (see the
[NixOS module](https://github.com/olafkfreund/nixos_config/blob/main/modules/containers/k3d.nix)).

ArgoCD itself uses this pattern — `bootstrap/argocd-sidecar-patch.yaml`
patches `argocd-server` to add the sidecar, so the UI shows up at
`https://argocd.tail833f7.ts.net` once the cluster is up.

For the per-service template see [docs/sidecar-pattern.md](docs/sidecar-pattern.md).

## "Why no Tailscale Operator?"

Short version: the operator requires OAuth client credentials from
`Settings → OAuth clients` in the Tailscale admin. This homelab is
wired with a plain auth key from `Settings → Keys`. Sidecars work with
what we have. Long version in [docs/why-not-operator.md](docs/why-not-operator.md).

## Operating notes

| What | Where |
|---|---|
| Add a new service | Commit `apps/<name>/application.yaml`, push — ArgoCD picks it up in ~3 min |
| Trigger a sync | `argocd app sync root` or in the UI |
| Reset and re-bootstrap | `systemctl restart k3d-cluster-bootstrap` on p510 |
| Auth-key rotation | `manage-secrets.sh edit tailscale-k8s-operator-oauth` on nixos_config, redeploy p510, bounce Pods |
| Cluster ops runbook | <https://github.com/olafkfreund/nixos_config/blob/main/docs/applications/k3d-cluster.md> |
| Architecture rationale | <https://github.com/olafkfreund/nixos_config/blob/main/docs/architecture/k3d-architecture.md> |

## Backstage

Backstage's GitHubEntityProvider auto-discovers the `catalog-info.yaml`
in this repo. After your first push, give it ~5 min, then it'll appear
under the `freundcloud-infra` system. TechDocs is built from `docs/`
via `mkdocs.yml`.
