# observe — OpenObserve OTLP backend for the Factory program

Single-binary [OpenObserve](https://openobserve.ai) (OTLP-native, local Parquet +
SQLite) that serves as the bundled telemetry backend for the Factory program. It
is the sink for AIFactory's per-worker OpenTelemetry spans + metrics
(`OTEL_EXPORTER_OTLP_ENDPOINT`) and the backend the CFactory cockpit links to.

Implements P2 of the per-worker observability design
(`docs/plans/2026-06-13-per-worker-observability-design.md` in the Factory spec repo):
"instrument + ship dashboards-as-code; operator runs the OTLP backend".

## What this deploys

In namespace `factory`, all labelled `app: observe`:

- **Deployment** `observe` — `public.ecr.aws/zinclabs/openobserve:v0.90.3`
  (pinned), single replica, `Recreate` strategy, requests 256Mi / limits 1Gi.
- **Service** `observe` — `:5080` (HTTP UI + OTLP/HTTP ingest) and `:5081`
  (OTLP/gRPC ingest).
- **PVC** `observe-data` (5Gi, `local-path`) mounted at `/data` (`ZO_DATA_DIR`).

It is fully isolated: it does not modify any other app's manifests, CFactory's
ingress, or the shared cloudflared route table.

## 1. Secret the operator MUST create (before/at first sync)

Credentials are never inlined in git. Create the bootstrap root user secret
out-of-band (same convention as `oauth2-proxy-cfactory` and `cloudflared-factory`):

```bash
kubectl -n factory create secret generic observe-root \
  --from-literal=email='admin@freundcloud.org.uk' \
  --from-literal=password='<a-strong-password>'
```

Password policy: 8–128 chars, with at least one lowercase, one uppercase, one
digit, and one special character. The Deployment reads `email` -> `ZO_ROOT_USER_EMAIL`
and `password` -> `ZO_ROOT_USER_PASSWORD`. Without this Secret the pod will not
start (the env refs are required).

## 2. OTLP endpoint to put in OTEL_EXPORTER_OTLP_ENDPOINT

In-cluster (AIFactory pods talking to the backend directly — recommended):

- **OTLP/HTTP** (the OTLP default protocol for most SDK setups):
  ```
  OTEL_EXPORTER_OTLP_ENDPOINT=http://observe.factory.svc.cluster.local:5080
  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
  ```
  OpenObserve exposes OTLP/HTTP under an org-scoped path; for OpenTelemetry SDKs
  set the base endpoint above and the signal-specific full URLs if your SDK does
  not auto-append the standard paths:
  ```
  traces : http://observe.factory.svc.cluster.local:5080/api/default/v1/traces
  metrics: http://observe.factory.svc.cluster.local:5080/api/default/v1/metrics
  logs   : http://observe.factory.svc.cluster.local:5080/api/default/v1/logs
  ```
  (`default` is the OpenObserve organization; change if you create another.)

- **OTLP/gRPC**:
  ```
  OTEL_EXPORTER_OTLP_ENDPOINT=http://observe.factory.svc.cluster.local:5081
  OTEL_EXPORTER_OTLP_PROTOCOL=grpc
  ```

**Auth header** (OpenObserve uses HTTP Basic with the root user):
```
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(email:password)>
# echo -n 'admin@freundcloud.org.uk:<password>' | base64
```

## 3. Public UI host — Keycloak SSO via oauth2-proxy (IMPLEMENTED)

The web UI is reachable in-cluster at `http://observe.factory.svc.cluster.local:5080`.
It is now exposed publicly on its own host **observe.freundcloud.org.uk**, fronted
by Keycloak SSO — mirroring EXACTLY how cfactory is exposed (`apps/cfactory-auth/`).
This was wired up in this repo (no longer an out-of-band operator one-liner):

- **`apps/observe-auth/`** — an ArgoCD `Application` (auto-discovered by the
  root App-of-Apps, same as `cfactory-auth`) that deploys an
  `oauth2-proxy-observe` Deployment + Service (`:4180`). It talks OIDC to
  Keycloak (realm `factory`, client `observe`,
  issuer `https://keycloak.freundcloud.org.uk/realms/factory`,
  redirect `https://observe.freundcloud.org.uk/oauth2/callback`) and proxies
  authenticated traffic upstream to `http://observe.factory.svc.cluster.local:5080`.
- **`infra/cloudflared/cloudflared.yaml`** — one ADDED ingress route (existing
  routes untouched), placed with the other oauth2-proxy'd services and before
  the `http_status:404` catch-all:

  ```yaml
        - hostname: observe.freundcloud.org.uk
          service: http://oauth2-proxy-observe.factory.svc.cluster.local:4180
  ```

