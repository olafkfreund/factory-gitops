# factory-gitops

GitOps source repo for the **k3d cluster on p510**. ArgoCD watches
this repo and reconciles whatever it finds under `apps/`. The k3d
cluster itself lives in [olafkfreund/nixos_config](https://github.com/olafkfreund/nixos_config).

## Quick links

- **[Repo layout](layout.md)** — directory tree + what each file does
- **[Sidecar pattern](sidecar-pattern.md)** — how Pods reach the tailnet
- **[Why not the operator](why-not-operator.md)** — design decision
- **[Bootstrap flow](bootstrap-flow.md)** — what happens on first boot
- **[Operating guide](operating.md)** — day-2 ops, rotation, reset

## Cross-repo references

- Cluster module: [nixos_config/modules/containers/k3d.nix](https://github.com/olafkfreund/nixos_config/blob/main/modules/containers/k3d.nix)
- Cluster ops runbook: [nixos_config/docs/applications/k3d-cluster.md](https://github.com/olafkfreund/nixos_config/blob/main/docs/applications/k3d-cluster.md)
- Architecture: [nixos_config/docs/architecture/k3d-architecture.md](https://github.com/olafkfreund/nixos_config/blob/main/docs/architecture/k3d-architecture.md)
- GitOps workflow: [nixos_config/docs/guides/factory-gitops.md](https://github.com/olafkfreund/nixos_config/blob/main/docs/guides/factory-gitops.md)

## ArgoCD UI

Once the cluster is up and the Tailscale sidecar on `argocd-server` has
registered: **<https://argocd.tail833f7.ts.net>**

Initial admin password (on p510):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```
