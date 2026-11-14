---
status: draft
issue: 1959
repo-issue: olafkfreund/Factory#1959
author: olafkfreund
---

# Intent: model gateway reads its configuration from a Secret that does not exist yet

## Problem

The model gateway (Factory#1959) runs in namespace `gateway` with no env and
no Secret, so it answers every chat request 503
(`plan/2026-10-27-1959-gateway-stage0.md`). Stage 1 needs it configured with
an upstream, an upstream key and a client token. Two things are the owner's
and still open: seeding the Secret, and whether the gateway's egress may be
`0.0.0.0/0:443`.

Today, after the owner seeds a Secret, a second manifest PR is still needed
before anything reads it. The manifests can reference the Secret now, safely,
so that seeding it is the only step left on the configuration side.

## Proposed outcome

- The gateway Deployment names its upstream URL and reads the upstream key
  and client token from a Secret in `gateway`, referenced as optional.
- While the Secret is absent the gateway is exactly as today: Pods Ready,
  `/healthz` 200, chat 503.
- Once the owner creates the Secret and restarts the Deployment, the gateway
  authenticates callers. It still cannot reach an upstream until the egress
  decision is made and applied.
- The exact Secret name and keys, and the egress options with a
  recommendation, are written down for the owner.

## Affected users and systems

- `apps/model-gateway/manifests/manifests.yaml` (Argo app `model-gateway`,
  namespace `gateway`, cluster on p620).
- No other app. The CFactory Deployment is not changed: its flag stays off
  (CFactory slug `2026-11-14-1959-copilot-gateway-flag`).

## Constraints

- factory-gitops is public: no secret value, only names and keys.
- No `kubectl` write and no Secret write by the agent. Argo applies the
  manifest after merge.
- The rollout must not be able to stall or take the gateway down while the
  Secret is missing.
- No egress change: that is the owner's decision. Egress stays DNS-only.
- Image pin and Kyverno scope are untouched.

## Open questions

For the owner, tracked on Factory#1959, not blocking this change:

1. Seed the gateway Secret (name and keys in the spec).
2. Egress: `0.0.0.0/0:443`, or something narrower.
