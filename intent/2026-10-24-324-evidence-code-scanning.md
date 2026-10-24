---
status: approved
issue: 324
author: olafkfreund
---

# Intent: evidence-collector snapshots open code-scanning alerts

## Problem

The evidence-collector records CodeQL/Trivy only as "expected push" drop points.
Auditors want a daily snapshot of open code-scanning alerts per repo.

## Outcome

`collect.py` also writes `code-scanning-alerts.json` from the GitHub API.

## Constraints

- Stdlib only; best-effort (a failed fetch is recorded, never a crash).
- The collector pod holds no GitHub token today (only `cfactory-api-keys`).

## Open question

Which credential? See spec.
