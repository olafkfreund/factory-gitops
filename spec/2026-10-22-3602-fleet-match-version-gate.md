---
status: draft
issue: 3602
intent: intent/2026-10-22-3602-fleet-match-version-gate.md
---

# Spec: fleet-match calls a version-gated deploy run a build

## Design

Chosen design (the user's decision for this wave): count a Deploy run as
built only when its `build-push` job concluded `success`, and forgive a
version-gated HEAD the way a docs-only push is already forgiven. All changes
are in `apps/fleet-match/manifests/manifests.yaml` (the embedded `match.py`).

1. `repo_state()`: for each run that concluded `success`, newest first, read
   `GET /repos/{repo}/actions/runs/{id}/jobs` and set `run["built"] = False`
   when a job named `build-push` exists and did not conclude `success`. Stop
   after the first run that built, because only the newest build and HEAD's
   run are read later. A run with no `build-push` job (PFactory, TFactory,
   CFactory, the runner workflows) stays built, as today. If the jobs call
   fails, the run stays built (today's behaviour) and a warning is printed.
2. `latest_success()`: skip runs with `built is False`.
3. `assess()` signal B: when every run for HEAD is completed and HEAD has a
   successful run with `built is False`, append the note `version_gated`
   and raise nothing.
4. Selftest: a run that succeeded with `build-push` skipped must not become
   the expected sha, and the case from #3602 (HEAD gated, pods on the previous
   build) must assess as `version_gated` with no codes.

## Alternatives rejected

- Check that `ghcr.io/...:sha-<head>` exists in the registry. It needs registry
  auth in the CronJob and still doesn't explain why the build was skipped.
- Parse the run log for "version unchanged". Brittle, and a log download is a
  much larger call than the job list.
- Change AIFactory's deploy.yml to conclude `skipped` or `neutral`.
  Workflow conclusions can't be set that way from a job gate, and the checker
  would still be wrong for the next repo that adds a gate.

## Risks

- One extra GitHub API call per successful run until the first build is found:
  usually 1–2 calls per repo per CronJob run, well within the rate limit.
- If a `build-push` job is renamed in AIFactory, gated runs count as builds
  again. That fails noisy (a false alarm), not silent.

## Verification

- `python3 .github/scripts/extract_embedded_script.py apps/fleet-match/manifests/manifests.yaml match.py /tmp/fm.py && python3 /tmp/fm.py selftest`
  passes. With step 2 reverted, the new assertion fails.
- CI `job-watchdog-test.yml` and `manifest-validate.yml` are green.
- After rollout, Factory#3602 closes itself on the next CronJob run.
