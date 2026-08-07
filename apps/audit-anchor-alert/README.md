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

Reads two read-only surfaces and fails on any of:

- either endpoint unreachable / non-200 (CFactory or its audit store is down)
- chain empty (nothing anchored at all), or a verdict computed over zero rows
- `GET /api/audit/chain` verdict of `tampered` (a mutated, duplicate or dangling
  row) or `forked` (an **undeclared** concurrent-append fork — after CFactory#310
  serialised the appends, a new one means that serialisation regressed)
- stale: newest entry older than `STALE_HOURS` (default 26h)

`GET /api/audit/chain` (CFactory#312) is the integrity authority: it walks every
row and recomputes every HMAC server-side, and returns the verdict plus the row
count it actually walked. `GET /api/audit` is still read, for entry timestamps —
the chain report carries none — and as the degraded fallback below.

**A check that cannot run reports `degraded`, not `ok`** (factory-gitops#146). A
cockpit image predating CFactory#312 answers 404 on `/api/audit/chain`; the job
then exits non-zero, says so loudly, and falls back to the old newest-100
structural check so the weaker signal is not lost — but a clean 100-row window
cannot promote the run to a pass. This red clears itself when the deployed image
carries CFactory#312. Declared forks (`CFACTORY_AUDIT_ACKNOWLEDGED_FORKS` in
`apps/cfactory`, currently entry `2178`) are counted and reported, never alerted
on: an alarm that is always on is not an alarm.

Stdlib only, `python:3.12-slim`, runs as non-root with a read-only rootfs — the
same hardened pattern as `apps/cred-broker`. No HMAC secret is needed here: the
recompute happens inside CFactory, which is the only thing holding the key.
`API_KEY` (optional, from `cfactory-api-keys/api-key`) is sent as a bearer so the
check keeps working now the `/api/*` keystore is enforced.

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
- ~~**Chain-break vs HMAC:** this does structural link verification; a full HMAC
  recompute belongs behind a CFactory `/api/audit/verify` endpoint (follow-up).~~
  **Done (factory-gitops#146).** That endpoint shipped as `GET /api/audit/chain`
  (CFactory#312) and this job now reads it — see "What it checks" above. The
  prediction was right and the gap was live: `GET /api/audit` serves the newest
  100 rows, and against a 5,402-row trail that window is ids ~5300-5402, so the
  standing fork at 2178 sat outside it. The job reported `ok` daily on a chain
  with a known anomaly, and would have missed an edit to any of the other 98%.
