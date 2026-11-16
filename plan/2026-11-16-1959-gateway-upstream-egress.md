---
status: draft
issue: 1959
repo-issue: olafkfreund/Factory#1959
spec: spec/2026-11-16-1959-gateway-upstream-egress.md
coders:
  1: coder   # one manifest edit
reviewers:
  - codex
---

# Plan: model-gateway upstream egress

Decisions from the spec: one new NetworkPolicy, TCP 443 to `0.0.0.0/0` except the five private/link-local/CGNAT ranges; DNS policy and Secret untouched; active on sync, traffic only after the owner creates the Secret (503 until then).

## Steps

1. `apps/model-gateway/manifests/manifests.yaml` after `allow-dns-egress` (~line 160): add `allow-upstream-egress`; reword the comment at ~135 → verify by the repo's manifest CI jobs and `git diff`.
   Traps: no Argo labels on Secrets (not touched); keep `podSelector` on `app: model-gateway`.

## Tests

Repo CI (manifest validation). After merge: `kubectl get netpol -n gateway` (read-only).

## Rollback

Revert the commit; Argo prunes the policy and egress returns to DNS only.
