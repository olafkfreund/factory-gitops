# CronJob health watchdog

`cred-broker` rotates the fleet's shared Claude OAuth credential every 4 hours. Its
stored credential expired on 2026-06-07 and the rotation failed **every run for
roughly seven weeks**. Nobody was told. It surfaced only because somebody happened
to run `kubectl get jobs` while looking into something else.

Had the access token expired before that, every agent run across AIFactory,
PFactory and TFactory would have failed at once, with an auth error that reads
like a model or network fault.

This app (`apps/job-watchdog`, Factory#381) closes that blind spot for every
CronJob in the `factory` namespace.

## Why the previous design could not have caught it

The namespace's convention was that a failed Job *is* the alert — a checker exits
non-zero and dies. `audit-anchor-alert` was the clearest case: it printed
`ALERT: ...` to stderr and exited 1. Its only outbound request *fetched*
`/api/audit`. It notified nobody.

An alert job whose alert is "the job failed", in a cluster where nothing watches
job failures, is a no-op. Worse, failed Jobs are garbage collected
(`failedJobsHistoryLimit`), so the evidence expires too: only ~9 hours of the
seven-week window still existed by the time anyone looked.

## The two signals

The watchdog runs every 30 minutes and writes one record per CronJob to the
OpenObserve stream `job_health`.

| Signal | Source | Survives Job GC? |
|---|---|---|
| consecutive failures | the Jobs a CronJob owns | **No** — bounded by `failedJobsHistoryLimit` |
| staleness / not-scheduled / never-succeeded | `CronJob.status.lastSuccessfulTime` and `.lastScheduleTime` | **Yes** — these live on the CronJob object |

The second row is the load-bearing one. Counting failures only works while the
failures still exist as objects; that is precisely the signal that had already
evaporated in #378. `lastSuccessfulTime` is on the CronJob's own status
subresource and stays true long after every Job has been reaped.

So **"no news" never reads as OK.** A CronJob whose Jobs have all been GC'd, that
has stopped being scheduled, that has never once succeeded, or that is suspended,
reports a problem — not silence.

### Statuses

- `ok`
- `failing` — N consecutive failed runs (default threshold 2)
- `stale` — last success is older than tolerance, regardless of surviving Jobs
- `never_succeeded` — no recorded success at all, and past the grace window
- `not_scheduled` — the controller has stopped creating Jobs for it
- `suspended` — `spec.suspend` is set

### Tolerance

Each CronJob is judged against its own cadence, estimated from its cron schedule:

```
tolerance = 2 * period + min(900s, period)
```

Two periods forgives one entirely missed run. The grace absorbs scheduler jitter
and image pull, and is **capped at one period** — a flat 15-minute grace gave a
1-minute CronJob a 17-minute blind window, which the induced-failure test caught
reporting a dead canary as healthy.

Set `factory.dev/expected-period-seconds` on a CronJob to override the estimate
when the schedule is too exotic to read (ranges, lists).

## Querying it

```sql
SELECT cronjob, status, consecutive_failures, surviving_jobs, last_success_age_seconds
FROM "job_health"
WHERE status != 'ok'
ORDER BY _timestamp DESC
```

`audit-anchor-alert` writes into the same stream with `source =
'audit-anchor-alert'`, on both its alert and healthy paths, so one query covers
scheduled-job health and audit-chain health together.

## Why it exits 0 even when it finds problems

A watchdog that goes red on its findings is indistinguishable from a watchdog that
is itself broken — and it would be repeating the exact mistake this issue is
about. A non-zero exit from `job-watchdog` means only *"the watchdog could not do
its job"*: the API server was unreachable, or OpenObserve refused the record. The
findings live in the stream.

`audit-anchor-alert` keeps its non-zero exit **as well as** emitting, so nothing
that depended on the old behaviour regresses.

### Who watches the watchdog

It is a CronJob in the namespace, so it reports on itself like any other. If it
stops running entirely, its absence shows up as `job_health` having no records at
all for a window. A second stacked watchdog would only move the same question one
level up.

## Paging a human — not done here, and deliberately not invented

These records are durable and queryable, but nothing yet wakes anybody at 3am.
OpenObserve has an Alerts + Destinations + Templates feature. Turning `job_health`
into a page needs, in the OpenObserve UI or API:

1. A **Destination** holding a real webhook URL and its auth header. **That URL
   does not exist yet** — no endpoint is guessed or hardcoded anywhere in this
   repo.
2. A **Template** rendering the record into the message body.
3. A scheduled **Alert** on stream `job_health`, condition `status != 'ok'`, over
   a window matching the 30-minute cadence.

Step 1 requires a real endpoint from a human. Until it exists, the honest claim is
that this app produces a durable record and a query surface — not that it pages.

## RBAC

Own ServiceAccount, namespaced Role, no cluster-wide grant, read-only, following
the `apps/cred-broker` precedent:

```yaml
rules:
  - apiGroups: ["batch"]
    resources: ["cronjobs", "jobs"]
    verbs: ["get", "list"]
```

## Post-mortem evidence

All five pre-existing CronJobs now keep `failedJobsHistoryLimit: 10`.

`ttlSecondsAfterFinished: 3600` was **removed** from `postgres-backup`,
`evidence-collector` and `audit-siem-forward`. It reaped every finished Job an
hour after completion regardless of outcome, which silently overrode
`failedJobsHistoryLimit` — raising that limit does nothing while the TTL
controller deletes the evidence an hour after it is produced. The history limits
are the correct reaper because they are per-outcome: successes stay capped at 3,
failures survive long enough to read.
