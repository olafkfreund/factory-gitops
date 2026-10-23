---
status: approved
issue: 3602
author: olafkfreund
---

# Intent: fleet-match calls a version-gated deploy run a build

Tracks olafkfreund/Factory#3602. The fix lives in this repo
(`apps/fleet-match`), because the false alarm comes from the checker, not from
AIFactory.

## Problem

fleet-match opened Factory#3602 ("aifactory is running an image older than
main") and raised it to critical. The service is not behind. AIFactory's Deploy
run 39403910559 for `89c2ab2` concluded `success`, but its `changes` job
logged `version unchanged (3.10.4) — not deploying`, and `build-push`, `pin`,
`build-nix` and `seam-check` were all skipped. No `sha-89c2ab2` image exists.
The pods run `sha-6231576`, the newest image that was built, which is what
gitops commit `d29f6e6` pinned.

`latest_success()` in `apps/fleet-match/manifests/manifests.yaml` treats any
Deploy run with `conclusion == "success"` as an image build, so it holds the
cluster to a sha that was never built. The alert cannot close itself, because
the gap never closes.

## Proposed outcome

- A Deploy run whose `build-push` job was skipped does not count as a build.
  The expected sha is the newest run that really built an image.
- When main HEAD's only deploy run is version-gated, fleet-match reports it as
  forgiven, the same way it forgives a docs-only push, rather than as
  `spec_behind` or `build_failed`.
- Factory#3602 closes itself on the next CronJob run after this rolls out.

## Affected users and systems

- `fleet-match` CronJob (factory namespace) and the alert issues it files in
  olafkfreund/Factory.
- Only AIFactory's deploy.yml has the version gate today. PFactory, TFactory,
  CFactory and the runner workflows have no job named `build-push`, so they
  must keep their current behaviour.

## Constraints

- Must not hide a real stranded build: a failed or cancelled run still counts
  as before.
- Must keep the API cost small. The job list is one extra GitHub call per run
  read.
- Selftest must cover it and run in CI (`job-watchdog-test.yml`).

## Open questions

None.
