---
status: approved
issue: 3681
spec: spec/2026-11-14-3681-offsite-backup-copy.md
coders:
  1: codex   # small tricky shell logic: timestamp parsing, freshness bounds, read-back compare
  2: codex   # the test of step 1; same agent so stub and script agree on the mc calls
  3: coder   # plain manifests copied from the sibling CronJob
  4: coder   # one small workflow
  5: coder   # prose in the runbook plus one comment
reviewers:
  - codex    # independent read of the diff against this plan
  - agy      # second independent read; often fails, carry on without it
---

# Plan: off-cluster copy of the postgres backups (Factory#3681)

## Approved decisions (from the spec)

- New directory `apps/backups/offsite/` with its own `kustomization.yaml`. It is
  **not** referenced from `apps/backups/manifests/kustomization.yaml`, so Argo
  CD deploys nothing and `job-watchdog` sees nothing until the owner enables it
  by adding `- ../offsite` there (after seeding the Secret). Do not add that
  line. Do not use `suspend: true`.
- CronJob `postgres-backup-offsite`, namespace `factory`, schedule `15 3 * * *`.
- Image, exactly: `cgr.dev/chainguard/minio-client:latest-dev@sha256:b056b795d31828015aea061e3168267b0ba80590ba2d8f869e72ff77153a68e8`
  (already used at `apps/backups/manifests/manifests.yaml:123`). No other image.
- Secrets by name only. Source: `minio-creds` keys `S3_ACCESS_KEY`,
  `S3_SECRET_KEY`. Destination: `offsite-s3-creds` keys `OFFSITE_S3_ENDPOINT`,
  `OFFSITE_S3_BUCKET`, `OFFSITE_S3_ACCESS_KEY`, `OFFSITE_S3_SECRET_KEY`. No
  `optional: true`. No secret values, example endpoints with real hosts are fine.
- The script is a real file, shipped by `configMapGenerator` as ConfigMap
  `postgres-backup-offsite-script` with `disableNameSuffixHash: true`.
- Never delete or overwrite at the destination; never write to the source.
- No client-side encryption. `factory-artifacts` is out of scope.

## Steps

