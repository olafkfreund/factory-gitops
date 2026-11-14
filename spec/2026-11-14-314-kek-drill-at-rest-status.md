---
status: approved
issue: 314
intent: intent/2026-11-14-314-kek-drill-at-rest-status.md
---

# Spec: at-rest status of record and a rehearsable KEK emergency procedure (Factory#314)

## Design

Five changes in factory-gitops, one in Factory, one comment on the epic.
Nothing touches the cluster, a Secret or nixos_config.

### D1. `docs/encryption-at-rest.md`: status of record

Replace the section "What is encrypted today: nothing at rest" with
"Status as of 2026-11-14": one table, one row per layer, with columns
Layer / State / Evidence. Every evidence cell starts with its kind and date,
as in the approved intent: **Live** (read-only `kubectl get/describe`,
2026-11-14), **Repo** (a file here), or **Record** (an issue, PR or risk entry
this repo cannot re-verify, with its own date). The heading does not say
"verified".

Rows: MinIO SSE (configured for new writes on three buckets; existing objects
and versions not evidenced); KEK custody (documented; agenix copy and offline
identity backup are Record/unconfirmed); key-rotation policy and ledger (Repo);
Postgres (unencrypted, risk-accepted R-014, Record); other `local-path` volumes
(unencrypted, R-003 open); etcd Secrets (unencrypted: no `--secrets-encryption`
in the server node args, Live); node disk (no LUKS: owner host check
2026-10-24, Record); application-level keys (`KMS_FERNET_KEY`,
`CFACTORY_CREDENTIAL_KEY`: documented in the rotation policy, not checked
live); FIPS 140 (nothing asserted; owner decision); KES / external KMS (not
deployed; MinIO uses its built-in static single-key mode).

Below the table, one paragraph states the limit plainly: while etcd and the
disk are unencrypted, the KEK is on the same host as the ciphertext, so SSE
protects a copied bucket or PVC blob, not a seized host.

Then two short lists: the read-only commands that produced the Live rows, and
the owner checks still open (the full list in D6). The existing-object check
is a full enumeration (`mc stat --versions --recursive --json` over each
bucket, delete markers excluded), not a sample.

Mechanical corrections in the rest of the file: three buckets everywhere;
"shipped in this PR" becomes a neutral "shipped" with links to
factory-gitops#71 only where the text is about the two original buckets; the
storage path is given as p620 `/mnt/code/k3d/storage` and labelled as the
owner's host check of 2026-10-24. The etcd and LUKS runbooks get, as their
first step, "confirm which host runs the cluster and the secret bootstrap";
their `p510` commands are marked as examples until then.

### D2. `docs/encryption-at-rest.md`: KEK emergency runbook

New section "KEK compromise: emergency re-encryption (UNTESTED)", replacing
"Rotating the KEK". The design is a **cutover to a fresh volume**: MinIO is
never started with a new KEK on top of data written under the old one, and
nothing is deleted until the end.

Decisions, in runbook order:

1. **Prepare the new KEK first.** If the compromise came through an agenix
   identity, remove that recipient and re-key before anything else
   (`secrets-management.md`, custody section). Generate the new KEK with a
   **new key name** (`factory-kek-2:...`), store it in agenix beside the old
   one, and confirm it decrypts. Key values are only ever handled through
   agenix and a file under `/dev/shm` fed to `kubectl patch`, never typed
   into a command line.
2. **Quiesce.** Pause ArgoCD auto-sync for `minio` and every app that writes
   to S3 (they have `selfHeal`), pause the KEDA scalers, scale the S3 writers
   to zero and suspend CronJobs `postgres-backup` and `evidence-collector`;
   wait for running Jobs to end. The runbook says to find every writer with
   `grep -rln 'factory-artifacts\|factory-backups\|factory-evidence' apps/`
   rather than trusting a fixed list. Lifecycle expiry keeps running inside
   MinIO; objects it removes during the window were already due to expire.
3. **Export under the old KEK** to persistent encrypted staging (a LUKS
   volume with room for the data; not `tmpfs`, which a reboot would empty,
   and not the plain node disk). Exported per bucket: current objects
   (`mc mirror`); every noncurrent version, each to a path that carries its
   version id; an inventory of versions and delete markers; and the object
   tags, because the `factory-artifacts` lifecycle rules filter on the `role`
   tag and a filesystem copy does not keep tags.
4. **Verify the export by content.** A SHA-256 manifest of the staged files
   must equal a SHA-256 manifest computed from a second, independent read of
   every object from MinIO (`mc cat | sha256sum`). `mc diff` is not used as
   evidence: it compares names and sizes. Any difference stops the procedure.
5. **Cut over.** Scale MinIO to zero. Leave the old PVC untouched. Point the
   Deployment at a new, empty PVC, set `minio-kms` to the new KEK, start
   MinIO, and confirm the key in use is the new key name
   (`mc admin kms key status`). Run the `minio-create-bucket` Job **before**
   restoring, so encryption, versioning and lifecycle are in force for every
   restored object.
