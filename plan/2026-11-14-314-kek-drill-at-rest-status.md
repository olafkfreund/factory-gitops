---
status: approved
issue: 314
spec: spec/2026-11-14-314-kek-drill-at-rest-status.md
coders:
  1: codex   # small, tricky logic: a print-only generator with a mutation self-test
  2: coder   # prose rewrite of one doc against a fixed list of decisions
  3: coder   # small doc and comment corrections in the same area as step 2
  4: coder   # one workflow step and three path entries
  5: coder   # prose edits to one policy file in the Factory repo
reviewers:
  - codex    # checks the mc commands and the self-test logic
  - agy      # checks the docs against the manifest and for unsupported claims
---

# Plan: at-rest status of record and a rehearsable KEK emergency procedure (Factory#314)

Docs, one print-only script and one CI step. No cluster, Secret or
nixos_config change. Nothing in this plan runs `kubectl` writes or `mc`.

Repos and branches:

- factory-gitops, branch `docs/314-kek-drill-at-rest-status`, base `main`
  (steps 1 to 4, one PR).
- Factory, branch `docs/314-encryption-policy-status`, base `main` (step 5,
  second PR, opened after the first merges).

## Approved decisions (copied from the spec)

**Evidence labels.** Every status statement carries its kind and date:
**Live** (read-only `kubectl get/describe` on context `k3d-factory`,
2026-11-14), **Repo** (a file in the repo), **Record** (an issue, PR or risk
entry the repo cannot re-verify, with its own date). No heading says
"verified".

**Status rows** (state; evidence):

