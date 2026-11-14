---
status: approved
issue: 3681
author: olafkfreund
---

# Intent: off-cluster copy of the postgres backups (Factory#3681)

## Problem

`postgres-backup` (`apps/backups/manifests/manifests.yaml`) dumps the shared
Postgres every night into the `factory-backups` bucket of the in-cluster MinIO.
MinIO's volume and the database's volume are both `local-path` PVCs on the same
k3d node, on one physical host (Factory#321 restore-drill comment, 2026-08-10).
Losing that host loses the database and every backup together.
`docs/restore.md` ("Off-cluster follow-up") says so and calls the whole-bucket
loss case unrecoverable.

factory-gitops#70 added an `offsite-backup-mirror` CronJob and was closed for
two reasons recorded in its closing comment:

- there was no external S3 target, and
- it referenced a Secret (`offsite-s3-creds`) that did not exist, so every
  scheduled run would have failed to start (the closing comment says it "would
  have failed on every schedule and accumulated Error pods").

It also only copied; nothing checked that the remote copy was readable or
matched the source. Nothing has tracked the gap since Factory#321 closed.

## Proposed outcome

- A CronJob in `apps/backups` copies the nightly dumps to an S3-compatible
  bucket outside the cluster's host, using an image already pinned in this repo.
- Each run proves the copy, and fails if any of these is false: the newest
  source dump is recent (inside the 24h RPO plus slack) and not empty; the same
  object read back from the destination is byte-identical to the source; and it
  is a valid gzip. This proves the copy is current and intact. It does not prove
  a restore; that stays a drill (`docs/restore.md`).
- Once enabled, a failed or missing run surfaces through the existing
  `job-watchdog` (`job_health` stream and its GitHub issue).
- The change can merge before the destination exists. Acceptance criterion:
  with the Secret absent, Argo CD syncs `backups` Healthy, no pod is created,
  and `job-watchdog` raises nothing new. The watchdog reports a suspended
  CronJob as a warning and, after about two days without a success, as
  `never_succeeded` (critical, re-commented daily:
  `apps/job-watchdog/manifests/manifests.yaml`, `assess()`), so the spec must
  pick a mechanism that avoids that.
- The destination's endpoint, bucket and credentials live in one Secret the
  owner seeds out of band. The repo names the Secret and its keys only.
- `docs/restore.md` says how to enable the copy (a change in git, since Argo CD
  self-heals), what the destination must provide, and how to restore from it.

## Affected users and systems

- factory-gitops `apps/backups` (Argo CD application `backups`, namespace
  `factory`) and `docs/restore.md`.
- `job-watchdog`: it will see one more CronJob in `factory` once the copy is
  enabled.
- The owner: picks the destination, seeds the Secret, enables the job.
- No change to `postgres-backup`, MinIO or any service.

## Constraints

- No secret values in git. The Secret is referenced by name only.
- No `kubectl apply`, no secret writes and no cluster changes by this task.
- Use an image that already runs in `factory`, pinned by digest, such as the
  `cgr.dev/chainguard/minio-client` image `postgres-backup` uses. The Kyverno
  signature rules verify first-party `ghcr.io/olafkfreund/*` images only, so
  no new image and no policy change.
- Follow the CronJob conventions `postgres-backup` documents:
  `restartPolicy: Never`, `failedJobsHistoryLimit: 10`, no
  `ttlSecondsAfterFinished`, non-root, read-only root filesystem, all
  capabilities dropped, resource limits, bounded scratch.
- Read-only towards the source bucket.
- Must not delete anything at the destination: dumps the local 14-day
  lifecycle expires stay off-cluster under the destination's own retention.
- The destination needs its own retention, and that is a prerequisite for
  enabling, not something this job enforces.
- Dumps contain all data and role password hashes. The transport must be TLS
  (the job refuses a non-`https` endpoint). TLS doesn't protect the stored
  copy: the destination must be a private bucket, encrypted at rest, with a
  credential scoped to that bucket and ideally unable to delete or overwrite
  (versioning or object lock), so a compromised cluster can't wipe both copies.
- Merge only if Argo CD syncs cleanly with the Secret absent.

## Open questions

- Which destination (owner's decision; a recommendation goes in the spec).
- Whether dumps must be encrypted client-side before they leave the host
  (owner's decision). The spec says what this change does and what adding
  client-side encryption would take.
- `factory-artifacts` (evidence) has the same single-host exposure
  (`docs/restore.md`, "Off-cluster follow-up"). It is out of scope here and
  stays an open gap; the runbook must keep saying so.
- The issue also asks for a recorded restore from the off-cluster copy. That
  needs the destination to exist, so it stays open on Factory#3681 for the owner.
