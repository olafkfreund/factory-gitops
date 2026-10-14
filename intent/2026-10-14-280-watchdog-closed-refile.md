---
status: draft
issue: 280
author: olafkfreund
---

# Intent: watchdogs re-file an alert a human closed

## Problem

When someone triages a watchdog alert and closes its issue, the watchdog files
a new issue for the same event on its next run. On 2026-10-14,
olafkfreund/Factory#3561 (fides-server exited 1 during the cluster restart after
a planned reboot) was investigated and closed. Two hours later restart-watchdog
opened olafkfreund/Factory#3578 for the same termination: the same
`finishedAt` (08:26:54Z) and the same restart count (7). Nothing had happened
since.

The cause: `open_issues()` (`apps/restart-watchdog/manifests/manifests.yaml:507`)
asks GitHub only for `state=open` issues. A closed issue doesn't exist as far as
the watchdog is concerned, so a termination still inside `WINDOW_HOURS` (6h)
looks unreported. job-watchdog does the same lookup
(`apps/job-watchdog/manifests/manifests.yaml:1877`).

The result is that closing a triaged alert doesn't stick. A human has to close
the same finding twice, and the duplicate issue makes a single incident look
like two.

## Proposed outcome

- A watchdog alert that a human closes stays closed for the event it reported.
- A new event on the same workload (a later termination) still raises an alert,
  so closing an issue never silences a workload for good.
- The watchdog's own auto-close on recovery keeps working.

## Affected users and systems

- restart-watchdog and job-watchdog (CronJobs in the k3d `factory` cluster,
  deployed from this repo by Argo CD). They file into olafkfreund/Factory.
- Whoever triages Factory alerts.
- fleet-match and endpoint-guard also list only `state=open` issues
  (`fleet-match` :690, `endpoint-guard` :568). Whether they hit the same problem
  is not yet checked.

## Constraints

- Must not suppress a genuinely new termination or kill.
- Must keep working when several alerts for different workloads are open.
- The embedded scripts carry their own self-tests (`job-watchdog-test.yml`, and
  the `test_extract_all_embedded.py` harness). The fix has to keep them passing.
- Deploying is an Argo CD sync from main. No host change.

## Open questions

1. What counts as "the same event"? The termination's `finishedAt` (and the
   node-kill timestamp for job-watchdog) is the obvious key, and the issue body
   would need to record it.
2. When a new event follows a human close, should the watchdog reopen the old
   issue (one thread per workload) or file a new one?
3. Scope: fix restart-watchdog and job-watchdog only, or also check fleet-match
   and endpoint-guard in this task?
