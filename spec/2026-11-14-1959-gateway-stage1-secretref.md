---
status: approved
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
  - name: GATEWAY_UPSTREAM_URL
    value: "https://ollama.com"
  - name: GATEWAY_UPSTREAM_API_KEY
    valueFrom:
      secretKeyRef:
        name: model-gateway-secrets
        key: GATEWAY_UPSTREAM_API_KEY
        optional: true
  - name: GATEWAY_CLIENT_TOKEN
    valueFrom:
      secretKeyRef:
        name: model-gateway-secrets
        key: GATEWAY_CLIENT_TOKEN
        optional: true
```

- Block style, not the `- { name: ..., valueFrom: ... }` flow style used
  elsewhere in the repo: the literal-credential scan in `manifest-validate`
  (job `secrets`) only recognises a `name:` that ends its line followed by a
  `value:` line, so it cannot see a flow-style entry at all. In block style a
  later edit that puts a literal on either credential fails CI.

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
- Comments: the file header ("stage 0") and the comment above
  `allow-dns-egress` ("no upstream egress until stage 1 configures one") are
  reworded to say an upstream is now named and egress is still closed pending
  the owner's decision. A comment on the `env` block states the Secret is
  owner-seeded, optional, and that the Deployment must be restarted after
  seeding.

**`apps/model-gateway/application.yaml`**: the header comment says "no env, no
Secret, no provider key". Replace with: configured from the optional Secret
`model-gateway-secrets`; 503 until it is seeded; no upstream egress yet.

Nothing else: image pin, replicas, probes, PDB, NetworkPolicies and Kyverno
scope are unchanged. No Secret object is added to git.

**Effect of the merge:** the Pod template changes, so Argo rolls the two Pods
(PDB `minAvailable: 1`, default surge). Behaviour before and after is the
same: `/healthz` 200, chat 503.

### What the owner does afterwards (not in this PR)

0. **Confirm the upstream destination**: Ollama Cloud, `https://ollama.com`.
   If it should be something else, that is a one-line PR before seeding.
1. **Gateway Secret**, namespace `gateway`, name `model-gateway-secrets`,
   type Opaque, no Argo labels or annotations:
   - `GATEWAY_CLIENT_TOKEN` — new random value, e.g. `openssl rand -hex 32`.
     Callers send it as `Authorization: Bearer`.
   - `GATEWAY_UPSTREAM_API_KEY` — the Ollama Cloud API key. Use a key issued
     for the gateway, not a copy of `factory-secrets/OLLAMA_API_KEY`, so
     stage 6 can revoke the old one separately.

   Seed both this and item 2 through the same out-of-band mechanism that
   seeds `factory-secrets` (the agenix bootstrap), not only by hand, or a
   cluster rebuild loses them.
2. **Caller token**, namespace `factory`: key `MODEL_GATEWAY_CLIENT_TOKEN` in
   the existing `factory-secrets`, same value as `GATEWAY_CLIENT_TOKEN`.
   (Consumed by a later CFactory manifest PR as
   `CFACTORY_MODEL_GATEWAY_TOKEN`; nothing reads it yet.)
3. `kubectl -n gateway rollout restart deploy/model-gateway`, then check
   through `kubectl -n gateway port-forward svc/model-gateway 8080`: chat with
   no token → 401 (not 503: the token key is present and spelled right);
   chat with the token → 502 after up to 120 s while egress is still closed
   (use a client timeout above that). This proves the client token only.
4. **Egress decision**, applied by a follow-up PR that adds one more egress
   NetworkPolicy next to `allow-dns-egress`. Options:
   - **A (recommended):** TCP 443 to `0.0.0.0/0` except `10.0.0.0/8`,
     `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`.
     Rule 2 of `factory-sandbox-jobs-egress` plus the link-local and CGNAT
     ranges. Excludes the
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
5. After the egress PR syncs: one chat call with the token through the
   port-forward must return 200 with a model answer. This is the only check
   that proves `GATEWAY_UPSTREAM_API_KEY` is present, spelled right and
   valid; a provider 401 passed through means it is not.
6. Only then set `CFACTORY_MODEL_GATEWAY_URL` and
   `CFACTORY_MODEL_GATEWAY_TOKEN` on the CFactory Deployment (a later PR,
   after the CFactory image carrying the flag is deployed), and switch the
   copilot provider to `ollama` with a model Ollama Cloud serves, in
   CFactory Settings. The default provider is `claude`, which does not use
   the gateway.

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

- A misspelled key in the Secret is silent at the Kubernetes level. Step 3
  catches the client token; only step 5, after egress opens, catches the
  upstream key.
- Secret seeded, egress still closed: an authenticated call hangs until the
  gateway's 120 s upstream timeout, then 502. No service calls it then.
  "Closed" is not absolute: on this CNI a new Pod's policy rules lag its
  start by up to about a second
  (`apps/factory-namespace/manifests/networkpolicy-sandbox-jobs.yaml`, the
  measured window), and the gateway has no init gate. The gateway only
  connects out when an authenticated caller asks, so the exposure is one
  early request reaching Ollama Cloud, the intended destination.
- A wrong literal URL would send the provider key to the wrong host once
  egress opens. It is one reviewed line.
- `kubectl rollout restart` adds a Pod-template annotation Argo does not
  manage. selfHeal reverts fields the manifest declares and ignores ones it
  does not (noted in `manifest-validate.yml`, pod-hardening step), so the
  restart sticks.

## Verification

- `kustomize build apps/model-gateway/manifests | kubeconform -strict
  -ignore-missing-schemas -summary -` passes locally.
- CI `manifest-validate` green, including the `secrets` job (literal-credential
  scan: `GATEWAY_UPSTREAM_API_KEY` and `GATEWAY_CLIENT_TOKEN` use `valueFrom`)
  and the image-pin gate (untouched line). The pod-hardening ratchet does not
  list `model-gateway`; adding it is out of scope here.
- After merge, read-only: `kubectl -n gateway get pods` shows 2 Ready with 0
  restarts on the new ReplicaSet; the Argo app is Synced/Healthy; and through
  a port-forward `/healthz` is 200 and a chat POST is 503 (the Secret is
  absent, so the gateway must still refuse).
