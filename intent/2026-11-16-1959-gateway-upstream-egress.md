---
status: approved
issue: 1959
repo-issue: olafkfreund/Factory#1959
author: olafkfreund
---

# Intent: model-gateway upstream egress (recommended option)

## Problem

The model-gateway namespace has DNS-only egress, so even with the Secret present the gateway cannot reach its upstream (`https://ollama.com`). The owner's checklist (Factory#1959 comment, item 4) names the egress decision and recommends TCP 443 to `0.0.0.0/0` except private ranges. On 2026-11-16 the owner delegated recommended options.

## Proposed outcome

A NetworkPolicy lets only the gateway pods open TCP 443 to public addresses. The policy takes effect on sync. The gateway still answers 503 until the owner creates the Secret (no client token), so no traffic flows before then.

## Affected users and systems

Namespace `gateway`, Argo CD app `model-gateway`.

## Constraints

Must not open the Kubernetes API, the LAN, link-local or CGNAT ranges. No secret handled here. The Secret, the token and the stage 6 manifest PR stay with the owner.

## Open questions

None. Decision (owner delegation 2026-11-16): take the recommended egress. Residual: a compromised gateway can reach any public HTTPS host; a host allowlist needs an egress proxy (new component), rejected for now.
