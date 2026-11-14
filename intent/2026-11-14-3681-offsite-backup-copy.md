---
status: draft
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
- it referenced a Secret (`offsite-s3-creds`) that did not exist, so it would
  have failed on every schedule and piled up Error pods.

It also only copied; nothing checked that the remote copy was readable or
matched the source. Nothing has tracked the gap since Factory#321 closed.

## Proposed outcome

- A CronJob in `apps/backups` copies the nightly dumps to an S3-compatible
  bucket outside the cluster's host, using an image already pinned in this repo.
- Each run proves the copy: the newest dump is read back from the destination
  and compared with the source, and the run fails if they differ. A failed or
  missing run surfaces through the existing `job-watchdog` (`job_health`
  stream and its GitHub issue).
- The change can merge before the destination exists: Argo CD syncs `backups`
  Healthy and no pod is created while the destination Secret is missing.
- The destination's endpoint, bucket and credentials live in one Secret the
  owner seeds out of band. The repo names the Secret and its keys only.
- `docs/restore.md` says how to enable the copy and how to restore from it.

## Affected users and systems

- factory-gitops `apps/backups` (Argo CD application `backups`, namespace
  `factory`) and `docs/restore.md`.
- `job-watchdog`: it will see one more CronJob in `factory`.
- The owner: picks the destination, seeds the Secret, enables the job.
- No change to `postgres-backup`, MinIO or any service.

## Constraints

- No secret values in git. The Secret is referenced by name only.
- No `kubectl apply`, no secret writes and no cluster changes by this task.
- Images must already be admitted in `factory` (pinned by digest; the Kyverno
  signature rules cover first-party `ghcr.io/olafkfreund/*` images).
- Must not delete anything at the destination: dumps the local 14-day
  lifecycle expires stay off-cluster under the destination's own retention.
- Dumps contain all data and role password hashes, so the transport must be TLS.
- Merge only if Argo CD syncs cleanly with the Secret absent.

## Open questions

- Which destination (owner's decision; a recommendation goes in the spec).
- Whether dumps should be encrypted client-side before they leave the host.
  This task doesn't add that; the spec records it as a risk.
- The issue also asks for a recorded restore from the off-cluster copy. That
  needs the destination to exist, so it stays open on Factory#3681 for the owner.
