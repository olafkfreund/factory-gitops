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
- Owner steps after merge (not in this PR; they go in the PR body verbatim):
  0. Confirm the upstream destination, Ollama Cloud (`https://ollama.com`).
  1. Secret `model-gateway-secrets` in namespace `gateway`, type Opaque, with
     no Argo labels or annotations (the app prunes what it tracks). Keys:
     `GATEWAY_CLIENT_TOKEN` (new random value, e.g. `openssl rand -hex 32`)
     and `GATEWAY_UPSTREAM_API_KEY` (an Ollama Cloud key issued for the
     gateway, not a copy of `factory-secrets/OLLAMA_API_KEY`, so the old key
     can be revoked separately later).
  2. Key `MODEL_GATEWAY_CLIENT_TOKEN` in `factory/factory-secrets`, same
     value as `GATEWAY_CLIENT_TOKEN`.
     Seed 1 and 2 through the agenix bootstrap that seeds `factory-secrets`,
     or a cluster rebuild loses them.
  3. `kubectl -n gateway rollout restart deploy/model-gateway`; wait for the
     rollout and another 30 s (NetworkPolicy rules lag a new Pod by seconds
     on this CNI). Then through
     `kubectl -n gateway port-forward svc/model-gateway 8080`:
     `POST /v1/chat/completions` with no token → 401; with the token → 502
     after up to 120 s (client timeout above that). Proves the client token
     only.
  4. Egress decision. Recommended: one more NetworkPolicy allowing TCP 443 to
     `0.0.0.0/0` except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
     `169.254.0.0/16`, `100.64.0.0/10`. Alternatives: pinned provider ranges
     (none published; breaks when they change) or an egress proxy with a host
     allowlist (new component). Applied by a follow-up PR.
  5. After that PR syncs: one authenticated `POST /v1/chat/completions`
     through the port-forward returns 200 with a model answer. The only proof
     of `GATEWAY_UPSTREAM_API_KEY`.
  6. Then, once a CFactory image with the flag is deployed: a manifest PR
     setting `CFACTORY_MODEL_GATEWAY_URL` and `CFACTORY_MODEL_GATEWAY_TOKEN`
     (from `MODEL_GATEWAY_CLIENT_TOKEN`), and in CFactory Settings switch the
     copilot provider to `ollama` with a model Ollama Cloud serves. The
     default provider, `claude`, does not use the gateway.

The implementer never stages, commits, pushes or switches branches, and runs
no `kubectl` command.

## Steps

1. Edit the two files.
   - `apps/model-gateway/manifests/manifests.yaml`:
     - l.1 header becomes exactly:
       `# Model gateway stage 1 (Factory#1959) — Deployment (configured from an optional Secret), Service, PDB, NetworkPolicies.`
     - container `model-gateway`: insert the `env` block above, between the
       `ports:` entry (l.33-35) and `readinessProbe:` (l.36), with a comment above it of at most six
       lines: owner-seeded Secret `model-gateway-secrets` in this namespace,
       never in git; `optional` so a missing Secret leaves the gateway
       refusing chat (503) instead of stalling the rollout; restart the
       Deployment after seeding or rotating; block style is deliberate (the
       `secrets` CI scan does not see flow style); the URL is a literal so a
       Secret edit cannot redirect the provider key.
     - comment above `allow-dns-egress` (l.115, currently "DNS only: no upstream
       egress until stage 1 configures one."): → "DNS only: an upstream is
       named but not reachable. Upstream egress is an owner decision
       (Factory#1959); it is added as its own policy by a later PR."
   - `apps/model-gateway/application.yaml`, header comment l.1-3 (both
     sentences, up to the empty `#` line) becomes exactly:

     ```
     # Model gateway, stage 1 (Factory#1959) — configured from the optional Secret
     # `model-gateway-secrets` (owner-seeded, not in git). It serves /healthz and
     # answers chat requests 503 until that Secret exists; it has no upstream
     # egress yet.
     ```

     Leave the rest of the header (own Application and namespace, Kyverno
     scope) as is.
   - Verify:
     `kustomize build apps/model-gateway/manifests | kubeconform -strict -ignore-missing-schemas -summary -`
     (`kubeconform` is not installed on this host: run `kustomize build` alone
     and say so; CI runs the schema check),
     `python -c "import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" apps/model-gateway/application.yaml apps/model-gateway/manifests/manifests.yaml`,
     and `git diff --stat` shows only those two files.
   - Traps: do not touch the `image:` line or its comment (image-pin gate,
     and CD rewrites the tag). Indentation of `env` must match `ports`. No
     trailing whitespace. Do not add a `Secret`, a `Namespace` or a new
     NetworkPolicy.

## Tests

- Local `kustomize build | kubeconform` as above.
- Run the `secrets` job's awk scan from `.github/workflows/manifest-validate.yml`
  locally, passing the edited manifest to `awk` directly: no hit. Then prove
  it can fail: on a copy outside the repo, replace one `valueFrom` block with
  `value: "x"`, pass that file to the same `awk`, and see it reported.
- CI `manifest-validate` (jobs `validate` and `secrets`) green on the PR.
- After merge, read-only by the lead: Argo app `model-gateway`
  Synced/Healthy; 2 Pods Ready, 0 restarts, on a new ReplicaSet; through
  `kubectl -n gateway port-forward` `GET /healthz` is 200 and
  `POST /v1/chat/completions` is 503.

## Rollback

Revert the PR; Argo rolls the Deployment back to the env-less template. If a
Pod fails to become Ready after the merge, revert first, investigate after.
