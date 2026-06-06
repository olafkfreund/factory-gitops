# SkillAI deployment

SkillAI is an internal AI-powered recruiting portal (Next.js 16 + PostgreSQL 17 /
pgvector + Claude). It runs in the `factory` namespace on the p510 k3d cluster,
reconciled by ArgoCD from
[`github.com/olafkfreund/SkillAi`](https://github.com/olafkfreund/SkillAi) — the
Kubernetes manifests live in that repo under `deploy/k8s/` (kustomize), and
`apps/skillai/application.yaml` here points ArgoCD at them.

## App-of-Apps wiring

| Field | Value |
| --- | --- |
| `source.repoURL` | `https://github.com/olafkfreund/SkillAi` |
| `source.path` | `deploy/k8s` |
| `source.targetRevision` | `core-mvp-foundation` (SkillAi's default branch — **not** `main`) |
| `destination.namespace` | `factory` |
| `syncPolicy` | automated, `prune: true`, `selfHeal: true`, `CreateNamespace=true` |

The root app discovers `apps/skillai/application.yaml` automatically; commit +
push and ArgoCD reconciles in ~3 min.

## What it deploys

| Object | Kind | Sync wave | Notes |
| --- | --- | --- | --- |
| `skillai-db` | StatefulSet + headless Service | 0 | `pgvector/pgvector:pg17`, 8Gi `local-path` PVC |
| `skillai-migrate` | Job (ArgoCD `Sync` hook) | 1 | Drizzle migrations; re-runs each sync; waits for the DB |
| `skillai-app` | Deployment + Service | 2 | Next.js standalone + Tailscale sidecar; 5Gi uploads PVC |

Sync waves enforce DB → migrations → app ordering on a fresh cluster. The
migration is a `Sync`-phase hook (not `PreSync`) so it runs after the DB is
healthy instead of deadlocking on a DB that doesn't exist yet.

## Images

Built + pushed to GHCR by the SkillAi repo's `deploy-image` workflow:

- `ghcr.io/olafkfreund/skillai` — the app (Dockerfile `runner` target)
- `ghcr.io/olafkfreund/skillai-migrator` — drizzle migrations (`migrator` target)

The deployed tag is pinned in `deploy/k8s/kustomization.yaml` (`images:`) in the
SkillAi repo. The GHCR packages must be public (or add an imagePullSecret).

## Networking

No Ingress. A Tailscale sidecar (`ghcr.io/tailscale/tailscale`, userspace)
`tailscale serve`s HTTPS `:443` → the app on `127.0.0.1:3000`, publishing it at
**https://skillai.tail833f7.ts.net**. Standard factory pattern — see
[Sidecar Pattern](sidecar-pattern.md).

## Secrets

Namespace-scoped, seeded out-of-band (agenix / `manage-secrets.sh` in
`nixos_config`) — never committed. Required in `factory`:

- `skillai-db` — `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`
- `skillai-app` — `DATABASE_URL`, `NEXTAUTH_SECRET`, `ANTHROPIC_API_KEY`, `ENCRYPTION_KEY`, `BRAVE_SEARCH_API_KEY`, `GITHUB_TOKEN`
- `tailscale-auth-key` — `TS_AUTHKEY` (often seeded cluster-wide at bootstrap)

## Data migration & restore

The live data starts in a docker-compose stack on **p620**. Back it up, copy to
p510, and restore the DB dump + uploads tarball into the in-cluster volumes. The
step-by-step runbook (with verification + rollback) lives in the SkillAi repo at
[`deploy/migration/RUNBOOK.md`](https://github.com/olafkfreund/SkillAi/blob/core-mvp-foundation/deploy/migration/RUNBOOK.md).

## Status

Until the SkillAi `deploy/k8s/` PR merges to `core-mvp-foundation`, this app
reports `ComparisonError` on the missing path — expected, same as the other
placeholder apps. It turns green once the manifests land and the Secrets are
seeded.
