# Repo Layout

```
factory-gitops/
├── README.md
├── catalog-info.yaml              ← Backstage entities
├── mkdocs.yml + docs/             ← TechDocs (this site)
├── bootstrap/                              ← Applied ONCE by the Nix k3d-cluster-bootstrap unit
│   ├── kustomization.yaml                  ← Entrypoint Kustomize root; inlines upstream argo-cd URL
│   ├── argocd-namespace.yaml               ← Namespace `argocd`
│   ├── argocd-sidecar-patch.yaml           ← Strategic-merge patch onto argocd-server: adds the `tailscale` sidecar container
│   ├── argocd-tailscale-serve-config.yaml  ← ConfigMap with Tailscale Serve config (:443 → localhost:8080)
│   └── argocd-root-app.yaml                ← App-of-Apps root Application
└── apps/                          ← One Application per product/service
    ├── README.md                  ← How to add a service
    ├── aifactory/application.yaml ← Placeholder until AIFactory grows deploy/k8s/
    ├── pfactory/application.yaml
    ├── tfactory/application.yaml
    └── cfactory/application.yaml
```

## Conventions

| | |
|---|---|
| **Image pinning** | Always SHA-digest or version-tag pinned. Never `:latest`, never `:main`, never a `kustomize.config.k8s.io` ref to a branch. |
| **Sync policy** | `automated: { prune: true, selfHeal: true }` for every Application. The cluster should match Git, full stop. |
| **Namespaces** | `argocd` (control plane), `factory` (every product Pod), `tailscale` (the bootstrap-seeded auth-key Secret). |
| **Owner** | `owner: olafkfreund` everywhere — resolves to the Group declared in nixos_config/catalog-info.yaml. |

## Where files do NOT go

- **Plaintext secrets**: never. Use `kubectl create secret` out-of-band,
  or hand-author with `syncOptions: ["Replace=false"]`.
- **Cluster-wide CRDs / operators**: would live under `infrastructure/`
  if we had any. We deliberately don't — see
  [why-not-operator.md](why-not-operator.md).
- **Product source code**: lives in product repos (AIFactory, PFactory,
  etc.); only the ArgoCD `Application` CR pointing at it lives here.
