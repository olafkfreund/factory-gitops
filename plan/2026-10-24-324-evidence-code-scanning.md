---
status: draft
issue: 324
spec: spec/2026-10-24-324-evidence-code-scanning.md
---

# Plan: code-scanning alert snapshot (BLOCKED on a new secret)

Approved spec decisions: dedicated read-only secret, not `factory-secrets`.

## Required secret (human action first)

Name: `evidence-github-token`, namespace `factory`, key `token`. Fine-grained
PAT, `security_events: read` and `metadata: read` on the factory repos. Create
via agenix per docs/secrets-management.md, and add a row to that doc.

## Steps (not started)

1. `apps/evidence-collector/manifests/manifests.yaml`, `collect.py`: add
   `collect_code_scanning(repos, token)` using urllib on
   `GET /repos/{r}/code-scanning/alerts?state=open&per_page=100`, writing
   `code-scanning-alerts.json` (count per repo + severity, error recorded per
   repo); skip with a recorded gap when `GITHUB_TOKEN` is unset. Add selftest
   for the summariser; update run-manifest and the HONEST SCOPE comment.
   Verify: `python3 .github/scripts/extract_embedded_script.py <manifest> collect.py /tmp/c.py && python3 /tmp/c.py selftest`.
2. Same file: `collect` env `GITHUB_TOKEN` from `evidence-github-token/token`, `optional: true`.
3. docs/evidence-collection.md and docs/secrets-management.md: document it.

Rollback: revert the PR; the secret is unused.
