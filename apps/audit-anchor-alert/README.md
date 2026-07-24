# audit-anchor-alert — first real security alert for the fleet (Factory#313, #319)

The fleet had zero security alerting. This is the smallest thing that actually
alerts on the highest-value signal: CFactory's tamper-evident audit chain (the
HMAC "anchor", `cfactory/audit.py`, #21) silently going stale or breaking. If
that chain stops being written, the audit trail loses its integrity guarantee
and nobody notices.

## What monitoring exists (and why this is a CronJob, not a PrometheusRule)

The cluster has **no Prometheus, Alertmanager, kube-state-metrics, or
PrometheusRule CRD**. OpenObserve (`apps/observe`) is the only telemetry backend
and it is an OTLP log/metric sink, not an alerting engine. There is also no Slack
webhook wired anywhere. So there is nothing to hang a metric-based rule on.

The minimal real alert available today is therefore a daily Kubernetes CronJob
that verifies the chain and **exits non-zero when it is stale or broken**. A
failed Job is the alert — it shows up in `kubectl get jobs -n factory`, in the
ArgoCD app health, and in the OpenObserve pod-log stream. `failedJobsHistoryLimit`
keeps the last 7 failures for triage.

## What it checks (`manifests/manifests.yaml`, `check.py`)

Reads the read-only `GET /api/audit` surface and fails on any of:

- endpoint unreachable / non-200 (CFactory or its audit store is down)
- chain empty (nothing anchored at all)
- chain break: an entry's `prev_hash` does not match the prior entry's
  `entry_hash` (deletion, reorder, or tamper)
- stale: newest entry older than `STALE_HOURS` (default 26h)

Stdlib only, `python:3.12-slim`, runs as non-root with a read-only rootfs — the
same hardened pattern as `apps/cred-broker`. No HMAC secret is needed: link
integrity is checked structurally; full HMAC re-verification stays CFactory's job
(`AuditStore.verify`). `API_KEY` (optional, from `cfactory-api-keys/api-key`) is
sent as a bearer so the check keeps working if/when the `/api/*` keystore is
enforced.

Self-test the pure chain logic without a cluster:

```bash
python3 <(kubectl -n factory get cm audit-anchor-alert-script -o jsonpath='{.data.check\.py}') selftest
```

## Deliberate scope / follow-ups

- **No dedicated daily anchor _producer_ exists yet.** The "anchor" is the tip of
  the in-process chain; entries are written on HITL actions. On a genuinely quiet
  control plane the freshness check can fire without a real fault — set
  `STALE_HOURS=0` to disable freshness (keeping the reachability + integrity
  checks) until a real daily notarizing anchor lands.
- **Notification path.** Failed-Job is the signal today. Wire it to a real
  notifier (Alertmanager, or an OpenObserve alert on the Job's log stream) once
  that plumbing exists.
- **Auth-failure-spike alerting** (the other half of #313/#319) is intentionally
  out of scope here: there is no auth-log pipeline to threshold on yet. Track
  separately.
- **Chain-break vs HMAC:** this does structural link verification; a full HMAC
  recompute belongs behind a CFactory `/api/audit/verify` endpoint (follow-up).
