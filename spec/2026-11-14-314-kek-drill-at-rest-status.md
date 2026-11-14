---
status: draft
issue: 314
intent: intent/2026-11-14-314-kek-drill-at-rest-status.md
---

# Spec: at-rest status of record and a rehearsable KEK emergency procedure (Factory#314)

## Design

Four changes, three in factory-gitops and one in Factory. Nothing touches the
cluster, a Secret or nixos_config.

### D1. `docs/encryption-at-rest.md`: status of record

Replace the section "What is encrypted today: nothing at rest" with
"Status (verified 2026-11-14)": one table, one row per layer, with columns
Layer / State / How verified. Rows and states are the ones in the approved
intent: MinIO SSE (configured for new writes on three buckets; existing objects
not evidenced), KEK custody (documented; offline identity backup unconfirmed),
Postgres (unencrypted, risk-accepted R-014), other `local-path` volumes
(unencrypted, R-003 open), etcd Secrets (unencrypted, no `--secrets-encryption`),
node disk (no LUKS, owner check 2026-10-24), application-level keys
(`KMS_FERNET_KEY`, `CFACTORY_CREDENTIAL_KEY`: exist, see the rotation policy).

Below the table, one paragraph states the limit plainly: while etcd and the
disk are unencrypted, the KEK is on the same host as the ciphertext, so SSE
protects a copied bucket or PVC blob, not a seized host.

Mechanical corrections in the rest of the file: three buckets everywhere
(`factory-evidence` added), "shipped in this PR" becomes "shipped in
factory-gitops#71", and the storage path is given as p620
`/mnt/code/k3d/storage` with the note that it comes from the owner's host
check of 2026-10-24. The etcd and LUKS runbooks name p510 as the host to
deploy; those lines get a one-line note that the host must be confirmed, and
are otherwise left alone, because which host runs the bootstrap cannot be
verified from this repo.

Add the read-only commands that produced the "Live" evidence, so the table can
be re-verified, and the owner command that checks existing objects
(`mc stat` on a sample of old objects and versions per bucket).

### D2. `docs/encryption-at-rest.md`: numbered KEK emergency runbook

New section "KEK compromise: emergency re-encryption (UNTESTED)", replacing
"Rotating the KEK". The decisions:

- **Scope:** all three buckets. The bucket list in the runbook is the list the
  manifest encrypts.
- **Object versions are not carried over, and that is stated as a decision.**
  `mc mirror` copies current versions only. Before anything is deleted the
  operator lists every noncurrent version and delete marker
  (`mc ls --versions --recursive`) into the incident record, so what is given
  up (up to 7 days on `factory-backups`, 30 days of tamper-recovery history on
  `factory-evidence`) is recorded rather than silently lost.
- **Writers paused first:** the three factories' S3 writers, CronJob
  `postgres-backup` and CronJob `evidence-collector` (suspend, then wait for
  running Jobs to finish). The runbook names them; it does not change them.
- **Plaintext copy on encrypted or RAM-backed storage** (`tmpfs` or a LUKS
  volume), never on the plain node disk, because `shred` is not reliable on
  SSD/CoW filesystems.
- **Integrity check before the point of no return:** `mc diff` between each
  bucket and its copy must be empty, and object counts must match, before the
  buckets are emptied.
- **Rollback point:** up to and including the KEK swap, restoring the old
  `minio-kms` value and restarting MinIO returns to the starting state.
  Emptying the buckets (`mc rm --recursive --versions --force`) is the point of
  no return; after it the copy is the only data.
- **After mirror-back:** `mc diff` empty again, counts match, `mc stat` on a
  sample shows SSE-S3, a Postgres backup object is downloaded and `gunzip -t`
  passes, and the bucket settings are re-asserted by re-running the
  `minio-create-bucket` Job (ArgoCD sync of `minio`).
- **Old KEK retired last:** only after those checks pass and writers are back;
  then the copy is destroyed, the agenix value is replaced, and the ledger row
  for `minio-kms` is updated.
- **Rehearsal:** a short subsection says how to rehearse on a throwaway MinIO
  (a local container with its own KEK and dummy objects, including overwritten
  objects so versions exist), and gives the drill-record fields: date,
  operator, MinIO and mc versions, steps run, checks and results, time taken,
  open limitations. The section stays titled UNTESTED until a record is
  linked there.

`docs/secrets-management.md` then points at this runbook instead of carrying
its own copy: the rotation-policy cell for `minio-kms` is shortened to
"compromise only; emergency path (untested) in
`encryption-at-rest.md#kek-compromise-emergency-re-encryption-untested`", the
inventory row drops "new, this PR" and "minio bucket-init" (the Job uses only
`minio-creds`), and "the new secret this PR introduces" is reworded.