| Layer | State | Evidence |
|---|---|---|
| MinIO SSE-S3 | Configured for new writes on `factory-artifacts`, `factory-backups`, `factory-evidence`. Existing objects and versions not evidenced. | Live: Deployment `minio` takes `MINIO_KMS_SECRET_KEY` from Secret `minio-kms`; Job `minio-create-bucket` succeeded 2026-10-22. Repo: `apps/minio/manifests/manifests.yaml` (`mc encrypt set sse-s3` on the three buckets). |
| KEK custody | Documented. Agenix copy and offline identity backup unconfirmed. | Record: owner comment on Factory#314, 2026-07-25. Repo: `docs/secrets-management.md`, custody section. |
| Key-rotation policy and ledger | In place; rotation is manual. | Repo: `docs/secrets-management.md`, `scripts/rotation-ledger-check.py`, `.github/workflows/secret-rotation-due.yml`. |
| Postgres | Unencrypted, risk accepted. | Record: R-014, review 2027-04-24 (Factory#3653). Live: PVC `data-postgres-0` on `local-path`. |
| Other `local-path` volumes (Redis, Keycloak, service data) | Unencrypted. | Live: all PVCs on `local-path`. Record: R-003, open. |
| etcd Secrets | Unencrypted. | Live: server node `k3s.io/node-args` has no `--secrets-encryption`. |
| Node disk | No LUKS. | Record: owner host check 2026-10-24 (p620, `/mnt/code/k3d/storage` on `/dev/sdb1` ext4). |
| Application-level keys | `KMS_FERNET_KEY` (aifactory), `CFACTORY_CREDENTIAL_KEY` (cfactory) documented; not checked live. | Repo: rotation policy in `docs/secrets-management.md`. |
| FIPS 140 | Nothing asserted. Owner decision. | Record: Factory#314 scopes it to FedRAMP. |
| KES / external KMS | Not deployed. MinIO uses its built-in static single-key mode. | Repo: MinIO manifest. |

**Limit to state under the table:** while etcd and the disk are unencrypted,
the KEK is on the same host as the ciphertext, so SSE protects a copied bucket
or PVC blob, not a seized host.

**KEK emergency runbook: cutover to a fresh volume.** MinIO is never started
with a new KEK over data written under the old one, and nothing is deleted
until the end. Steps:

1. Prepare the new KEK first. If the compromise came through an agenix
   identity, remove that recipient and re-key first. New KEK with a new key
   name (`factory-kek-2:<base64 32 bytes>`), stored in agenix beside the old
   one, decrypt confirmed. Key values go only through agenix and a file under
   `/dev/shm` fed to `kubectl patch`; never on a command line.
2. Quiesce. Pause ArgoCD auto-sync for `minio` and every S3-writing app (they
   have `selfHeal`), pause the KEDA scalers, scale S3 writers to zero, suspend
   CronJobs `postgres-backup` and `evidence-collector`, wait for running Jobs.
   Find writers with
   `grep -rln 'factory-artifacts\|factory-backups\|factory-evidence' apps/`.
   Lifecycle expiry keeps running; what it removes was due to expire.
3. Export under the old KEK to persistent encrypted staging (a LUKS volume;
   not `tmpfs`, not the plain node disk). Per bucket: current objects
   (`mc mirror`); every noncurrent version to a path carrying its version id;
   an inventory of versions and delete markers; the object tags (the
   `factory-artifacts` lifecycle rules filter on the `role` tag).
4. Verify the export by content, for current objects and for noncurrent
   versions separately: a SHA-256 manifest of the staged files equals a
   SHA-256 manifest from a second independent read from MinIO
   (`mc cat | sha256sum`; for noncurrent versions `mc cat --version-id`, with
   the version id in each manifest line). `mc diff` is not evidence. Any
   difference stops.
5. Cut over. Scale MinIO to zero. Old PVC untouched. Deployment on a new empty
   PVC, `minio-kms` set to the new KEK, start, confirm the key in use is the
   new key name (`mc admin kms key status`). Run `minio-create-bucket`
   **before** restoring.
6. Restore and verify. Mirror current objects back, re-apply tags, recompute
   the SHA-256 manifest from the new MinIO: equal to the staged one. Newest
   Postgres backup passes `gunzip -t`. Restart MinIO once more and repeat the
   read check on a sample.
7. Resume writers, KEDA, ArgoCD sync.
8. Retire, last and separately, after a soak the owner sets (suggested: one
   good nightly backup and one evidence run): delete the old PVC, remove the
   old KEK from agenix, update the `minio-kms` ledger row. Staged noncurrent
   versions stay on the staging volume until their retention would have
   expired (`factory-backups` 7 days, `factory-evidence` 30 days), then the
   volume is destroyed.

Properties to state: rollback without data loss is available through step 6
(old PVC + old KEK, writers still paused). After writers resume in step 7,
going back to the old PVC loses whatever was written since, so from step 7 on
rollback is a decision with a stated loss. Deleting the old PVC in step 8 ends
the rollback option altogether. No backup or
evidence data is lost: current objects restored and checksum-verified,
noncurrent versions kept in the staging archive, in-bucket version history
restarts. Cost: downtime for all S3 consumers; disk for old PVC, new PVC and
staging at once. Unproven, to be settled by rehearsal: exact `mc` flags for
exporting versions and tags on the pinned image; that `mc admin kms key
status` reports the key name in single-key mode; how the PVC switch is done
under ArgoCD.

**Script.** Print-only, covers only the data steps 3, 4 and 6. Prints no
`kubectl`, no key placeholder, nothing that deletes bucket data. No execute
option.

## Steps

1. **New file `scripts/minio-kek-drill.py`** (coder: codex) → verify by
   `python3 scripts/minio-kek-drill.py > /tmp/plan.sh && bash -n /tmp/plan.sh`
   (both exit 0) and `python3 scripts/minio-kek-drill.py --alias=-rf` (exits
   non-zero). `--self-test` is expected to fail on assertion (b) only until
   step 2 is done; it is the verification of step 2. Steps 1 and 2 may run in
   parallel.
   - Style: follow `scripts/rotation-ledger-check.py` (shebang, docstring,
     `argparse`, a `self_test()` with in-memory cases, `main()` returning an
     exit code). Mark it executable like that file (`git ls-files -s scripts/`
     shows the mode to match).
   - `BUCKETS = ("factory-artifacts", "factory-backups", "factory-evidence")`.
   - Arguments: `--alias` (default `drill`, must fully match
     `[A-Za-z][A-Za-z0-9_]*`), `--staging` (default `/mnt/kek-staging`, must
     fully match `/[A-Za-z0-9._/-]+` and contain no `..`), `--self-test`.
   - Output: four bash fragments in this order, each headed by a comment line
     `# step N: <name>` and starting with `set -euo pipefail`:
     step 3 export, step 4 verify export, step 6a restore, step 6b verify
     restore. Every fragment has one block per bucket. Gates are commands that
     fail (for example `cmp` of two manifest files), never comments.
     Step 3 per bucket: `mc mirror` of current objects into
     `<staging>/current/<bucket>`; a versions-and-delete-markers inventory
     (`mc ls --versions --recursive --json`) into
     `<staging>/inventory/<bucket>.versions.json`; export of each noncurrent
     version to `<staging>/noncurrent/<bucket>/<version-id>/<key>`; tags into
     `<staging>/inventory/<bucket>.tags.json`. Where the exact `mc` flag is
     one of the unproven assumptions, emit the best-known command and a
     `# UNPROVEN: settle in rehearsal` comment on the line above it.
     Step 4: two comparisons per bucket. Current objects: a sorted
     `sha256  key` manifest of `<staging>/current/<bucket>` against one built
     from `mc cat` of every current object; `cmp` them. Noncurrent versions: a
     sorted `sha256  version-id  key` manifest of
     `<staging>/noncurrent/<bucket>` against one built from
     `mc cat --version-id`; `cmp` them. Step 6b: the current-object comparison
     again, against the new MinIO.
     Object keys: the first command of step 3 for each bucket lists every key
     and **stops** (non-zero exit) if any key contains a newline, a `..` path
     component, a leading `/` or a trailing `/`. The fragments do not try to
     encode such keys; the runbook says to handle them by hand. All loops read
     keys with `while IFS= read -r` and quote every expansion.
     Step 6a: `mc mirror` from `<staging>/current/<bucket>` into the bucket,
     then re-apply tags from the inventory.
   - Imports only `argparse`, `ast`, `pathlib`, `re`, `sys`. No environment
     access. Files are opened only inside `self_test()`: the script's own
     source, `apps/minio/manifests/manifests.yaml`, `docs/encryption-at-rest.md`
     (paths resolved from the script's location).
   - `self_test()` asserts, with a failing mutation for each:
     (a) `set(BUCKETS)` equals the buckets in `mc mb --ignore-existing fac/<b>`
     lines and equals the buckets in `mc encrypt set sse-s3 fac/<b>` lines of
     the manifest; the lines are indented (manifest lines 237, 241, 246 and
     258-260), and each extracted set must be non-empty (mutations: a manifest
     text with a fourth `mc mb` bucket; a manifest text with no match at all);
     (b) each bucket name occurs in the text of `docs/encryption-at-rest.md`
     between the heading containing `KEK compromise` and the next heading of
     the same or a higher level (mutation: a doc text with one bucket removed
     from that section only, still present in the sections around it);
     (c) each bucket occurs in each of the four fragments, and the fragments
     are in the order above;
     (d) the plan printed with the default arguments, and with a valid
     non-default pair (`--alias lab2 --staging /srv/stage_1`), contains none of
     `kubectl`, `mc rm`, `mc rb`, `MINIO_KMS`, `<OLD` or `<NEW`;
     (e) the imports, read with `ast.parse` of the script's source, are a
     subset of the allowlist (mutation: source text with `import subprocess`);
     (f) `-rf`, `a;b` and an empty string are rejected as alias; `relative`,
     `/a/../b` and `/a;b` are rejected as staging.
   Traps: (b) fails until step 2 has added the runbook section; every other
   assertion must pass on its own. Never run `mc` or `kubectl`. Do not add a `--execute`
   or `--run` flag. Do not stage or commit.

2. **`docs/encryption-at-rest.md`** (coder: coder) → verify by
   `grep -n 'nothing at rest\|this PR' docs/encryption-at-rest.md` (no
   output, exit 1) and `python3 scripts/minio-kek-drill.py --self-test` (exit 0, once step 1
   exists).
   - Lines 6-26 ("What is encrypted today: nothing at rest"): replace with
     "## Status as of 2026-11-14": the status table above (same rows, states
     and evidence labels), the limit paragraph, a "How the Live rows were
     checked" list with the read-only commands
     (`kubectl -n factory describe deploy minio`,
     `kubectl -n factory describe job minio-create-bucket`,
     `kubectl -n factory get pvc`, `kubectl get storageclass`,
     `kubectl get node -o jsonpath='{.items[*].metadata.annotations.k3s\.io/node-args}'`),
     and an "Open owner checks" list (same items as step 6 below). The
     existing-object check is a full enumeration:
     `mc stat --versions --recursive --json` over each bucket, delete markers
     excluded, every entry must show SSE-S3.
   - Lines 37-51 (layers table and the paragraph after it) and 53-70: three
     buckets; "shipped in this PR" becomes "shipped" (link factory-gitops#71
     where the sentence is about the first two buckets). Line 86: drop "on
     p510" (say "agenix in nixos_config").
   - Lines 92-102 ("Rotating the KEK"): replace with
     "### KEK compromise: emergency re-encryption (UNTESTED)" containing the
     eight numbered steps, the properties, the unproven assumptions, a line
     saying the per-bucket commands for steps 3, 4 and 6 come from
     `python3 scripts/minio-kek-drill.py --alias <alias> --staging <dir>` and
     must not be retyped, and a "Rehearsal and drill record" subsection: a
     throwaway MinIO (local container at the digest pinned in
     `apps/minio/manifests/manifests.yaml`, its own KEK, dummy objects,
     overwritten objects, tagged objects), and the record fields: date,
     operator, MinIO and mc versions, steps run, each check and its result,
     time taken, deviations, open limitations. State that the section keeps
     UNTESTED in its title until a drill record is linked there. Name all
     three buckets inside this `###` section itself (the self-test in step
     1(b) reads only this section, up to the next `###` or `##`), so put the
     rehearsal text under `####` headings or plain bold labels, not a new
     `###`. State the rollback boundary as in the decisions above, and that
     object keys the script refuses must be handled by hand.
   - Lines 104-111 ("Verifying it is on"): add `factory-evidence`.
   - Sections 2 and 3 (lines 124-261): add as the first step of each "confirm
     which host runs the cluster and the secret bootstrap (the storage was
     found on p620 on 2026-10-24; these commands were written for p510)", and
     at line 204 (prose) change `/mnt/img_pool/k3d/storage` on p510 to "the
     local-path storage directory (`/mnt/code/k3d/storage` on p620 per the
     2026-10-24 host check)". Lines 224 (a `mount` command) and 230 (a Nix
     attribute) are code: replace only the path string with
     `/mnt/code/k3d/storage` so they stay valid. Lines 207 (`apps/backups`)
     and 235 (`docs/restore.md`) reference the backup system; leave them.
   - Lines 263-272 ("Recommended sequencing"): item 1 becomes "Done: MinIO
     SSE-S3"; add "Rehearse the KEK emergency runbook" as the next item.
   Traps: do not edit `docs/restore.md` or anything under `apps/backups`
   (team t3681). Do not paste any Secret value; use placeholders only in
   prose, and no key placeholder inside a command line. Keep line width near
   the file's existing ~80 columns. Do not stage or commit.

3. **`docs/secrets-management.md` and one manifest comment** (coder: coder) →
   verify by
   `python3 scripts/rotation-ledger-check.py --validate-only docs/secrets-management.md`
   (exit 0),
   `grep -n 'this PR\|two consumers\|brand new\|both buckets' docs/secrets-management.md`
   (no output), and
   `kustomize build apps/minio/manifests | sha256sum` equal before and after.
   - Line 50: `minio-kms` row: drop "(new, this PR)"; consumers "minio".
   - Line 206: shorten the last cell to: "Single-key mode can't hold old and
     new at once, so there's no scheduled rotation until KES. On compromise,
     follow the emergency runbook (untested, needs downtime) in
     [`encryption-at-rest.md`](encryption-at-rest.md#kek-compromise-emergency-re-encryption-untested)."
     Check the anchor against the heading written in step 2.
   - Lines 412-416: "the new secret this PR introduces" → "the MinIO KEK";
     "two consumers" → "one consumer"; replace the "brand new" bullet with
     "It has no scheduled rotation, so there is no rotation habit to disrupt."
   - `docs/encryption-at-rest.md` line ~100 and `secrets-management.md`
     line 179 link to `#rotation-policy`; keep those links valid.
   - `apps/minio/manifests/manifests.yaml` line 31: "(the minio pod and the
     Job both reference it)" → "(the minio pod references it)". Comment only.
   Traps: the ledger block between `<!-- rotation-ledger:start -->` and
   `<!-- rotation-ledger:end -->` must not change. Leave the `p510` statements
   in this file as they are (bootstrap host unconfirmed; listed as an owner
   check). Do not stage or commit.

4. **`.github/workflows/secret-rotation-due.yml`** (coder: coder) → verify by
   the PR's CI run of this workflow (the lead also reads the diff; no local
   YAML tooling is assumed).
   - `on.pull_request.paths`: add `scripts/minio-kek-drill.py`,
     `apps/minio/manifests/manifests.yaml`, `docs/encryption-at-rest.md`.
   - New step after "Self-test the checker before trusting it" and before
     "Check the ledger": name "Self-test the KEK drill printer (bucket list
     matches the manifest and the runbook)", run
     `python3 scripts/minio-kek-drill.py --self-test`.
   - Add one comment line in the header saying the workflow also guards the
     KEK runbook's bucket list (#314).
   Traps: actions are pinned by digest in this repo; add no new action. The
   `workflow duplication` check compares workflows pairwise; this adds lines
   to an existing file, not a new file. Do not stage or commit.

