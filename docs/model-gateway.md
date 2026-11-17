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

Order matters: the client token before the URL. A client with a URL and no token fails closed.

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
# 3. restart the gateway, then prove the contract through a port-forward
kubectl -n gateway rollout restart deploy/model-gateway
kubectl -n gateway rollout status deploy/model-gateway && sleep 30
kubectl -n gateway port-forward svc/model-gateway 8080 &   # stop it when done
# healthz 200, chat without the token 401, chat with the token 200 (the 200 needs the egress
# policy synced and spends one upstream token). Run it BEFORE the token files are removed.
GATEWAY_PROBE_MODEL=<a model your Ollama Cloud key serves> \
  scripts/verify-model-gateway.sh http://127.0.0.1:8080 "$d/client"
# 4. remove the token files
shred -u "$d"/*; rmdir "$d"
# 5. switch the clients on: seed MODEL_GATEWAY_URL in factory/factory-secrets
#    (http://model-gateway.gateway.svc.cluster.local:8080, no /v1) through the agenix bootstrap, then
#    restart one service at a time (env from a Secret is read at container start):
kubectl -n factory rollout restart deploy/cfactory && kubectl -n factory rollout status deploy/cfactory
kubectl -n factory rollout restart deploy/tfactory && kubectl -n factory rollout status deploy/tfactory
kubectl -n factory rollout restart deploy/aifactory && kubectl -n factory rollout status deploy/aifactory
# CFactory only routes the `ollama`, `openai` and `openai_compatible` copilot providers: also switch
# the copilot provider to `ollama` in CFactory Settings. Then the epic's stage 1 checkpoint: remove
# OLLAMA_API_KEY from CFactory and confirm chat still works.
```

`apps/{cfactory,tfactory,aifactory}/manifests` carry `<SVC>_MODEL_GATEWAY_URL` and
`<SVC>_MODEL_GATEWAY_TOKEN` as `optional` references to the `factory-secrets` keys
`MODEL_GATEWAY_URL` and `MODEL_GATEWAY_CLIENT_TOKEN`, and the Job egress policy admits the gateway
pods on 8080, so nothing changes until step 5. The images that run today carry the client code
(CFactory#513, TFactory#1520, AIFactory#2070); CFactory has no release tags, `main` is the release.
The Secret `model-gateway-secrets` carries no Argo labels or annotations. Both of its keys are
`optional` in the Deployment, so nothing changes before they exist.

## Plane B bench test (owner)

Does the `claude` CLI honour `ANTHROPIC_BASE_URL` while authenticating with
`CLAUDE_CODE_OAUTH_TOKEN`? Run `ANTHROPIC_BASE_URL=http://127.0.0.1:9 claude -p hi` on a bench
host with a throwaway logged-in profile and watch for a connection attempt to port 9. A hit means
the base URL is honoured. Also check the provider's terms for proxying subscription auth.

## Not done yet

- The owner steps above (Secret, keys, proof, switch-on) and the Plane B bench test.
- Epic stages 3 to 6: routes in the contract, AIFactory and PFactory through the gateway, Plane B, and
  revoking and rotating the old provider keys at the provider (removing them from a Deployment does not
  invalidate them).
