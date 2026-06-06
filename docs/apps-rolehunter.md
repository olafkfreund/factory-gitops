# RoleHunter deployment

RoleHunter is a self-hosted, single-user AI job-hunt workspace (Next.js 15 +
PostgreSQL 16 / pgvector + LLM providers). It runs in the `factory` namespace on
the p510 k3d cluster, reconciled by ArgoCD from
[`github.com/olafkfreund/rolehunter`](https://github.com/olafkfreund/rolehunter) —
the Kubernetes manifests live in that repo under `deploy/k8s/` (kustomize), and
`apps/rolehunter/application.yaml` here points ArgoCD at them.

## App-of-Apps wiring

| Field | Value |
| --- | --- |
| `source.repoURL` | `https://github.com/olafkfreund/rolehunter` |
| `source.path` | `deploy/k8s` |
| `source.targetRevision` | `main` |
| `destination.namespace` | `factory` |
| `syncPolicy` | automated, `prune: true`, `selfHeal: true`, `CreateNamespace=true` |

The root app discovers `apps/rolehunter/application.yaml` automatically; commit +
push and ArgoCD reconciles in ~3 min.

## What it deploys

| Object | Kind | Sync wave | Notes |
| --- | --- | --- | --- |
| `rolehunter-db` | StatefulSet + headless Service | 0 | `pgvector/pgvector:pg16`, 8Gi `local-path` PVC, `/dev/shm` Memory emptyDir (avoids initdb "Bus error") |
| `rolehunter-migrate` | Job (ArgoCD `Sync` hook) | 1 | Drizzle migrations (`node scripts/migrate.mjs`); re-runs each sync; waits for the DB |
| `rolehunter-app` | Deployment + Service | 2 | Next.js standalone + Tailscale sidecar; 5Gi uploads PVC; `Recreate` strategy |

Sync waves enforce DB → migrations → app ordering on a fresh cluster. The
migration is a `Sync`-phase hook (not `PreSync`) so it runs after the DB is
healthy instead of deadlocking on a DB that doesn't exist yet.

## Images

Built + pushed to GHCR by the RoleHunter repo's `deploy-image` workflow
(on push to `main`):

- `ghcr.io/olafkfreund/rolehunter` — the app (Dockerfile `runner` target)
- `ghcr.io/olafkfreund/rolehunter-migrator` — drizzle migrations (`migrator` target)

The deployed tag is pinned in `deploy/k8s/kustomization.yaml` (`images:`) in the
RoleHunter repo. The packages are private and pulled in-cluster via the
`ghcr-pull` imagePullSecret in the `factory` namespace.

## Networking

No Ingress. A Tailscale sidecar (`ghcr.io/tailscale/tailscale`, userspace)
`tailscale serve`s HTTPS `:443` → the app on `127.0.0.1:3000`, publishing it at
**https://rolehunter.tail833f7.ts.net**. Standard factory pattern — see
[Sidecar Pattern](sidecar-pattern.md).

## Secrets

Namespace-scoped, seeded out-of-band (agenix / `manage-secrets.sh` in
`nixos_config`, or `kubectl create secret`) — never committed. Required in
`factory`:

- `rolehunter-db` — `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`
- `rolehunter-app` — `DATABASE_URL` (required) plus the optional provider keys:
  `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `JSEARCH_RAPIDAPI_KEY`,
  `ADZUNA_APP_ID` / `ADZUNA_APP_KEY`, `APIFY_API_TOKEN`, `GOOGLE_MAPS_API_KEY`
- `tailscale-auth-key` — `TS_AUTHKEY` (seeded cluster-wide at bootstrap)
- `ghcr-pull` — image pull secret (already present in `factory`)

Exact `kubectl create secret` commands:
[`deploy/k8s/README.md`](https://github.com/olafkfreund/rolehunter/blob/main/deploy/k8s/README.md).

## Data

This is a **fresh** deployment — the in-cluster Postgres starts empty and the
migrate Job creates the schema. No data is carried over from the local
docker-compose stack. The DB is a single replica on node-bound `local-path`
storage; back up the PVC if the data later matters.

## Status

Until the RoleHunter `deploy/k8s/` directory is on `main` **and** the `rolehunter-db`
/ `rolehunter-app` Secrets are seeded in `factory`, this app reports
`ComparisonError` / degraded — expected. It turns green once the manifests land,
the GHCR images are built, and the Secrets exist.