In-cluster OTLP ingest (§2) is unaffected: AIFactory ships to the `observe`
Service (`:5080`/`:5081`) directly and never traverses oauth2-proxy or cloudflared.

### Operator steps the operator MUST do (SSO is manual, like every other Factory client)

Keycloak clients in this suite are created **imperatively** with `kcadm.sh`
inside the Keycloak pod — there is no declarative realm-import in this repo
(see `docs/keycloak-sso.md`). So the `observe` client and its Secret are NOT in
git and the operator must create them:

1. **Create the `observe` OIDC client** in realm `factory` (mirrors §2 of
   `docs/keycloak-sso.md`):

   ```bash
   KCPOD=$(kubectl -n factory get pod -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
   kubectl -n factory exec "$KCPOD" -c keycloak -- bash -c '
     K=/opt/keycloak/bin/kcadm.sh
     $K config credentials --server http://localhost:8080 --realm master \
        --user admin --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"
     $K create clients -r factory \
       -s clientId=observe -s enabled=true -s protocol=openid-connect \
       -s publicClient=false -s standardFlowEnabled=true \
       -s "redirectUris=[\"https://observe.freundcloud.org.uk/oauth2/callback\"]" \
       -s "webOrigins=[\"https://observe.freundcloud.org.uk\"]" || echo "observe client exists"
   '
   ```

   IMPORTANT: the `observe` client's redirect URI is the **oauth2-proxy callback**
   `https://observe.freundcloud.org.uk/oauth2/callback` (NOT the app `/api/auth/...`
   path used by the native-OIDC apps) — same as `cfactory` / `odin-dashboard`.

2. **Read the generated client secret** (do not echo it into git/logs):

   ```bash
   kubectl -n factory exec "$KCPOD" -c keycloak -- bash -c '
     K=/opt/keycloak/bin/kcadm.sh
     $K config credentials --server http://localhost:8080 --realm master \
        --user admin --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"
     CID=$($K get clients -r factory -q clientId=observe --fields id --format csv --noquotes)
     $K get clients/$CID/client-secret -r factory --fields value --format csv --noquotes
   '
   ```

3. **Create the `oauth2-proxy-observe` Secret** the proxy references (same shape
   as `oauth2-proxy-cfactory` — three keys: `client-id`, `client-secret`,
   `cookie-secret`). The cookie secret must be a fresh random 32-byte value:

   ```bash
   kubectl -n factory create secret generic oauth2-proxy-observe \
     --from-literal=client-id='observe' \
     --from-literal=client-secret='<the secret from step 2>' \
     --from-literal=cookie-secret="$(openssl rand -base64 32 | tr -d '\n')"
   ```

   Without this Secret the `oauth2-proxy-observe` pod will not start (the env
   refs are required), so the route will return 502 until it exists.

4. **DNS**: add the `observe.freundcloud.org.uk` CNAME to the Cloudflare tunnel
   (same as the other `*.freundcloud.org.uk` hosts).

5. **cloudflared rollout**: cloudflared reloads its config on file change, but
   the ConfigMap-mounted `config.yaml` may not hot-reload inside the running
   pod. If the new route 404s after the ArgoCD sync, restart the connector to
   pick up the new ingress entry:

   ```bash
   kubectl -n factory rollout restart deployment/cloudflared
   ```

OpenObserve also has its own root login (the `observe-root` Secret in §1), so
after the Keycloak gate the operator still authenticates to OpenObserve itself.

## 4. Import the starter dashboard

`dashboards/factory-per-worker-cost.json` is a dashboards-as-code starter with
panels for the P1 metrics: `gen_ai.input_tokens` / `gen_ai.output_tokens`,
`gen_ai.cost_usd` (by provider, by model), the `worker.duration_ms` histogram
(p95), and the `budget.exceeded` counter.

Import via the UI: **Dashboards -> Import -> Upload JSON**, then select the
`metrics` stream and `default` org.

Or via the API:
```bash
OO=http://observe.factory.svc.cluster.local:5080   # or https://observe.freundcloud.org.uk
AUTH=$(echo -n 'admin@freundcloud.org.uk:<password>' | base64)
curl -sS -X POST "$OO/api/default/dashboards" \
  -H "Authorization: Basic $AUTH" \
  -H 'Content-Type: application/json' \
  --data-binary @dashboards/factory-per-worker-cost.json
```

Note: the PromQL queries assume the OTel metric names arrive normalised to
underscores (`gen_ai_cost_usd_total`, `worker_duration_ms_bucket`, etc.) tagged
with `provider` / `model` / `phase`. Adjust the metric/stream names if your
collector or SDK maps them differently.
