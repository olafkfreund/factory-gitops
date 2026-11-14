---
status: draft
issue: 1959
repo-issue: olafkfreund/Factory#1959
spec: spec/2026-11-14-1959-gateway-stage1-secretref.md
coders:
  1: coder   # one small manifest edit; nothing mechanical or tricky enough for agy or codex
reviewers:
  - codex    # independent read of the manifest against the CI gates
  - agy      # second independent read; found the scanner blind spot at spec review
---

# Plan: model gateway reads its configuration from a Secret that does not exist yet

## Approved decisions (from the spec)

- One PR, two files: `apps/model-gateway/manifests/manifests.yaml` and
  `apps/model-gateway/application.yaml`.
- Container `model-gateway` gets exactly this `env`, in block style (the
  `secrets` CI scan cannot see flow-style entries):

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

- The URL is the origin (the gateway appends `/v1/chat/completions`), a
  literal on purpose. `optional: true` so the rollout cannot stall while the
  Secret is absent; the gateway then has no client token and keeps answering
  chat 503. `secretKeyRef` per key, never `envFrom`.
- No Secret object in git. No egress change: `allow-dns-egress` stays the
  only egress policy. Image, replicas, probes, resources, securityContext,
  Service, PDB and Kyverno scope are untouched.
- Comments are brought up to date: an upstream is named, the Secret is
  owner-seeded and optional, the Deployment must be restarted after seeding,
  egress is still closed pending the owner's decision.
- Owner steps after merge (not in this PR; listed in the spec and the PR
  body): confirm the destination; seed `gateway/model-gateway-secrets`
  (`GATEWAY_CLIENT_TOKEN`, `GATEWAY_UPSTREAM_API_KEY`) and
  `factory/factory-secrets` key `MODEL_GATEWAY_CLIENT_TOKEN`; restart and
  check 401/502; decide egress (recommended: TCP 443 to `0.0.0.0/0` except
  `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`,
  `100.64.0.0/10`); after egress, one authenticated chat must return 200;
  then enable the CFactory flag.

The implementer never stages, commits, pushes or switches branches, and runs
no `kubectl` command.

## Steps

1. Edit the two files.
   - `apps/model-gateway/manifests/manifests.yaml`:
     - l.1 header: "stage 0" → "stage 1 (Factory#1959): configured from an
       optional Secret" (keep it one line).
     - container `model-gateway`: insert the `env` block above, between
       `ports:` and `readinessProbe:`, with a comment above it of at most six
       lines: owner-seeded Secret `model-gateway-secrets` in this namespace,
       never in git; `optional` so a missing Secret leaves the gateway
       refusing chat (503) instead of stalling the rollout; restart the
       Deployment after seeding or rotating; block style is deliberate (the
       `secrets` CI scan does not see flow style); the URL is a literal so a
       Secret edit cannot redirect the provider key.
     - comment above `allow-dns-egress` (currently "DNS only: no upstream
       egress until stage 1 configures one."): → "DNS only: an upstream is
       named but not reachable. Upstream egress is an owner decision
       (Factory#1959); it is added as its own policy by a later PR."
   - `apps/model-gateway/application.yaml`, header comment l.1-3: replace the
     "unconfigured: no env, no Secret, no provider key" sentence with: stage
     1, configured from the optional Secret `model-gateway-secrets` (not in
     git); chat answers 503 until the owner seeds it; no upstream egress yet.
     Leave the rest of the header (own Application and namespace, Kyverno
     scope) as is.
   - Verify:
     `kustomize build apps/model-gateway/manifests | kubeconform -strict -ignore-missing-schemas -summary -`
     (if the tools are missing, say so; CI runs it), and
     `git diff --stat` shows only those two files.
   - Traps: do not touch the `image:` line or its comment (image-pin gate,
     and CD rewrites the tag). Indentation of `env` must match `ports`. No
     trailing whitespace. Do not add a `Secret`, a `Namespace` or a new
     NetworkPolicy.

## Tests

- Local `kustomize build | kubeconform` as above.
- Run the `secrets` job's awk scan from `.github/workflows/manifest-validate.yml`
  locally against the edited manifest: no hit. Then prove it can fail: on a
  scratch copy, replace one `valueFrom` block with `value: "x"` and see the
  scan report it.
- CI `manifest-validate` (jobs `validate` and `secrets`) green on the PR.
- After merge, read-only by the lead: Argo app `model-gateway`
  Synced/Healthy; 2 Pods Ready, 0 restarts, on a new ReplicaSet; through
  `kubectl -n gateway port-forward` `/healthz` is 200 and a chat POST is 503.

## Rollback

Revert the PR; Argo rolls the Deployment back to the env-less template. If a
Pod fails to become Ready after the merge, revert first, investigate after.
