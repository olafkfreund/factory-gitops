# deploy-live/ — Phase 1 cluster bring-up manifests

Working Kubernetes manifests that brought the **Factory suite live** on the p510 k3d cluster
(`factory` namespace). Part of epic
[#2](https://github.com/olafkfreund/factory-gitops/issues/2).

> **Status:** applied **imperatively** (`kubectl apply`) to get the suite running and verified.
> Repointing the ArgoCD `apps/<product>/application.yaml` placeholders at these manifests so ArgoCD
> manages them is the remaining GitOps step (issue #4). Until then a cluster reset loses these.

## What's live (verified Ready + `/health` green)

| Workload | Image | Port | Notes |
|---|---|---|---|
| `aifactory` | `ghcr.io/olafkfreund/aifactory:v3.4.2` | 3101 | SQLite on PVC `aifactory-data` |
| `pfactory` | `ghcr.io/olafkfreund/pfactory:0.6.0` | 3114 | SQLite on PVC `pfactory-data` |
| `tfactory` | `ghcr.io/olafkfreund/tfactory:0.5.0` | 3103 | SQLite on PVC; Docker test-runners need DinD (deferred) |
| `cfactory` (backend) | `ghcr.io/olafkfreund/cfactory:0.1.0` | 3111 | upstreams wired to cluster DNS |
| `cfactory-frontend` (cockpit) | `ghcr.io/olafkfreund/cfactory-frontend:0.1.0` | 80→8080 | Tailscale sidecar → `https://cockpit.tail833f7.ts.net` |

The app manifests now live per-product under `apps/<product>/manifests/` and are managed by each
product's ArgoCD Application (`apps/<product>/application.yaml`). This directory keeps only the
deferred Postgres + this note.

`postgres.yaml` — shared Postgres (currently **deferred**: the k3d node's `/dev/shm` is 64M and
postgres `initdb` SIGBUSes; bump node shm in the nixos_config k3d module, then switch the apps'
`*_DATABASE_URL` to Postgres).

## Key wiring decisions

- Images live under `ghcr.io/olafkfreund/*` (the chart's `dataseeek` default is inaccessible).
- Private images pulled via the existing `ghcr-pull` secret.
- Secrets via `factory-secrets` (ANTHROPIC_API_KEY, GITHUB_TOKEN, CFACTORY_AUDIT_HMAC_SECRET).
- `enableServiceLinks: false` everywhere — k8s was injecting `CFACTORY_FRONTEND_PORT=tcp://…` which
  clobbered CFactory's `frontend_port` setting.
- `fsGroup: 65532` so the non-root app user can write its PVC.
- Auth: apps run with auth ON (first-run bearer token); OIDC/Keycloak is Phase 2.

## Re-apply

```bash
KUBECONFIG=/etc/k3d/kubeconfig kubectl apply -f deploy-live/apps.yaml
```
