---
status: approved
issue: 324
intent: intent/2026-10-24-324-evidence-code-scanning.md
---

# Spec: code-scanning alert snapshot

## Finding

The `collect` init container has no GitHub token in env or mounted secret.
`factory-secrets/GITHUB_TOKEN` exists (docs say `repo` scope) but is the
catch-all, highest-blast-radius secret, and the collector's RBAC/security model
is "no secrets". Whether it has `security_events` read is not verifiable here.

## Decision

Do not mount `factory-secrets`. Add a dedicated read-only secret
`evidence-github-token` (key `token`), a fine-grained PAT with
`security_events: read` + `metadata: read` on the factory repos only, wired
into `collect` as optional `GITHUB_TOKEN` env. Needs a human to create it.

## Alternatives rejected

- Reuse `factory-secrets` `GITHUB_TOKEN`: widens blast radius, scope unverified.
- Push from GitHub Actions CI: separate pipeline, not asked.

## Verification

Selftest for the alert-summarising function; run `collect.py` with the token.
