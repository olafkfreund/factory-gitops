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
its job"*: the API server was unreachable, OpenObserve refused the record, or the
notification could not be delivered. The findings live in the stream and in the
issues, never in this exit code.

`audit-anchor-alert` keeps its non-zero exit **as well as** emitting, so nothing
that depended on the old behaviour regresses.

### Who watches the watchdog

It is a CronJob in the namespace, so it reports on itself like any other. If it
stops running entirely, its absence shows up as `job_health` having no records at
all for a window. A second stacked watchdog would only move the same question one
level up.

## Routing to a human (Factory#439)

The durable record above was correct and still functionally silent. The watchdog
logged `postgres-backup has NEVER succeeded in 5.6d since creation` every thirty
minutes for days. It was right every time. The fleet had no database backup at
all and did not know, and that was found by accident while working an unrelated
issue. **Detection was never the problem.** The only reader of a log stream is
someone who already went looking, which is exactly the person who does not need
telling.

So the watchdog notifies directly, and the notification is a **GitHub issue**.

### Why the watchdog posts, rather than an OpenObserve alert

Two options were on the table: an OpenObserve Alert + Destination on the
`job_health` stream, or the watchdog posting for itself. The watchdog posts.

- **A chain whose first link is the most misconfigurable subsystem is a poor
  chain.** If OpenObserve alerting breaks or is never armed, it breaks silently,
  and we are back here a third time. This was not hypothetical: at the time of
  writing the live cluster had **zero destinations and zero alerts** defined, so
  option 1 had never actually been connected to anything.
- **OpenObserve alert config is imperative API state.** It lives nowhere in git,
  so it drifts out of this GitOps repo the moment anyone edits it in the UI.

### Why a GitHub issue

There is no Slack webhook, SMTP relay or pager endpoint anywhere in this fleet.
The previous revision of this document said so and declined to invent one, which
was right — a placeholder URL that silently drops messages is this same bug in a
better disguise. A real channel that already exists beats a better channel that
does not:

- no new secret — the fleet `GITHUB_TOKEN` in `factory-secrets` already has the
  `repo` scope, and no URL or token is committed anywhere;
- it reaches the maintainer by GitHub notification and email, without anyone
  going looking;
- it is where every other fleet fault is already tracked and worked, including
  #437, #438 and #439 itself.

When a webhook endpoint does exist, it belongs *alongside* this, not instead of
it.

### Severity

"This backup has never once succeeded" must not sit at the same level as one
transient failed run, or the level means nothing and the label gets ignored.

| Severity | Findings | What it does |
|---|---|---|
| `critical` | `never_succeeded`, `stale` | Opens an issue labelled `severity:critical`, and **re-comments every `ALERT_RENOTIFY_HOURS`** (default 24) while it persists, so a long outage keeps resurfacing instead of sinking down the issue list. |
| `warning` | `failing`, `not_scheduled`, `suspended` | Opens an issue labelled `severity:warning`, then **stays quiet**. |

The split is "is the job's purpose being served". `critical` means no success sits
inside the tolerance window — there is not even a stale backup to fall back on.
`warning` means it is misbehaving but a success is still within tolerance and the
next run may clear it, or a human suspended it deliberately.

Nothing has to remember to escalate: a warning becomes critical on its own once
its last success finally ages past tolerance. Severity is computed from **every**
finding, not from `status` — `status` is only the first problem found, and
`cred-broker` reports `failing` first while the thing that makes it critical is
`stale`.

### And it shuts up

An alarm that fires every thirty minutes is muted inside a week, and a muted
alarm is silence reached by a more annoying road. So:

| Situation | What is sent |
|---|---|
| Healthy CronJob | nothing at all |
| Unhealthy, no open issue | one issue |
| Unhealthy, already reported | nothing, until it escalates or the re-notify window elapses |
| Severity changed | the issue is re-titled, re-labelled, and one comment explains the change |
| Recovered | a comment, and the issue is **closed** |
| CronJob deleted outright | a comment saying so, and the issue is closed as not-planned |

Deduplication keys on an HTML-comment marker in the issue **body**
(`<!-- job-watchdog:{namespace}/{cronjob} -->`), not the title, so a finding that
worsens updates the one issue rather than stacking duplicates beside it. An
existing hand-filed issue can be adopted by pasting that marker into it — which
is how `cred-broker` #437 is wired, so the watchdog maintains the issue a human
already opened instead of competing with it.

The deleted-CronJob case is closed but never *silently*: a CronJob that stops
existing produces no failures and no alerts, only silence (Factory#429), so the
disappearance is stated in the comment and a human judges whether it was
deliberate. The watchdog cannot tell retirement from accident.

### Configuration

| Env | Default | Meaning |
|---|---|---|
| `ALERT_REPO` | `olafkfreund/Factory` | `owner/repo` issues are raised on |
| `ALERT_RENOTIFY_HOURS` | `24` | re-comment cadence for `critical` |
| `GITHUB_TOKEN` | — | from `factory-secrets`, needs `repo` scope |

`ALERT_REPO` and `GITHUB_TOKEN` are checked **before any work** and are fatal if
missing (exit 2). There is deliberately no "carry on without notifying" mode:
running with no path to a human is the exact defect this closes, and it would be
invisible from the outside — the job would go green having told nobody anything.

Exit 5 means a notification could not be delivered. That is a hard failure, not a
logged warning, because an alert path that is not proven to deliver is the same
bug one layer up. The OpenObserve emit happens *first*, so if GitHub is
unreachable the durable record still lands and the delivery failure is itself
visible in the stream.

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
