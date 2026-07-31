# ArgoCD sync honesty — why `Synced` was not true, and what now checks it

Closes the diagnosis for Factory#425.

## The user story

> As the person verifying a fix I just merged, I need to know that the pod I am
> about to test is running my code — and if it is not, I need to be told,
> not left to discover it by reading files inside the container.

Three times across 2026-07-28/29 that was false, and every signal said
otherwise:

| Signal | Said | Truth |
|---|---|---|
| `kubectl get application` | `Synced / Healthy` | one gitops commit behind |
| `kubectl rollout status` | `successfully rolled out` | rolled out the *old* image |
| `deploy.yml` run | `success` | bump landed; nothing consumed it |

The cost is not the delay. Twice the stranded commit was the fix the author had
just merged and was about to verify — so verification would have run against
the old code and reported the fix as broken, sending the next investigation
after a change that was never deployed. `Synced` did not merely fail to inform;
it actively misdirected.

## What `Synced` actually means

`status.sync.revision` is the revision ArgoCD's **repo-server last resolved**,
not the tip of your branch. `Synced` compares the cluster against *that*. So it
reads "synced to the revision I last fetched", and from outside there is no way
to tell that apart from "synced to what git says".

## Root cause, measured rather than assumed

Two independent 180-second timers sit between a push and ArgoCD noticing it,
and **neither one is the `timeout.reconciliation` people reach for first**.

1. **No webhook.** `gh api repos/olafkfreund/factory-gitops/hooks` returns `[]`.
   Nothing tells ArgoCD a commit landed, so it only ever finds out by polling.

2. **Controller poll — `timeout.reconciliation`, default 180s.** `argocd-cm` in
   this cluster is empty (no `data:` at all, untouched since install), so every
   timeout is at its upstream default.

3. **Repo-server `ls-remote` cache — the part that actually bites.** The
   repo-server caches its ref resolution in Redis under
   `git-refs|https://github.com/olafkfreund/factory-gitops|1.8.3.gz`. Observed
   live, its TTL cycles `180 -> 0 -> 180`. On a cache hit the repo-server
   returns the *cached* sha without going to git.

Because of (3), **the controller can reconcile an app after a commit lands, get
the pre-commit sha back, and record `Synced` against it.** The issue comments
show exactly this: `reconciledAt 10:13:40Z`, after the push, still on the
previous commit. A recent `reconciledAt` is therefore *not* evidence that the
newest revision was ever considered.

### The trap

**Lowering `timeout.reconciliation` on its own fixes nothing.** The repo-server
keeps serving the same 180s-cached sha, so the app gets "refreshed" three times
against a stale answer and reports `Synced` each time. Anyone who lowers that
number, sees no change, and moves on has reproduced the original bug in a new
place: a knob turned without checking whether it did anything.

There is no `argocd-cmd-params-cm` key for the revision cache in v2.13 — it is
the repo-server CLI flag `--revision-cache-expiration`. Changing it means
patching the Deployment args in `bootstrap/`, which is applied once at cluster
bootstrap and **not** re-applied by ArgoCD. The webhook avoids all of this.

## Measured on this cluster, 2026-07-30

Identical workload both times: one docs-only commit to `main`, 27 Applications
sourced from `factory-gitops`.

| | push | all 27 at HEAD | window | apps reporting `Synced` while behind |
|---|---|---|---|---|
| **Polling only (today)** | 09:14:06Z | 09:19:49Z | **5m43s** | 25 apps, for 2m35s |
| **With a push webhook** | 09:20:45Z | 09:21:22Z | **37s** | none observed |

343s versus 37s. The polling figure lands almost exactly on the predicted
`180 + 180 = 360s` ceiling, which is what confirms the two caches are the
mechanism.

## The fix, in the order it matters

### 1. Make the reported revision honest — add the webhook (DONE 2026-07-31)

This is the real fix: it removes the blind window rather than shrinking it, and
ArgoCD's webhook handler invalidates the cached refs instead of waiting for the
TTL. `argocd.freundcloud.org.uk` is already publicly routed by
`infra/cloudflared/`, and `POST /api/webhook` answers.

