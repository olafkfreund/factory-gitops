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

## Routes (capability classes)

The gateway rewrites a request only when its `model` is literally `local`, `cheap`, `balanced` or
`frontier`, using the flat JSON file at `GATEWAY_ROUTES_PATH` (`/etc/model-routes/routes.json`),
re-read on every request, and answers `X-Model-Route: <class>`. Any other model name, a missing class
or an unreadable file leaves the request unchanged. The file is ConfigMap `model-routes`, mounted as an
optional directory volume (no `subPath`: subPath mounts never update), so a change needs no restart.

The ConfigMap is generated, never edited by hand: `scripts/gen-model-routes.py` renders
`apps/model-gateway/manifests/model-routes.yaml` from `apis/model-catalog.json` of the Factory hub at the
SHA in `apps/model-gateway/hub-catalog.sha`, plus per-class pins in `apps/model-gateway/route-overrides.json`.
CI (`model-gateway-tools.yml`) fetches the catalog at that SHA and fails when the committed file differs.

Selection rule, per class: catalog models with provider `claude`, `price.mode` `metered` and a concrete id
(no `<placeholder>`); the lowest `in_per_mtok + out_per_mtok` wins, ties go to the larger `caps.context`,
then the id. `local` has no concrete candidate and is omitted. Subscription entries (`codex`,
`github-models`, `ollama-cloud:<model>`) are CLI-login or placeholder providers the gateway cannot serve,
and `gemini` is a CLI shorthand, not a model id. Today: `cheap=claude-haiku-4-5-20251001`,
`balanced=claude-sonnet-5`, `frontier=claude-opus-4-8`.

Residual: the only upstream is Ollama Cloud, which cannot serve Claude ids. Nothing sends a class name until
the owner enables `AIFACTORY_PHASE_ROUTES` (not set here, nor `AIFACTORY_RUNTIMES`), so traffic is unchanged.
Before enabling it, pin ids the upstream serves in `route-overrides.json` (for example
`{"cheap": "<an Ollama Cloud model id>"}`) and run the generator.

Change a route or the catalog pin:

```bash
curl -fsSL "https://raw.githubusercontent.com/olafkfreund/Factory/$(cat apps/model-gateway/hub-catalog.sha)/apis/model-catalog.json" -o /tmp/model-catalog.json
python3 scripts/gen-model-routes.py --catalog /tmp/model-catalog.json   # writes model-routes.yaml
python3 scripts/gen-model-routes.py --catalog /tmp/model-catalog.json --check
```

To take a newer catalog, write the new Factory `main` SHA into `hub-catalog.sha`, fetch that catalog, regenerate,
and commit both in one PR.

## Acceptance verifiers (read-only)

Both need `kubectl` (context `k3d-factory`, override with `KUBE_CONTEXT`) and `jq`, read workload specs only
(never a Secret), and print names, never values.

**AC-1, no provider key anywhere** (container env, mounted credential volumes, dispatched Job env):

```bash
bash scripts/verify-no-provider-keys.sh --accept-volume cli-creds   # report; always exit 0
bash scripts/verify-no-provider-keys.sh --strict --accept-volume cli-creds \
  --gateway-token-file "$d/client"                                    # fails on any finding
```

Lines are `VIOLATION|UNVERIFIED|GATEWAY-REF|ACCEPTED <workload> <container-or-volume> <name>`. A key sourced from
`factory-secrets/MODEL_GATEWAY_CLIENT_TOKEN` is `GATEWAY-REF`; a literal is `GATEWAY-REF` only when it equals the
token in `--gateway-token-file` (compared in memory), else `UNVERIFIED` or `VIOLATION`; `envFrom` is `UNVERIFIED`.
`--accept-volume` takes the volume name (`cli-creds`) and is how the accepted Plane C residual is listed
separately. The default mode reports current violations without failing while the migration is incomplete;
`--strict` is for the end state. Scope: model-provider keys only, not the gateway's own upstream key or
third-party keys (LANGCHAIN, RAPIDAPI). A missing Deployment, zero Jobs or a failed `kubectl` is a failure in
`--strict`, never a pass.

**AC-2, a route change needs no redeploy:**

