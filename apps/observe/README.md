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

## 3. Public UI host (operator-added cloudflared route)

The web UI is reachable in-cluster at `http://observe.factory.svc.cluster.local:5080`.
To expose it publicly on its own host **observe.freundcloud.org.uk** — mirroring
how cfactory is exposed — the operator adds ONE ingress entry to the shared
`infra/cloudflared/cloudflared.yaml` ConfigMap (kept out of this PR on purpose,
so this app touches no shared/CFactory config):

```yaml
      - hostname: observe.freundcloud.org.uk
        service: http://observe.factory.svc.cluster.local:5080
```

Optionally front it with a Keycloak `oauth2-proxy-observe` (copy `apps/cfactory-auth/`)
if the UI should require SSO. OpenObserve also has its own login (the root user
above), so the bare route is already credential-gated.

The DNS record + cloudflared route + any SSO are the operator's decision.

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