5. **Factory `docs/compliance/policies/encryption-key-mgmt.md`** (coder:
   coder; separate worktree on branch `docs/314-encryption-policy-status`,
   after the factory-gitops PR is merged) → verify by
   `grep -c '^- \[x\]' docs/compliance/policies/encryption-key-mgmt.md` = 0
   and the repo's docs checks in CI.
   - After line 12 ("## Current state (grounded)"): add
     "### Status update 2026-11-14" with the status table above (same labels),
     linking factory-gitops `docs/encryption-at-rest.md` and
     `docs/secrets-management.md`.
   - Line 29 (MinIO paragraph): SSE-S3 is configured on three buckets with
     MinIO's built-in static single-key mode (`MINIO_KMS_SECRET_KEY`); new
     writes are encrypted; existing-object coverage is not evidenced.
   - Line 32: "Net: object content in MinIO is encrypted for new writes;
     every volume (Postgres, Redis, Keycloak, MinIO's own) and etcd are not."
   - Line 37: keep "no key-management system"; say MinIO's key is a static
     key in a Kubernetes Secret, not a KMS service, and that a rotation policy
     and overdue check now exist (factory-gitops#328).
   - Lines 43, 47, 48 (gaps 2, 6, 7): append the annotations: gap 2 "Partly
     addressed 2026-11-14: SSE-S3 configured; existing-object coverage not
     evidenced; emergency re-encryption untested." gap 6 "Partly addressed:
     agenix custody documented in factory-gitops; offline identity backup and
     bootstrap host unconfirmed; no dual control." gap 7 "Partly addressed:
     rotation policy and overdue check exist; rotation is manual."
   - Lines 89-98: tick nothing. Append to lines 90, 95 and 96 a short
     "(2026-11-14: <what is still missing>)" note.
   - Line 4 status line: "Draft. MinIO SSE-S3 is configured for new writes;
     volume encryption (Postgres, Redis, Keycloak, MinIO), etcd Secret
     encryption and a KMS are not implemented."
   Traps: Factory is a different repo with its own artifact folders; the
   artifacts for this task live in factory-gitops, so link them by full
   GitHub URL in the PR, not by relative path. Touch only this one file. Do
   not stage or commit.

6. **Comment on Factory#314** (lead, no file) after both PRs are open: the
   status table and the owner actions, one line each: enable k3s
   `--secrets-encryption`; rehearse the KEK runbook on a throwaway MinIO and
   file the drill record; confirm an offline backup of a decrypting identity;
   confirm which host runs the secret bootstrap; run the existing-object
   encryption check; decide on Redis/Keycloak volumes (risk acceptance or node
   LUKS); decide on FIPS 140 scope; decide on KES. The epic stays open.

## Deviations

- Step 2: the paragraph on the `local-path` provisioner (old lines 24-26) was
  kept under the status table with the path corrected, instead of being
  replaced. It states the constraint the rest of the doc works within.
- Step 2: the runbook also says to run each printed fragment from a file with
  `bash`, and lists the tools the fragments need (`mc`, `jq`, `sha256sum`).
- Step 1: tags are exported with `mc tag list --json` and re-applied as
  `key=value&key=value`; still marked UNPROVEN in the output.

- Step 1, after the final review: the script exports **every** version by
  version id to `<staging>/versions/<bucket>` (not only noncurrent ones to
  `noncurrent/`), because selecting noncurrent versions depended on a JSON
  field that may not exist, and an empty selection passed its own check. A
  count gate (at least one staged version per current key) now fails an empty
  export. Also added: `--step` to print one step, `set -o noclobber` in
  step 3, a tag comparison and a tie-back to the step 4 manifest in step 6b.
- Step 5: the heading "Data at rest (none)" became "Data at rest (partial:
  MinIO object content only)", because the lines under it no longer say
  "none". The status line is line 6 of the file, not line 4.

## Tests

In the factory-gitops worktree. Exit 0 unless noted; a `grep` that is
expected to find nothing exits 1, which is the pass.

```
python3 scripts/minio-kek-drill.py --self-test
python3 scripts/minio-kek-drill.py > /tmp/plan.sh && bash -n /tmp/plan.sh
grep -c -E 'kubectl|mc rm|mc rb|MINIO_KMS|<OLD|<NEW' /tmp/plan.sh   # prints 0, exits 1
python3 scripts/minio-kek-drill.py --alias=-rf        # non-zero
python3 scripts/minio-kek-drill.py --alias 'a;b'      # non-zero
python3 scripts/rotation-ledger-check.py --self-test
python3 scripts/rotation-ledger-check.py --validate-only docs/secrets-management.md
grep -n 'nothing at rest\|this PR\|both buckets\|two consumers\|brand new\|both reference' \
  docs/encryption-at-rest.md docs/secrets-management.md apps/minio/manifests/manifests.yaml   # no output, exits 1
git diff main -- apps/minio/manifests/manifests.yaml   # one comment line only
```

Then CI green on both PRs (`gh pr checks`).

## Rollback

Revert the merge commit of each PR. Nothing was applied to the cluster, so
there is no runtime state to undo.