1. `apps/backups/offsite/offsite-copy.sh` (new, mode 755, `#!/bin/sh`): the job
   script. Must run under the image's busybox `sh` and under `bash`; start with
   `set -euo pipefail`. Use only `mc`, `awk`, `sort`, `tail`, `cut`, `date`,
   `sha256sum`, `gzip`, `grep`, `wc`, `cat`. Use only these `mc` forms (the test
   stub implements exactly these): `mc alias set <alias> <url> <access> <secret>`,
   `mc ls <alias>/<path>/` (object name is the last field of each line),
   `mc mirror <alias>/<path>/ <alias>/<path>/`, `mc cat <alias>/<path>`.
   Inputs (env): `S3_ACCESS_KEY`, `S3_SECRET_KEY`, the four `OFFSITE_S3_*`;
   optional `SOURCE_ENDPOINT` (default
   `http://minio.factory.svc.cluster.local:9000`), `SCRATCH` (default
   `/scratch`), `MAX_AGE_SECONDS` (default `43200`). Behaviour, in order, every
   failure prints `offsite-copy: FAIL: <reason>` to stderr and exits 1:
   1. `OFFSITE_S3_ENDPOINT` must start with `https://`.
   2. `export MC_CONFIG_DIR="$SCRATCH/.mc"`; set alias `fac` (source) and `off`
      (destination); send alias output to `/dev/null` so keys never reach logs.
   3. Newest dump = last line of the sorted names matching
      `^factory-cluster-.*\.sql\.gz$` in `fac/factory-backups/postgres/`. None: fail.
   4. Timestamp = name without `factory-cluster-` and `.sql.gz`. It must match
      `YYYYMMDDTHHMMSSZ` (8 digits, `T`, 6 digits, `Z`; check with a `case`
      glob), else fail. Convert with
      `date -u -d "YYYY-MM-DD HH:MM:SS" +%s` (this form works in busybox and
      GNU date). `age = now - that`. Fail if `age < -300` (future-dated) or
      `age > MAX_AGE_SECONDS`.
   5. `mc mirror fac/factory-backups/postgres/ "off/$OFFSITE_S3_BUCKET/postgres/"`.
      No `--remove`, no `--overwrite`.
   6. `mc cat` the destination object to `$SCRATCH/readback.gz`. Fail if it is
      empty, if `gzip -t` fails, or if its sha256 differs from the sha256 of
      `mc cat` of the source object.
   7. Print `offsite-copy: OK name=<n> bytes=<b> sha256=<h> age_seconds=<a>`.
   Add one comment in the form
   `# shortcut: reads the whole newest dump back each night, fine at MB size; compare provider checksums when dumps reach GBs`
   and one line saying why the age limit must stay below 25h (this job runs 1h
   after the dump, so yesterday's dump is 25h old).
   → verify by `shellcheck -s busybox apps/backups/offsite/offsite-copy.sh`
   (no findings; the busybox dialect is needed because plain `sh` has no
   `pipefail`).
   Traps: the sibling job's comment at `apps/backups/manifests/manifests.yaml:83-93`:
   `pipefail` is load-bearing, and `dash` has none, so never run this with
   Debian `sh`. Do not `echo` any credential. Do not stage or commit.

2. `apps/backups/offsite/test.sh` (new, mode 755, `#!/bin/sh`): self-contained
   test for step 1, no network. It creates a temp dir, writes a stub `mc` there
   and puts it first on `PATH`. The stub maps `<alias>/<path>` to
   `$STUB_ROOT/<alias>/<path>` and implements the four forms in step 1 (`alias
   set` is a no-op; `mirror` copies files that do not exist at the target and
   never deletes). Each case builds source objects, runs
   `offsite-copy.sh` with `SCRATCH` in the temp dir, and checks the exit status
   and, for failures, that the reason is the expected one. Make dump names from
   epoch seconds with `date -u -d "@<epoch>" +%Y%m%dT%H%M%SZ`. Cases:
   happy path (dump 1h old: exit 0, object present at the destination, `OK`
   line printed); stale (newest dump 25h old); future-dated (2h ahead);
   unparsable name (`factory-cluster-garbage.sql.gz`); no dump; corrupt
   destination copy (pre-place a different valid gzip under the same name at
   the destination, which `mirror` will not replace); empty destination copy
   (pre-place a 0-byte object); invalid gzip (the newest "dump" is the same
   non-empty, non-gzip bytes at source and destination, so the hashes match and
   only `gzip -t` can fail it); `http://` endpoint; older dumps already at the
   destination are still there after a run. Ends with `test.sh: N passed` and
   exits non-zero if any case failed. A test that ran zero cases must fail.
   → verify by running it in the pinned image:
   `docker run --rm -v "$PWD/apps/backups/offsite:/t:ro" --entrypoint /bin/sh <image> /t/test.sh`
   and by `shellcheck -s busybox apps/backups/offsite/test.sh`.
   Traps: the mount is read-only, so write only under `mktemp -d`. The
   container user is uid 65532. Do not stage or commit.

3. `apps/backups/offsite/cronjob.yaml` and `apps/backups/offsite/kustomization.yaml`
   (new). `kustomization.yaml`: `namespace: factory`, `resources: [cronjob.yaml]`,
   `configMapGenerator` named `postgres-backup-offsite-script` with
   `files: [offsite-copy.sh]`, `generatorOptions: { disableNameSuffixHash: true }`.
   `cronjob.yaml`: copy the shape of `postgres-backup`
   (`apps/backups/manifests/manifests.yaml:27-155`) with one container and no
   initContainer: labels `app: postgres-backup-offsite`, `schedule: "15 3 * * *"`,
   `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`,
   `failedJobsHistoryLimit: 10`, `startingDeadlineSeconds: 600`,
   `backoffLimit: 2`, `activeDeadlineSeconds: 3600` (added after review: a hung
   transfer to the destination would otherwise block every later run under
   `Forbid`), no `ttlSecondsAfterFinished`, `restartPolicy: Never`,
   `enableServiceLinks: false`, `automountServiceAccountToken: false`, pod
   `securityContext` `runAsNonRoot: true`, `runAsUser: 65532`, `fsGroup: 65532`,
   `seccompProfile: RuntimeDefault`; container `command: ["/bin/sh", "/script/offsite-copy.sh"]`,
   the six env vars from the Secrets above, `allowPrivilegeEscalation: false`,
   `readOnlyRootFilesystem: true`, `capabilities: { drop: ["ALL"] }`, requests
   `cpu: 20m, memory: 64Mi`, limits `cpu: 200m, memory: 256Mi`; volumes
   `scratch` (`emptyDir: { sizeLimit: 5Gi }`, at `/scratch`) and `script` (the
   ConfigMap, `defaultMode: 0555`, at `/script`, read-only). A header comment
   says in a few lines: what it does, that it is NOT deployed until `../offsite`
   is added to `apps/backups/manifests/kustomization.yaml`, why not `suspend`
   (job-watchdog escalates a suspended never-run CronJob to critical), and the
   Secret name and keys. Short comments only; do not copy the sibling's
   post-mortem paragraphs.
   → verify by `kustomize build apps/backups/offsite` (one CronJob, one
   ConfigMap, both in `factory`) and
   `git diff --exit-code origin/main -- apps/backups/manifests/kustomization.yaml`.
   Traps: `manifest-validate.yml` schema-checks this directory because it has a
   `kustomization.yaml`. Do not stage or commit.

4. `.github/workflows/backup-offsite-test.yml` (new): name
   `backup offsite copy test`; triggers `pull_request`, `push` to `main`,
   `workflow_dispatch` (no `paths:` filter, as in `cred-sync-test.yml`);
   `permissions: contents: read`; one job, `ubuntu-latest`,
   `timeout-minutes: 10`; checkout with the same pinned action line as
   `cred-sync-test.yml`; one step that reads the image from `cronjob.yaml`
   (`grep -o 'cgr.dev/chainguard/minio-client[^ ]*'`, fail if it is empty) and
   runs the `docker run` command from step 2.
   → verify by `python3 .github/scripts/check_workflow_duplication.py` (run it
   the way `workflow-duplication.yml` does) and by reading the workflow run on
   the PR.
   Traps: actions are pinned by commit SHA in this repo; copy the checkout line,
   do not write a tag. Do not stage or commit.

5. `docs/restore.md` and `apps/backups/manifests/manifests.yaml:18-22`.
   In `docs/restore.md`: add the off-cluster copy to "What exists" (off until
   enabled); reword the first bullet of "Current gaps"; replace the section
   "Off-cluster follow-up (required to call this DR)" with "Off-cluster copy"
   covering: what the job does and verifies; destination requirements (private
   bucket, encryption at rest, versioning or object lock, a lifecycle rule,
   a key scoped to the bucket that can list, read and write but not delete);
   the recommendation (a bucket at an S3-compatible provider outside the house,
   in the EU, for example Backblaze B2 or Hetzner Object Storage, lifecycle
   about 90 days; a MinIO on p510 is the fallback, which leaves the cluster
   host but does not survive losing the site);
   the Secret `offsite-s3-creds` and its four keys (names only), seeded the way
   `docs/secrets-management.md` describes, and that the Secret then needs a row
   in that file's inventory and rotation ledger; the enable step (add
   `- ../offsite` to `apps/backups/manifests/kustomization.yaml` in a PR, only
   after the Secret exists, otherwise the pod sits in
   `CreateContainerConfigError`); how to check it (`kubectl -n factory logs
   job/<name>` shows the `offsite-copy: OK` line; `job_health` for
   `postgres-backup-offsite`); restoring from the copy (get the object from the
   destination with `mc`, then the existing "Restore: Postgres" steps from
   step 3 on); and what is still open: dumps are not encrypted client-side
   (the pinned image has no `openssl`, `gpg` or `age`; adding it means another
   image and a key that must be at hand during a restore; owner's decision),
   `factory-artifacts` has no off-cluster copy, and a restore from the
   off-cluster copy has not been drilled (Factory#3681). Update "Whole-bucket
   loss" under "Restore: MinIO objects" (Postgres dumps recoverable from the
   off-cluster copy once enabled; artifacts still not) and add one
   backup-verification checkbox for the off-cluster job. In `manifests.yaml`
   replace the "RESIDUAL DR GAP" comment's last sentence with a pointer to
   `apps/backups/offsite/` and that it is off until enabled. Comment change
   only: no YAML field in that file may change.
   → verify by `kustomize build apps/backups/manifests | sha256sum` equal to the
   same command on `origin/main`.
   Traps: do not touch `docs/secrets-management.md` (its ledger is checked by
   `secret-rotation-due.yml` and belongs to Factory#314). Leave the dead
   `quay.io/minio/mc` reference in "Restore: Postgres" alone; it is not this
   task. Do not stage or commit.

6. (lead) Run every check under Tests, review, commit, push, open the PR.

## Tests

- `shellcheck -s busybox apps/backups/offsite/*.sh`: clean.
- `docker run --rm -v "$PWD/apps/backups/offsite:/t:ro" --entrypoint /bin/sh <image> /t/test.sh`: all cases pass.
- `kustomize build apps/backups/offsite`: a CronJob and a ConfigMap.
- `kustomize build apps/backups/manifests | sha256sum` equals `origin/main`'s:
  Argo CD has nothing to sync.
- With `- ../offsite` added in a scratch copy (not committed),
  `kustomize build apps/backups/manifests` renders both objects.
- PR checks green, including `manifest validation (blocking)`.

## Rollback

Revert the merge commit. Nothing was deployed, so there is no cluster state to
undo. If the copy has been enabled: remove `- ../offsite` from
`apps/backups/manifests/kustomization.yaml`; Argo CD prunes the CronJob and the
ConfigMap. Objects already at the destination stay there.
