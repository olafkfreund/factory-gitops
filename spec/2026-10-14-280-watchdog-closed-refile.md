---
status: approved
issue: 280
intent: intent/2026-10-14-280-watchdog-closed-refile.md
---

# Spec: watchdogs re-file an alert a human closed

## Design

Each watchdog looks at its closed issues as well as its open ones. When a closed
issue matches a finding, it compares when the issue was closed with when the
finding's event happened:

| Matching issue | Event time vs. `closed_at` | Action |
|---|---|---|
| open | (any) | today's behaviour: none, escalate or renotify |
| closed | event happened **before** the close | **none**: the closer already saw this event |
| closed | event happened **after** the close | **reopen** that issue and comment the new body |
| none | (any) | open, as today |

The event time is the time the reported thing happened:

- **restart-watchdog:** the last termination's `finishedAt`. `assess()`
  (`apps/restart-watchdog/manifests/manifests.yaml:280`) already parses it but
  only stores its age, so the record gains `"last_terminated_at": term.get("finishedAt")`.
- **job-watchdog:** the pod-termination records (`assess_pod_terminations`,
  `:1250`, which includes the node-kill shape of #3560) use their latest
  victim's `finished_at`. The other kinds (CronJob, ArgoCD, stuck Job, and
  `orphans_unreaped` at `:1530`, whose victims carry no `finished_at`) describe
  an ongoing **condition**, not a discrete event, and have no event time. For them, closed issues are ignored
  as they are today. A condition that is still true after a human closes its
  issue is still broken, and re-filing it is the correct signal. A stuck Job
  already carries the job name in its marker, so a new stuck Job gets a new
  issue anyway.

Changes in each watchdog's script, embedded in its ConfigMap:

1. **Lookup.** `open_issues()` (restart-watchdog `:507`) and
   `open_watchdog_issues()` (job-watchdog `:1874`) query `state=all&sort=updated`
   and return marker → issue. An open issue wins over a closed one, and among
   closed issues the most recently updated wins. The functions are renamed
   `watchdog_issues()` to say what they now return.
2. **Decision.** `notify_action()` gains one rule ahead of its existing ones:
   if the issue is closed, return `None` when the event time is missing or not
   after `closed_at`, and return `"reopen"` otherwise. For an open issue nothing
   changes. Keeping the rule inside `notify_action()` keeps it pure and testable,
   as its docstrings ask.
3. **Action.** `notify()` handles `"reopen"`: PATCH `state: open`, then comment
   "Reopened: a new event after this was closed." with `issue_body(r)`, and
   re-apply the severity label if it differs.
4. **Recovery and orphan loops** (restart `:573`, job `:1955`) iterate only over
   **open** issues, so a closed issue is never "recovered" or "no longer
   present" again.

Each watchdog's `selftest` gains cases for: closed before the event → silent;
closed after the event → reopen; closed condition record → open as today; an
open issue beats a closed one with the same marker; the recovery loop skips
closed issues.

## Alternatives rejected

- **Fingerprint the event in the issue body**, as a hash of fields. That needs
  a per-kind field list and a body parser. `closed_at` against the event time
  answers the same question with data GitHub and the record already hold.
- **Suppress any human-closed marker until the workload is healthy again.**
  A stateless CronJob can't know "healthy since the close" without writing
  state somewhere, such as a label. That's more moving parts.
- **Always file a new issue for a new event.** You chose reopening (intent
  decision 2) to keep one thread per workload.
- **Include condition kinds by using the last-success time as the event.**
  That would silence a CronJob that is still failing once someone closes its
  issue, which is exactly the silence these watchdogs exist to prevent.

## Risks

- **Paging.** `state=all&per_page=100&sort=updated` reads only the 100 most
  recently updated issues. A closed issue older than that falls out, and the
  next event opens a new issue instead of reopening. That's the same as today
  and harmless, so it's acceptable with a `shortcut:` comment.
- **Clock skew** between the node's `finishedAt` and GitHub's `closed_at` is
  seconds. A close within seconds of a new termination is not a realistic case.
- **Old open issues** have no marker change, so they keep working. No
  migration is needed.
- **Deploy:** Argo CD syncs the ConfigMaps from main. The next CronJob run uses
  the new script. No host change.

## Verification

- Both self-tests pass, extracted exactly as CI does:
  `python3 .github/scripts/extract_embedded_script.py <manifest> watchdog.py /tmp/x.py && python3 /tmp/x.py selftest`.
- `job-watchdog-test.yml` and `test_extract_all_embedded.py` are green on the PR.
- After deploy: closing a firing restart alert by hand produces no new issue on
  the next run (the `NOTIFIED` log line is absent), and a later termination of
  the same container reopens that issue.
