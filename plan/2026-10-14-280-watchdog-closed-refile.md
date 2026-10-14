---
status: draft
issue: 280
spec: spec/2026-10-14-280-watchdog-closed-refile.md
---

# Plan: watchdogs re-file an alert a human closed

## Approved decisions (carried from the spec)

- Each watchdog lists **all** its issues (`state=all&sort=updated&per_page=100`)
  and maps marker → issue. An **open issue wins** over a closed one with the
  same marker. Among closed issues, the most recently updated wins.
- A finding's **event time** decides what a closed issue means:
  - event time missing, or not after the issue's `closed_at` → **silent** (`None`);
  - event time after `closed_at` → **`"reopen"`**: PATCH `state: open`, apply
    the current severity label, and comment
    `"Reopened: a new event after this was closed.\n\n" + issue_body(...)`.
- Event time: restart-watchdog uses the record's new `last_terminated_at`
  (= `finishedAt`). job-watchdog uses the latest `victims[*]["finished_at"]` on
  pod-termination records **only**. CronJob, ArgoCD, stuck Job and
  `orphans_unreaped` records have **no** event time. For them a closed issue is
  treated exactly as "no issue" (open a new one, as today), because a condition
  that is still true should alert again.
- The recovery and orphan loops act on **open** issues only.
- The lookup functions are renamed `watchdog_issues()`. A comment:
  `# shortcut: only the 100 most recently updated issues are read; an older closed issue just means a new issue, as before`.
- Open-issue behaviour is otherwise **unchanged**.
- fleet-match and endpoint-guard are out of scope (#281).

## Steps

Steps 1 and 2 touch different files and can run in parallel.

1. **restart-watchdog** (`apps/restart-watchdog/manifests/manifests.yaml`, the
   embedded `watchdog.py`). **Coder: agy.**
   - `assess()` ~:304: add `"last_terminated_at": term.get("finishedAt"),` to the record.
   - `open_issues()` :507 → `watchdog_issues()`. Query `state=all&sort=updated`.
     Keep an open issue over a closed one, and the first-seen (most recently
     updated) closed one otherwise. Add the shortcut comment.
   - `notify_action()` :529: the first rule, when `issue` is closed (`issue.get("state") == "closed"`):
     event = `_parse_ts(record.get("last_terminated_at"))` if present;
     closed = `_parse_ts(issue.get("closed_at"))`; return `"reopen"` if both
     are set and event > closed, else `None`. Update the docstring's return list.
   - `notify()` :542: call `watchdog_issues`; add a `"reopen"` branch (PATCH
     state open plus labels `[ISSUE_LABEL, SEVERITY_LABELS[sev]]`, then the
     comment), with `eprint(f"NOTIFIED  {key_of(r)} [{sev}] -> reopened ...")`.
     The recovery loop :579 iterates `existing.items()` filtered to
     `issue.get("state") != "closed"`.
   - `_selftest()`: add cases: (a) closed before the event → `None`;
     (b) event after `closed_at` → `"reopen"`;
     (c) closed issue but the record has no `last_terminated_at` → `None`;
     (d) `watchdog_issues` prefers open over closed for the same marker (stub
     `gh`); (e) the recovery loop does not touch a closed issue (stub `gh`,
     assert no PATCH for it).
   → verify by:
   `python3 .github/scripts/extract_embedded_script.py apps/restart-watchdog/manifests/manifests.yaml watchdog.py /tmp/rw.py && python3 /tmp/rw.py selftest` → `selftest OK`.
   Traps: the script is YAML-embedded, so keep the ConfigMap's indentation
   exact (4 spaces of YAML block indent before Python). `_parse_ts` raises on
   `None` (`:237`), so guard before calling it. No new imports beyond the stdlib
   ones already present.

2. **job-watchdog** (`apps/job-watchdog/manifests/manifests.yaml`, embedded
   `watchdog.py`). **Coder: Codex.**
   - Add `def event_time(record) -> datetime | None`: if
     `record.get("victims")` and every victim has `"finished_at"`, return
     `max(_parse_ts(v["finished_at"]) ...)`; else `None`. This covers
     pod-termination records only, because orphan victims carry no `finished_at`.
   - `open_watchdog_issues()` :1874 → `watchdog_issues()`, with the same rules
     as step 1 (`state=all&sort=updated`, open wins, shortcut comment).
   - `notify_action()` :1620: the first rule, when the issue is closed:
     `ev = event_time(record)`; if `ev is None` → treat as `issue = None` and
     fall through to the existing rules (so a condition reopens as a NEW issue,
     as today). Otherwise return `"reopen"` if `sev` is not None and
     `ev > _parse_ts(issue["closed_at"])`, else `None`. A healthy record
     (`sev is None`) with a closed issue → `None` (never "close" a closed issue).
   - `notify()` :1888: call `watchdog_issues`; add the `"reopen"` branch, as in
     step 1. The orphan loop :1955 and the `"close"` path act only on open
     issues (filter `existing` once into `open_existing` for the orphan loop).
   - `_selftest()` :2189: add cases: termination record closed after → `None`;
     termination record with a new victim after the close → `"reopen"`; a
     CronJob record with a closed issue → `"open"`; a healthy record with a
     closed issue → `None`; the orphan loop skips a closed issue.
   → verify by:
   `python3 .github/scripts/extract_embedded_script.py apps/job-watchdog/manifests/manifests.yaml watchdog.py /tmp/jw.py && python3 /tmp/jw.py selftest` → `selftest OK`.
   Traps: same YAML indentation rule. `_parse_ts(raw: str)` (:670) also needs a
   non-None value. The `cronjob` key name is load-bearing (see the comment at
   :943); do not rename it. Keep type hints, as this file uses them.

3. **Review and PR** (session): a fresh Opus agent reviews `git diff` against
   this plan; open the PR linking intent, spec and plan, closing #280, and
   saying which coder did which step.

## Tests

```bash
S=$(mktemp -d)
for a in restart-watchdog job-watchdog; do
  python3 .github/scripts/extract_embedded_script.py apps/$a/manifests/manifests.yaml watchdog.py $S/$a.py \
    && python3 $S/$a.py selftest
done   # both: selftest OK
python3 -m pytest -q .github/scripts/test_extract_all_embedded.py
```

Baseline (main, 2026-10-14): both self-tests print `selftest OK`.

## Rollback

Revert the squash-merge commit on main. Argo CD syncs the old ConfigMaps, and
the next CronJob run uses the old script. Any issue the new code reopened stays
open, which is harmless; close it by hand.
