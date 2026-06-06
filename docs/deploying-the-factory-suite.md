# Deploying the Factory suite (ArgoCD + Keycloak, multi-tenant)

How the four Factory products run as **stable, released versions** on the **k3d cluster on p510**,
driven by ArgoCD GitOps from this repo — while local development continues from source. Adds a
single **Keycloak** for central identity and **multi-tenancy** so friends can log in and test.

> Tracked by epic [#2](https://github.com/olafkfreund/factory-gitops/issues/2) and its child issues.

## Goal

- One place to run the whole **PARR** pipeline (PFactory → AIFactory → TFactory → CFactory).
- Stable, reproducible, GitOps-managed deployments. Upgrades = bump an image tag via PR; ArgoCD syncs.
- Central login (Keycloak) with per-tenant groups so testers get scoped access.

Local dev is unchanged: run each product from source on loopback with `APP_DISABLE_AUTH=true`. The
**cluster runs released image tags only**.

## Architecture

```
Tailnet (freundcloud)                 k3d cluster on p510  (ArgoCD app-of-apps from this repo)
  argocd.tail833f7.ts.net  ─┐         ns: argocd   → ArgoCD
  keycloak.…ts.net         ─┼─ TS ───▶ ns: factory  → postgres (DBs: pfactory/aifactory/
  pfactory/aifactory/…     ─┘            tfactory/cfactory/keycloak)
                                         keycloak (+ oauth2-proxy for cfactory)
   each app Pod = [app container] + [tailscale sidecar]
   apps talk via http://<svc>.factory.svc.cluster.local:<port>
   OIDC issuer = https://keycloak.<tailnet>/realms/factory
```

Each product's ArgoCD `Application` (in `apps/<product>/application.yaml`) points at `deploy/k8s`
**inside its product repo**. Until those directories exist, the Applications report
`ComparisonError` — an intentional TODO list. This effort fills them in.

## Canonical ports & service DNS

| Product | API port | Cluster DNS |
|---|---|---|
| PFactory | `3114` | `http://pfactory.factory.svc.cluster.local:3114` |
| AIFactory | `3101` | `http://aifactory.factory.svc.cluster.local:3101` |
| TFactory | `3103` | `http://tfactory.factory.svc.cluster.local:3103` |
| CFactory | `3111` (API) / `3110` (cockpit) | `http://cfactory.factory.svc.cluster.local:3111` |

Bind via `APP_PORT` (AIF/PF/TF) or `CFACTORY_BACKEND_PORT` (CF).

## Inter-service wiring

- **CFactory upstreams** (set in its ConfigMap to cluster DNS, not localhost):
  `CFACTORY_AIFACTORY_API_URL`, `CFACTORY_PFACTORY_API_URL`, `CFACTORY_TFACTORY_API_URL`;
  plus `CFACTORY_SUBSCRIBE_UPSTREAMS=true`, `CFACTORY_LIVE_PROGRESS=true`.
- **Completion events → CFactory** (RFC-0001): each of AIF/PF/TF sets
  `*_COMPLETION_WEBHOOK=http://cfactory.factory.svc.cluster.local:3111/api/events`.

## Runtime dependencies

- **Postgres** (one shared instance, a DB per service) — replaces the per-app SQLite default.
- **PVC per app** mounted at `~/.<product>/` for workspaces.
- **Docker socket** for TFactory/PFactory test runners (host `/var/run/docker.sock`, or
  `TFACTORY_CONTAINER_BIN=podman`).
- **Secrets** seeded as `factory/factory-secrets` by the agenix bootstrap (same mechanism as the
  Tailscale auth key): `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `OPENAI_API_KEY` (opt),
  `CFACTORY_AUDIT_HMAC_SECRET`, Postgres creds, and (Phase 2) the OIDC client secrets.

## Images

AIFactory/PFactory/TFactory publish `ghcr.io/olafkfreund/{aifactory,pfactory,tfactory}:vX.Y.Z`
via each repo's `.github/workflows/release.yml` (triggered by a `package.json` version bump).
**CFactory needs a release pipeline** (its first gap) and a decision on serving its separate Vite
cockpit (`apps/frontend-web`), since the backend image is backend-only. Manifests **pin image
tags** (never `:latest`), per this repo's image-pinning convention.

## Identity & multi-tenancy (Keycloak)

- **Native OIDC** is already built into AIFactory/PFactory/TFactory (`APP_OIDC_ENABLED`,
  `APP_OIDC_ISSUER_URL`, `APP_OIDC_CLIENT_ID`, `APP_OIDC_CLIENT_SECRET`, `APP_OIDC_REDIRECT_URI`).
  They become OIDC relying parties of the `factory` realm.
- **CFactory has no native OIDC** (`CFACTORY_API_KEYS` + `CFACTORY_MULTI_TENANT`/`X-Tenant-Id`) →
  fronted by **oauth2-proxy** bound to a Keycloak `cfactory` client.
- **Tenancy model:** single shared instance + a **Keycloak group per tenant**; a `tenant` claim is
  mapped to `X-Tenant-Id`.

!!! warning "Known limitation — shared data"
    CFactory per-tenant **data** isolation is currently *deferred*. Multi-tenancy gives separate
    **logins and roles**, but tenants **share data** until app-level scoping lands. Acceptable for
    collaborative friend-testing; tracked as product issues (see epic #2).

## Phased rollout

1. **Phase 1 — services + Postgres (single-user, no SSO):** CFactory image; `deploy/k8s/` for all
   four; shared Postgres (`infra/postgres` + `apps/postgres`); `factory-secrets` via agenix; verify
   on p510.
2. **Phase 2 — Keycloak SSO:** deploy Keycloak (`infra/keycloak` + `apps/keycloak`, Tailscale
   sidecar); `factory` realm + per-app OIDC clients as-code; enable OIDC in the three native apps;
   oauth2-proxy for CFactory.
3. **Phase 3 — multi-tenancy:** Keycloak groups → `tenant` claim → `X-Tenant-Id`; file product
   data-isolation issues; document the shared-data limitation.

## Operating

This is the deployment design/runbook for the Factory products specifically. For cluster-level ops
(bootstrap, ArgoCD sync, auth-key rotation, full reset) see the [Operating Guide](operating.md).
Adding a product deployment follows the same recipe as any service — see
[Repo Layout](layout.md) and the `apps/` README. Tailnet exposure uses the
[sidecar pattern](sidecar-pattern.md).

## Verification

- `ssh p510 'KUBECONFIG=/etc/k3d/kubeconfig kubectl -n factory get pods'` → all Ready.
- ArgoCD UI: root + `postgres`, `pfactory`, `aifactory`, `tfactory`, `cfactory` Synced/Healthy.
- CFactory `/health` shows the three upstreams at cluster DNS (not localhost).
- A minimal PARR run threads through the CFactory cockpit; (Phase 2) tailnet login redirects to
  Keycloak; (Phase 3) two users in different groups get scoped access.