6. **Restore and verify.** Mirror the current objects back, re-apply the tags
   from the inventory, and recompute the SHA-256 manifest from the new MinIO;
   it must equal the staged manifest. The newest Postgres backup passes
   `gunzip -t`. Restart MinIO once more and repeat the read check on a sample,
   which proves the running pod really holds the new key.
7. **Resume** writers, KEDA and ArgoCD sync.
8. **Retire, last and separately.** After a soak period the owner sets
   (suggested: one successful nightly backup and one evidence run), delete the
   old PVC, remove the old KEK from agenix and update the `minio-kms` ledger
   row. The staged noncurrent versions of `factory-backups` (7 days) and
   `factory-evidence` (30 days) stay on the encrypted staging volume until
   their retention would have expired, then the staging volume is destroyed.

Stated properties:

- **Rollback** is available through step 7: scale MinIO down, point it back
  at the old PVC with the old KEK. The point of no return is deleting the old
  PVC in step 8, not a step in the middle.
- **No backup or evidence data is lost.** Current objects are restored and
  verified by checksum. Noncurrent versions are preserved in the staging
  archive for their retention period; they are not restored into the bucket,
  so in-bucket version history restarts. The runbook says this in one
  sentence so it is a decision, not a surprise.
- **Cost:** downtime for every S3 consumer, and disk for the old PVC, the new
  PVC and the staging copy at once.
- **Unproven assumptions**, listed in the runbook as things the rehearsal must
  settle before it can lose the UNTESTED label: the exact `mc` flags for
  exporting versions and tags on the pinned image; that `mc admin kms key
  status` reports the key name in single-key mode; how the PVC switch is done
  under ArgoCD (a manifest PR versus a paused-sync patch).

**Rehearsal** subsection: how to rehearse on a throwaway MinIO (a local
container at the pinned digest with its own KEK, dummy objects, overwritten
objects so versions exist, tagged objects), and the drill-record fields:
date, operator, MinIO and mc versions, steps run, each check and its result,
time taken, deviations, open limitations. The section keeps UNTESTED in its
title until a record is linked there.