### D3. `scripts/minio-kek-drill.py`: print-only rehearsal aid

A Python script in the style of `scripts/rotation-ledger-check.py` (standard
library only, `--self-test`).

- `minio-kek-drill.py [--alias NAME]` prints the runbook's steps as numbered
  shell commands for that `mc` alias (default `drill`), one block per step,
  for all three buckets, with the stop conditions as comments.
  `--alias` is validated against `[A-Za-z0-9_-]+`.
- It has no option that executes anything. It imports no `subprocess`, `os`
  process functions, `socket` or HTTP module, reads no environment variable and
  no file except, in `--self-test`, the MinIO manifest. Key values appear only
  as the placeholders `<OLD_KEK>` and `<NEW_KEK>`.
- `--self-test` asserts: (a) the script's bucket list equals the set of
  buckets in `mc encrypt set sse-s3 fac/<bucket>` lines of
  `apps/minio/manifests/manifests.yaml`; (b) the printed plan has the
  destructive step after the integrity check and before the mirror-back, and
  retires the old KEK last; (c) the script's own source contains none of the
  forbidden imports; (d) a bad `--alias` is rejected.
- The runbook in D2 is the readable source; the script exists so the commands
  for a given alias are copy-exact and so (a) is machine-checked. The runbook
  says to generate the commands with the script rather than retyping them.

### D4. CI

`.github/workflows/secret-rotation-due.yml` gets one step,
`python3 scripts/minio-kek-drill.py --self-test`, and three more `paths:`
entries (`scripts/minio-kek-drill.py`, `apps/minio/manifests/manifests.yaml`,
`docs/encryption-at-rest.md`). No new workflow.

### D5. Factory `docs/compliance/policies/encryption-key-mgmt.md`

A dated "Status update 2026-11-14" block under "Current state", and edits to
the lines that are now false: the MinIO paragraph ("started with no
server-side encryption"), "Net: no data-at-rest encryption exists on any
store", "No key-management system ... no KMS resource", and gaps 2, 6 and 7.
Gaps are annotated, not deleted: 2 "partly closed: SSE-S3 on three buckets,
existing-object coverage not evidenced, emergency re-encryption untested";
6 "closed for agenix custody (documented), offline identity backup
unconfirmed"; 7 "policy and overdue check in place, rotation itself manual".
No acceptance-criteria checkbox is ticked: each still lacks part of its
evidence, and the note next to it says which part. Separate PR in Factory,
opened after the factory-gitops PR merges so its links resolve.

## Alternatives rejected

- **A script with a real `--execute` mode guarded by flags.** One wrong
  context and it empties the evidence bucket. The owner's instruction is
  dry-run only.
- **Preserve versions by replicating to a second MinIO with a new KEK and
  cutting over.** It keeps history, but it needs a second MinIO, replication
  setup and a service cutover: more to go wrong in an emergency on a
  single-node cluster. Recorded as the path to take with KES.
- **Run the rehearsal on a local throwaway MinIO in this change.** It would
  give a first drill record, but the instruction for this round is a script
  that only prints, and a drill record should name a human operator.
- **Add an `mc encrypt info` read-back assertion to the bucket Job.** Worth
  doing, but the exact output of the pinned `mc` build cannot be confirmed
  without running it, and a wrong match fails the PostSync hook on the live
  cluster. Listed as a follow-up.
- **Bash for the script.** The repo's existing checker is Python with a
  self-test; a second style buys nothing.
- **A new workflow file.** The existing rotation workflow already covers
  these docs.
- **Tick the policy checkboxes that are "mostly" met.** An assessor tests the
  whole sentence.

## Risks

- The runbook is still untested when this merges. A wrong `mc` flag in it
  would surface only in a rehearsal. Mitigation: the title says UNTESTED, the
  rehearsal is the first owner action, and the reviewers check each command
  against `mc` documentation.
- `mc rm --recursive --versions --force` is in a document. Mitigation: it is
  printed for a named alias, default `drill`, never run by anything here.
- The host statements (p510 vs p620) stay partly unverified; the doc says so.
- No runtime risk: docs, one script that only prints, one CI step.

## Verification

- `python3 scripts/minio-kek-drill.py --self-test` passes; changing the bucket
  list in a copy of the manifest makes it fail.
- `python3 scripts/minio-kek-drill.py` prints all three buckets and exits 0;
  `--alias 'a;b'` exits non-zero.
- `python3 scripts/rotation-ledger-check.py --validate-only docs/secrets-management.md`
  still passes (the ledger block is untouched).
- `grep -n 'nothing at rest\|this PR\|both buckets' docs/encryption-at-rest.md docs/secrets-management.md`
  returns nothing.
- Every relative link and anchor added resolves (checked by hand; mkdocs build
  if the repo's CI runs one).
- CI on the PR is green.