**Live since 2026-07-31** (Factory#506): hook `659390464` on
`olafkfreund/factory-gitops`, push events, JSON, HMAC secret held in
`argocd-secret` under `webhook.github.secret`. Deliveries return 200; the
measured convergence is recorded in section 3 below.

The commands are kept here because they are the recovery procedure, not just the
setup: if the hook is ever deleted or the secret rotated, this is what re-creates
it. Note the secret reaches `kubectl` and `gh` via a file rather than an argument
in the runbook below — the inline form puts a live credential in the process
table and in shell history.

```bash
# 1. a shared secret, so the endpoint is not an open refresh trigger
SECRET=$(openssl rand -hex 32)

# 2. teach argocd-server about it (additive key; argocd-server hot-reloads it)
kubectl --context factory -n argocd patch secret argocd-secret \
  --type merge -p "{\"stringData\":{\"webhook.github.secret\":\"$SECRET\"}}"

# 3. point the repo at it
gh api -X POST repos/olafkfreund/factory-gitops/hooks \
  -f name=web -F active=true -f 'events[]=push' \
  -f config[url]=https://argocd.freundcloud.org.uk/api/webhook \
  -f config[content_type]=json -f config[secret]="$SECRET"
```

Verify with a real push, not by assuming — `gh api
repos/olafkfreund/factory-gitops/hooks/<id>/deliveries` must show a `200`, and
the app revision must move within a minute.

**Without the secret the endpoint accepts unauthenticated POSTs.** The blast
radius is only a forced refresh, which auto-sync would do within 3 minutes
anyway, but leaving it open lets anyone on the internet drive repo-server load.
Set the secret.

### 2. Make staleness loud regardless — `apps/argocd-drift`

The webhook is a delivery mechanism, and delivery can fail silently: a webhook
that stops firing looks exactly like a repo with no commits. So the webhook is
not allowed to be the only thing standing between a stale pod and a green
dashboard.

`apps/argocd-drift` re-checks ArgoCD's claim from outside ArgoCD, every 5
minutes, against the git remote itself, and writes one record per Application
to the OpenObserve stream `argocd_drift`. Per the shared standard's rule 4.7 —
a gate that cannot verify must not report success — anything it cannot evaluate
is reported as a finding, never skipped.

#### What it reports

| `status` | Meaning |
|---|---|
| `ok` | reported revision equals the branch tip, and ArgoCD looked recently |
| `revision_behind` | **the #425 defect** — reported revision is not the branch tip, and the tip has been current longer than the tolerance |
| `reconcile_stale` | ArgoCD has not compared this app in longer than the tolerance; its status is a cached opinion of that age |
| `never_reconciled` | no `reconciledAt` at all — never successfully compared |
| `no_revision` | ArgoCD reports no revision to compare |
| `sync_unevaluated` | sync status is neither `Synced` nor `OutOfSync`, so ArgoCD is not claiming anything |
| `tip_unknown` | the git remote was unreachable, so nothing about this app was verified |

`OutOfSync` is deliberately **not** a finding. ArgoCD is telling the truth
there, and repeating its own signal is noise.

#### Options

| Env | Default if unset | Effect |
|---|---|---|
| `DRIFT_TOLERANCE_SECONDS` | `600` | grace after a commit lands before a behind-tip app is a finding |
| `RECONCILE_TOLERANCE_SECONDS` | `900` | max age of `status.reconciledAt` before that alone is a finding |
| `OO_STREAM` | `argocd_drift` | OpenObserve stream written to |
| `OO_ORG` | `default` | OpenObserve organization |
| `OBSERVE_URL` | `http://observe.factory.svc.cluster.local:5080` | OpenObserve base URL |
| `OO_USER` / `OO_PASS` | *(none — job exits 2)* | from the `observe-root` secret |
| `GITHUB_API` | `https://api.github.com` | override for the commit-date lookup |

`DRIFT_TOLERANCE_SECONDS` **must stay above ~360s until the webhook is live**,
because that much blindness is legitimate today and a tighter value would fire
on every normal deploy. Once the webhook is in, 180s is generous against the
measured 37s — and lowering it is the whole point of adding the webhook.

#### Exit codes

`0` means it reported, whatever it found. Non-zero means **this job** is
broken, never that a watched Application is: `2` no OpenObserve credentials,
`3` kubernetes API unreachable, `4` OpenObserve ingest failed, `5` no git
remote reachable. Same contract as `apps/job-watchdog`, and for the same
reason — a watchdog that goes red on its findings is indistinguishable from one
that is itself broken.

#### Running it by hand

```bash
kubectl --context factory -n factory create job --from=cronjob/argocd-drift drift-now
kubectl --context factory -n factory logs job/drift-now
```

The script's own checks run offline:

```bash
python3 drift.py selftest
```

#### Cost

One `ls-remote` per **distinct (repo, branch)** per run — currently 3, not 29,
because apps sharing a repo share the lookup. That is ~36 unauthenticated git
requests an hour against `info/refs`, which has no published rate limit. The
GitHub REST API is used only for the tip's commit date, only when a mismatch
already exists, so a healthy cluster makes zero REST calls and stays clear of
the 60/hr unauthenticated limit that this cluster's single egress IP shares
with everything else.

### 3. What was deliberately not done

- **No shortening of `timeout.reconciliation`.** It is not the bottleneck (see
  the trap above), it would triple controller and repo-server load for a
  change the measurements say is invisible, and it would leave the impression
  the problem was handled.
- **No Prometheus/Alertmanager.** OpenObserve is already the SIEM and already
  receives `job_health` from `apps/job-watchdog`; adding a metrics stack to
  fix a notification gap is the wrong trade.
- **No paging destination.** Turning `argocd_drift` records into a page needs
  a real webhook URL and its auth header in an OpenObserve Destination. That
  endpoint does not exist yet and is not invented here — same open item as
  `docs/job-health-watchdog.md`.

## Coverage gap this leaves open

Only CFactory has a deploy-drift watchdog of its own (CFactory#236). TFactory,
PFactory and AIFactory have none — the #425 incident happened on TFactory and
nothing in that repo would have reported it. `apps/argocd-drift` covers all of
them at the ArgoCD layer, which is where the failure actually was, but it does
not compare the *running container's image digest* to gitops HEAD. An app can
be `Synced` at the right revision with a rollout that never completed. That
check is tracked separately.
