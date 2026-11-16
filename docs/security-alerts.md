# Security alert rules (Factory#3688, R-009)

`apps/security-alerts` is a CronJob (every 15 minutes) that evaluates two rules against
OpenObserve. It uses the alert path the cluster already has (there is no Prometheus or
Alertmanager, see `docs/argocd-sync-honesty.md`): one `job_health` record per rule, one GitHub
issue per firing rule, and `job-watchdog` watching the CronJob itself, so a dead evaluator is
reported like any other failed CronJob.

## Rules

| Rule | Counts | Window | Fires at | Source |
|---|---|---|---|---|
| `auth_failure_spike` | rows with `action = 'auth.failure'` | 30 min | `AUTH_FAIL_THRESHOLD` (10) | stream `audit_chain` (`docs/audit-siem-forwarding.md`) |
| `egress_anomaly` | every row in the stream | 30 min | `EGRESS_THRESHOLD` (1) | stream named by `EGRESS_STREAM` |

Statuses in the `job_health` record (`kind = security_alert`, field `rule`): `ok`, `firing`,
`error` (query failed; the run exits 1), `no_source` (the stream does not exist; never read as
zero; for `auth_failure_spike` the run also exits 1, so job-watchdog reports the CronJob) `no_field` (OpenObserve says no row in the stream has ever had the field `action`, so no auth failure has been ingested; count is null, the run exits 0, and detection is unavailable, not proven zero; it clears when the first row arrives), and `not_configured` (`EGRESS_STREAM` empty; exits 0, optional source).

```sql
SELECT rule, status, count, threshold FROM "job_health"
WHERE kind = 'security_alert' ORDER BY _timestamp DESC
```

## What is not done yet

- **Egress detects nothing today.** No egress telemetry exists: `docs/egress-allowlist.md` is a
  design only. Contract for when the owner builds the proxy in log-only mode: forward one row per
  off-allowlist connection into an OpenObserve stream, then set `EGRESS_STREAM` to its name in
  `manifests.yaml`.
- **No paging destination.** Issues open in Factory with label `security-alert` (needs
  `GITHUB_TOKEN` in `factory-secrets`, as for `secret-rotation`). To page, create the optional
  Secret; the job then POSTs `{"text": ..., "dedup_key": <rule>}` on every run in which a rule is
  firing (a failed POST is retried next run and exits 1). The destination must accept that JSON
  and is outside `factory` egress policy if it is external:

  ```bash
  kubectl -n factory create secret generic security-alert-webhook --from-literal=url='<paging webhook URL>'
  ```

- **Routing existing `job_health` failures to a pager.** `job-watchdog` posts to the same
  `security-alert-webhook` Secret (Factory#3688). It POSTs `{"text": ..., "dedup_key": "<issue
  marker>"}` for every **critical** finding on every run while its issue is open (about every 30
  minutes), so the pager must de-duplicate on `dedup_key`, as for `security-alerts`; a failed POST
  is retried by the next run. Warnings stay GitHub-issue-only. Off while the Secret is absent. A
  failed POST is counted and the run exits 7 after the heartbeat, so a dead pager shows as a red
  CronJob rather than silence. The destination (who is paged, by which channel) is the owner's
  choice and must accept that JSON. Recovery is not paged: the issue closes.
- **Known limit.** The auth rule reads what `audit-siem-forward` has delivered. That forwarder caps
  a run at 10,000 rows and reports success with a backlog, so a large backlog can push rows past the
  30-minute window. A forwarder-lag check is a follow-up.
- Thresholds are first guesses. Tune `AUTH_FAIL_THRESHOLD` after a week of `count` values.

The incident-response tabletop that exercises these alerts is in Factory
`docs/compliance/ir-tabletop.md`.
