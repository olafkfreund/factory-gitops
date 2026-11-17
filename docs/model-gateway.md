# Model gateway (Factory#1959)

`apps/model-gateway` is the first-party gateway in namespace `gateway`: callers hold a gateway
token, only the gateway holds the upstream provider key. Image signatures are verified by the
`gateway` Kyverno rules.

## Decisions (owner delegation 2026-11-16)

- **Upstream:** Ollama Cloud, `https://ollama.com` (the value already in the Deployment).
- **Egress:** TCP 443 to any public address, minus the private, link-local and CGNAT ranges
  (`allow-provider-egress`). A NetworkPolicy cannot match host names. Residual risk: a compromised
  gateway can reach any public HTTPS host. Narrower options (pinned provider ranges, an egress
  proxy with a host allowlist) need a new component or break when ranges change.
- **Plane C** (`codex-auth.json`, `copilot-apps.json`, `gemini-oauth_creds.json`: CLI login files
  with no base-URL override) is accepted and documented as a residual: the gateway cannot front
  them, so those logins stay mounted. Revisit if the upstream CLIs gain proxy support.
- **Plane B** (Anthropic-shaped, `ANTHROPIC_BASE_URL` with `CLAUDE_CODE_OAUTH_TOKEN`) stays blocked
  until the owner's bench test below answers it.

## Owner steps (no secret value is ever passed on a command line or printed)

```bash
# 1. two new random values; the client token is shared with factory-secrets
umask 077; d=$(mktemp -d /dev/shm/gw.XXXXXX)
openssl rand -hex 32 | tr -d '\n' > "$d/client"
# put the Ollama Cloud key issued FOR THE GATEWAY (not a copy of OLLAMA_API_KEY) in $d/upstream,
# then strip the newline: the gateway compares both values verbatim, so a trailing newline
# makes every client call fail with 401
$EDITOR "$d/upstream"; tr -d '\n' < "$d/upstream" > "$d/upstream.n"; mv "$d/upstream.n" "$d/upstream"
kubectl -n gateway create secret generic model-gateway-secrets \
  --from-file=GATEWAY_CLIENT_TOKEN="$d/client" --from-file=GATEWAY_UPSTREAM_API_KEY="$d/upstream"
# 2. the same client token as MODEL_GATEWAY_CLIENT_TOKEN in factory/factory-secrets,
#    through the agenix bootstrap (a cluster rebuild loses anything seeded only by kubectl)
# 3. restart and prove the client token only
kubectl -n gateway rollout restart deploy/model-gateway
kubectl -n gateway rollout status deploy/model-gateway && sleep 30
# via kubectl -n gateway port-forward svc/model-gateway 8080: chat without the token -> 401
# 4. after this repo's egress policy has synced: one authenticated chat call returns 200
shred -u "$d"/*; rmdir "$d"
```

The Secret carries no Argo labels or annotations. Both keys are `optional` in the Deployment, so
nothing changes before they exist.

## Plane B bench test (owner)

Does the `claude` CLI honour `ANTHROPIC_BASE_URL` while authenticating with
`CLAUDE_CODE_OAUTH_TOKEN`? Run `ANTHROPIC_BASE_URL=http://127.0.0.1:9 claude -p hi` on a bench
host with a throwaway logged-in profile and watch for a connection attempt to port 9. A hit means
the base URL is honoured. Also check the provider's terms for proxying subscription auth.

## Not done yet

- A CFactory release carrying CFactory#513, then a manifest PR setting `CFACTORY_MODEL_GATEWAY_URL`
  and `CFACTORY_MODEL_GATEWAY_TOKEN` (the live image is `cfactory:0.1.0`; no release exists).
- TFactory Job wiring (TFactory#1520) and AIFactory builds (AIFactory gateway PR): manifest PRs once released.
- Revoking and rotating the old provider keys at the provider (removing them from a Deployment does not invalidate them).