`docs/secrets-management.md` then points at this runbook instead of carrying
its own copy. The rotation-policy cell for `minio-kms` becomes "compromise
only; emergency path (untested) in `encryption-at-rest.md`". The inventory row
drops "new, this PR" and "minio bucket-init" (the Job uses only
`minio-creds`). The ESO section's "two consumers", "brand new" and "the new
secret this PR introduces" are corrected. The comment in
`apps/minio/manifests/manifests.yaml` line 31 ("the minio pod and the Job both
reference it") is corrected to the pod only; no other manifest change.

### D3. `scripts/minio-kek-drill.py`: print-only rehearsal aid

A Python script in the style of `scripts/rotation-ledger-check.py` (standard
library only, `--self-test`). It covers only the data steps (3, 4 and 6):
the ones with many per-bucket commands, where retyping causes mistakes.

- `minio-kek-drill.py [--alias NAME] [--staging DIR]` prints a bash fragment
  per step for all three buckets. Each fragment starts with
  `set -euo pipefail` and its gates fail closed (a checksum mismatch is a
  failing command, not a comment).
- It prints **no `kubectl` command, no key placeholder and no command that
  deletes bucket data.** The cluster steps (1, 2, 5, 7, 8) are prose in the
  runbook, so a rehearsal on a local container cannot paste a live-cluster
  command from this script.
- `--alias` must match `^[A-Za-z][A-Za-z0-9_]*$` (default `drill`);
  `--staging` must be an absolute path without shell metacharacters (default
  `/mnt/kek-staging`).
- It has no option that executes anything. Its imports are limited to
  `argparse`, `ast`, `pathlib`, `re`, `sys`. It reads no environment variable.
  It opens files only in `--self-test`: its own source, the MinIO manifest and
  `docs/encryption-at-rest.md`.
- `--self-test` asserts, with in-memory mutation cases in the style of the
  ledger checker:
  (a) the script's bucket list equals the buckets the manifest creates
  (`mc mb`) and equals the buckets it encrypts (`mc encrypt set sse-s3`), so a
  bucket that is created but not encrypted fails too;
  (b) each of those buckets is named in the runbook section of
  `docs/encryption-at-rest.md`;
  (c) every bucket appears in every per-bucket step, and the steps come out in
  the order export, verify export, restore, verify restore;
  (d) the printed plan contains no `kubectl`, no `mc rm`, no `mc rb` and no
  `KEK`;
  (e) the script's imports, read with `ast`, are within the allowlist;
  (f) bad `--alias` and `--staging` values are rejected.

What the self-test does not prove, and the runbook says so: that the commands
are right for the pinned `mc`. Only the rehearsal does.

### D4. CI

`.github/workflows/secret-rotation-due.yml` gets one step,
`python3 scripts/minio-kek-drill.py --self-test`, placed before "Check the
ledger" so an overdue ledger row on the weekly run does not skip it, and three
more `paths:` entries (`scripts/minio-kek-drill.py`,
`apps/minio/manifests/manifests.yaml`, `docs/encryption-at-rest.md`). No new
workflow.

### D5. Factory `docs/compliance/policies/encryption-key-mgmt.md`

A dated "Status update 2026-11-14" block under "Current state", using the same
Live / Repo / Record labels, and corrections to the sentences that no longer
describe the system:

- MinIO: SSE-S3 is configured on three buckets with MinIO's built-in static
  single-key mode. This is **not** a KMS service; "no key-management system"
  stays true and is reworded to say exactly that.
- "Net: no data-at-rest encryption exists on any store" becomes: object
  content in MinIO is encrypted for new writes; every volume and etcd are not.
- Gaps are annotated, not deleted: gap 2 "partly addressed: SSE-S3 configured,
  existing-object coverage not evidenced, emergency re-encryption untested";
  gap 6 "partly addressed: agenix custody is documented in factory-gitops;
  offline identity backup and bootstrap host unconfirmed; no dual control";
  gap 7 "partly addressed: rotation policy and overdue check exist; rotation
  is manual".
- No acceptance-criteria checkbox is ticked; each gets a note saying which
  part of its evidence is missing.

Separate PR in Factory, opened after the factory-gitops PR merges so that its
links to the docs and to these three artifacts resolve.

### D6. Comment on Factory#314

One comment with the status table and the owner actions, each one line:
enable k3s `--secrets-encryption`; rehearse the KEK runbook and file the drill
record; confirm an offline backup of a decrypting identity; confirm which host
runs the secret bootstrap; run the existing-object encryption check; decide on
Redis/Keycloak volumes (risk acceptance or node LUKS); decide on FIPS 140
scope; decide on KES. The epic stays open.

## Alternatives rejected

- **In-place swap: empty the buckets, change the KEK, mirror back** (the path
  in the current doc, and the first draft of this spec). Both reviewers
  showed it has a window where the staging copy is the only data, and that
  MinIO started with a new key over old-key data may not start or list at
  all. The fresh-volume cutover removes both.
- **A second MinIO running in parallel with bucket replication.** Keeps
  versions and tags natively and needs no plaintext staging, but adds a second
  service, replication setup and a client cutover in the middle of an
  incident. Recorded as the better path once KES exists.
- **A script with a real `--execute` mode guarded by flags.** The owner's
  instruction is dry-run only, and one wrong context is too expensive.
- **Run the rehearsal on a local throwaway MinIO in this change.** The
  instruction for this round is a script that only prints, and a drill record
  should name a human operator.
- **Add an `mc encrypt info` read-back assertion to the bucket Job.** Worth
  doing, but the output of the pinned `mc` cannot be confirmed without
  running it, and a wrong match fails the PostSync hook on the live cluster.
  Follow-up.
- **Bash for the script; a new workflow file.** The repo already has a Python
  checker with a self-test and a workflow that covers these docs.
- **Tick the policy checkboxes that are "mostly" met.** An assessor tests the
  whole sentence.

## Risks

- The runbook is untested when this merges, and three of its assumptions are
  listed as unproven. Mitigation: the title says UNTESTED, the rehearsal is
  the first owner action, and the old PVC is kept until the end, so a wrong
  command costs downtime, not data.
- Commands printed by the script can still be pasted against the wrong alias.
  Mitigation: it prints nothing that deletes bucket data and no cluster
  command; the worst case is an unwanted read or an upload into a bucket.
- Staging holds plaintext. Mitigation: LUKS volume, destroyed at the end.
- The host statements (p510 or p620) stay unconfirmed; the docs say so.
- Runtime risk of this change itself: none beyond a comment edit in the MinIO
  manifest, which does not alter the rendered resources.

## Verification

- `python3 scripts/minio-kek-drill.py --self-test` passes, including its
  mutation cases (a manifest with a bucket created but not encrypted, a
  runbook missing a bucket, a forbidden import, a plan containing `mc rm`).
- `python3 scripts/minio-kek-drill.py` exits 0 and its output names all three
  buckets; `--alias=-rf` and `--alias 'a;b'` exit non-zero.
- `bash -n` accepts the printed fragments.
- `python3 scripts/rotation-ledger-check.py --validate-only docs/secrets-management.md`
  still passes.
- `grep -n 'nothing at rest\|this PR\|both buckets\|two consumers\|brand new\|both reference'`
  over the two docs and the MinIO manifest returns nothing, and every
  remaining `/mnt/img_pool` or two-bucket mention has been reviewed by hand.
- `kustomize build apps/minio/manifests` output is unchanged against `main`.
- Added links and anchors resolve; CI on both PRs is green.