```bash
bash scripts/verify-route-hot-reload.sh record /tmp/routes-before.json
# change apps/model-gateway/route-overrides.json (or the catalog pin) in a PR, regenerate, merge,
# let Argo sync. Never kubectl edit: selfHeal reverts it.
bash scripts/verify-route-hot-reload.sh check /tmp/routes-before.json 240
```

`record` stores each gateway pod's name, UID, restart count and the routes file it sees (via `kubectl exec`
of a read). `check` polls until every pod shows the same new content, equal to the live ConfigMap, then
requires the same UIDs and restart counts. It prints old and new model per class. A restart cannot fake it;
an exec failure fails. Kubelet propagation takes up to about 90 s: note the measured time on the epic.
(`X-Model-Route` is not used: it carries the class, which does not change when its model does.)

## Plane B bench test (owner-run checklist, not run by us)

Question 1: does the `claude` CLI send its requests to `ANTHROPIC_BASE_URL` while authenticating with
`CLAUDE_CODE_OAUTH_TOKEN`? Question 2: may a subscription token be used that way (terms). Do this on a bench
host, not a cluster node, with a throwaway home so no real login is touched.

```bash
# 1. throwaway home and token file (the token is typed once, never echoed, never on a command line)
export BENCH=$(mktemp -d) && export HOME=$BENCH && umask 077
claude setup-token        # interactive login; copy the token it shows
IFS= read -rsp 'token: ' t && printf %s "$t" > "$BENCH/oauth-token"; unset t; echo

# 2. a loopback listener that prints only the request line and header NAMES, never values
cat > "$BENCH/listen.py" <<'PY'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        print(self.requestline, sorted(self.headers.keys()), flush=True)
        self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers()
    do_GET = do_POST
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 9999), H).serve_forever()
PY
python3 "$BENCH/listen.py" > "$BENCH/hits.log" 2>&1 &  LISTENER=$!
sleep 1; kill -0 "$LISTENER" || echo "listener did not start (port 9999 busy?): fix this before reading any result"

# 3. point the CLI at the listener, authenticated by the token file
CLAUDE_CODE_OAUTH_TOKEN="$(cat "$BENCH/oauth-token")" ANTHROPIC_BASE_URL=http://127.0.0.1:9999 \
  timeout 90 claude -p hi; echo "exit=$?"

# 4. read the result
cat "$BENCH/hits.log"

# 5. second run with the other credential form, then read again
ANTHROPIC_AUTH_TOKEN="$(cat "$BENCH/oauth-token")" ANTHROPIC_BASE_URL=http://127.0.0.1:9999 \
  timeout 90 claude -p hi; echo "exit=$?"; cat "$BENCH/hits.log"

# 6. clean up only after both runs
kill "$LISTENER"; shred -u "$BENCH/oauth-token"
```

Reading it: a line like `POST /v1/messages ... ['authorization', ...]` (or `x-api-key`) means the base URL IS
honoured under the OAuth token, and the header names tell which credential form the CLI sends. An empty
`hits.log` with the listener confirmed running (step 2) means the CLI ignored the variable (it went to its own
endpoint), so Plane B is not possible through a gateway and the epic records that; an empty log with a listener
that failed to start is inconclusive. Step 5 repeats with `ANTHROPIC_AUTH_TOKEN` instead of `CLAUDE_CODE_OAUTH_TOKEN`:
note whether behaviour differs. Then revoke the token (`claude` account settings) and delete `$BENCH`.

Terms (cannot be decided from code): read Anthropic's current Consumer Terms, Commercial Terms and the Claude Code
legal and compliance page, and answer in writing whether a subscription OAuth token may be sent through a
self-hosted proxy used by automation. Post the answer, the CLI version (`claude --version`) and the date as a comment on
Factory#1959. If the answer is no, Plane B stays closed and the epic keeps the subscription logins mounted.

## Not done yet

- The owner steps above (Secret, keys, proof, switch-on), the Plane B bench test, pinning upstream-servable
  ids in `route-overrides.json`, and enabling `AIFACTORY_PHASE_ROUTES` after the Secret exists.
- Epic stages 3 to 6: routes in the contract, AIFactory and PFactory through the gateway, Plane B, and
  revoking and rotating the old provider keys at the provider (removing them from a Deployment does not
  invalidate them).
