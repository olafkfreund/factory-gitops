---
status: draft
issue: 1959
repo-issue: olafkfreund/Factory#1959
intent: intent/2026-11-14-1959-gateway-stage1-secretref.md
---

# Spec: model gateway reads its configuration from a Secret that does not exist yet

## Design

One PR, two files.

**`apps/model-gateway/manifests/manifests.yaml`**, container `model-gateway`,
add `env`:

```yaml
env:
  - { name: GATEWAY_UPSTREAM_URL, value: "https://ollama.com" }
  - { name: GATEWAY_UPSTREAM_API_KEY, valueFrom: { secretKeyRef: { name: model-gateway-secrets, key: GATEWAY_UPSTREAM_API_KEY, optional: true } } }
  - { name: GATEWAY_CLIENT_TOKEN, valueFrom: { secretKeyRef: { name: model-gateway-secrets, key: GATEWAY_CLIENT_TOKEN, optional: true } } }
```

- The gateway appends `/v1/chat/completions` to the upstream URL
  (AIFactory `apps/model-gateway/gateway.py`), so the value is the origin,
  not `https://ollama.com/v1`.
- The URL is a literal in the public manifest on purpose: it is not a secret,
  and whoever can write the Secret then cannot redirect the provider key to
  another host. Changing the destination is a reviewed PR.
- `optional: true` on both references: with no Secret the two variables are
  simply unset, the gateway has a URL and no client token, and it keeps
  answering chat 503 (`if not (config.upstream_url and config.client_token)`).
  Without `optional`, the new Pods would sit in `CreateContainerConfigError`
  and the Argo app would stay Progressing until the owner acts.
- `secretKeyRef` per key, not `envFrom`.
- The comment above `allow-dns-egress` and the file header stay true and are
  not edited; a comment on the `env` block states the Secret is owner-seeded,
  optional, and that the Deployment must be restarted after seeding.

**`apps/model-gateway/application.yaml`**: the header comment says "no env, no
Secret, no provider key". Replace with: configured from the optional Secret
`model-gateway-secrets`; 503 until it is seeded; no upstream egress yet.

Nothing else: image pin, replicas, probes, PDB, NetworkPolicies and Kyverno
scope are unchanged. No Secret object is added to git.

**Effect of the merge:** the Pod template changes, so Argo rolls the two Pods
(PDB `minAvailable: 1`, default surge). Behaviour before and after is the
same: `/healthz` 200, chat 503.

### What the owner does afterwards (not in this PR)

1. **Gateway Secret**, namespace `gateway`, name `model-gateway-secrets`,
   type Opaque, no Argo labels or annotations:
   - `GATEWAY_CLIENT_TOKEN` — new random value, e.g. `openssl rand -hex 32`.
     Callers send it as `Authorization: Bearer`.
   - `GATEWAY_UPSTREAM_API_KEY` — the Ollama Cloud API key. Use a key issued
     for the gateway, not a copy of `factory-secrets/OLLAMA_API_KEY`, so
     stage 6 can revoke the old one separately.
2. **Caller token**, namespace `factory`: key `MODEL_GATEWAY_CLIENT_TOKEN` in
   the existing `factory-secrets`, same value as `GATEWAY_CLIENT_TOKEN`.
   (Consumed by a later CFactory manifest PR as
   `CFACTORY_MODEL_GATEWAY_TOKEN`; nothing reads it yet.)
3. `kubectl -n gateway rollout restart deploy/model-gateway`, then check:
   chat with no token → 401 (not 503: the token key is present and spelled
   right); chat with the token → 502 while egress is still closed.
4. **Egress decision**, applied by a follow-up PR to `allow-dns-egress`'s
   sibling policy. Options:
   - **A (recommended):** TCP 443 to `0.0.0.0/0` except `10.0.0.0/8`,
     `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`.
     Same shape as rule 2 of `factory-sandbox-jobs-egress`. Excludes the
     Kubernetes API (10.43.0.1), cluster Services and Pods, the docker bridge
     and the LAN. Residual: a compromised gateway can reach any public HTTPS
     host. Mitigations already in place: the destination is a manifest
     literal, the gateway refuses redirects, and the image is signature-
     verified at admission.
   - **B:** pin Ollama Cloud's address ranges. Narrowest, but the provider
     publishes none and its addresses change; every change is an outage.
   - **C:** an egress proxy with a host allowlist. The right long-term answer
     if more upstreams are added; a new component to build, sign and run now.
   - Plain `0.0.0.0/0:443` with no exceptions is not offered: it opens the
     Kubernetes API and the LAN.
5. Only then set `CFACTORY_MODEL_GATEWAY_URL` and
   `CFACTORY_MODEL_GATEWAY_TOKEN` on the CFactory Deployment (a later PR,
   after the CFactory image carrying the flag is deployed).

## Alternatives rejected

- **Required (non-optional) references**: stalls the rollout until the owner
  seeds the Secret; a merge today would leave the app Progressing.
- **Upstream URL in the Secret**: keeps the manifest free of a provider
  choice, but lets a Secret edit move the provider key to any host, and hides
  the destination from review.
- **`envFrom`**: any key in the Secret becomes an environment variable.
- **Reuse `factory-secrets`**: wrong namespace, and the gateway's trust
  boundary would share a Secret with the services it is meant to isolate keys
  from.
- **A SealedSecret or ExternalSecret in git**: the cluster has neither
  controller; secrets are seeded by the agenix bootstrap.
- **Add the egress rule now**: owner decision, and an open rule with no
  configured caller is attack surface.

## Risks

- A misspelled key in the Secret is silent at the Kubernetes level. Step 3's
  401/502 check catches both keys' spelling (a missing upstream key shows up
  only once egress is open, as a provider 401 passed through).
- Secret seeded, egress still closed: an authenticated call hangs until the
  gateway's 120 s upstream timeout, then 502. No service calls it then.
- A wrong literal URL would send the provider key to the wrong host once
  egress opens. It is one reviewed line.
- `kubectl rollout restart` adds a Pod-template annotation Argo does not
  manage. Not verified whether selfHeal reverts it here; the fleet's other
  apps are restarted this way.

## Verification

- `kustomize build apps/model-gateway/manifests | kubeconform -strict
  -ignore-missing-schemas -summary -` passes locally.
- CI `manifest-validate` green, including the `secrets` job (literal-credential
  scan: `GATEWAY_UPSTREAM_API_KEY` and `GATEWAY_CLIENT_TOKEN` use `valueFrom`)
  and the image-pin and pod-hardening gates (untouched lines).
- After merge, read-only: `kubectl -n gateway get pods` shows 2 Ready with 0
  restarts on the new ReplicaSet; the Argo app is Synced/Healthy.
