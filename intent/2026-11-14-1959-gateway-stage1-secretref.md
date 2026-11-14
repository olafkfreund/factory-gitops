---
status: approved
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
which removes that PR from the path. What stays with the owner afterwards is
listed under Open questions.

## Proposed outcome

- The gateway Deployment names its upstream URL and reads the upstream key
  and client token from a Secret in `gateway`, each key referenced by name
  and as optional. The upstream is Ollama Cloud (`https://ollama.com`), the
  destination CFactory's copilot already calls directly today; the epic's
  stage 1 moves that call behind the gateway.
- While the Secret is absent the gateway is exactly as today: Pods Ready,
  `/healthz` 200, chat 503.
- Once the owner creates the Secret and restarts the Deployment, the gateway
  authenticates callers. It still cannot reach an upstream until the egress
  decision is made and applied in a further manifest PR; until then an
  authenticated chat call waits for the upstream timeout and fails with 502.
  No service calls the gateway in that window.
- The exact Secret name and keys, and the egress options with a
  recommendation, are written down for the owner.

## Affected users and systems

- `apps/model-gateway/manifests/manifests.yaml` (Argo app `model-gateway`,
  namespace `gateway`, cluster on p620).
- No other app. The CFactory Deployment is not changed. CFactory has no
  gateway setting on `dev` yet; one is being added, default off, under the
  CFactory slug `2026-11-14-1959-copilot-gateway-flag`. Its status probe
  will use `/healthz`, because the gateway has no `/v1/models`.

## Constraints

- factory-gitops is public: no secret value, only names and keys.
- No `kubectl` write and no Secret write by the agent. Argo applies the
  manifest after merge.
- The rollout must not be able to stall or take the gateway down while the
  Secret is missing.
- No egress change: that is the owner's decision. Egress stays DNS-only.
- Individual `secretKeyRef` entries, never `envFrom`: a Secret key must not
  be able to set an arbitrary environment variable or override the upstream.
- An optional reference also hides a missing or misspelled key: the Pod
  starts and the gateway stays 503 (no client token) or calls the upstream
  with no key (no upstream key). The owner steps must include a check.
- CI `manifest-validate` must stay green; the stage 0 comment in
  `apps/model-gateway/application.yaml` must stop saying "no env, no Secret".
- Image pin and Kyverno scope are untouched.

## Open questions

For the owner, tracked on Factory#1959, not blocking this change:

1. Seed the gateway Secret (name and keys in the spec), without Argo
   tracking labels or annotations (the app prunes), then restart the
   Deployment: env from a Secret is read at start only.
2. Seed the same client token in namespace `factory` for CFactory; a
   `secretKeyRef` cannot cross namespaces.
3. Confirm the upstream destination, Ollama Cloud.
4. Egress. A NetworkPolicy here matches IP ranges, not host names, so the
   choices are TCP 443 to `0.0.0.0/0` minus the private, link-local and
   cluster ranges, a pinned provider range that breaks when the provider's
   addresses change, or an egress proxy. Plain `0.0.0.0/0:443` with no
   exceptions would also open the Kubernetes API and the LAN.
