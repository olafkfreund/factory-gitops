---
status: draft
issue: 314
author: olafkfreund
---

# Intent: at-rest status of record and a rehearsable KEK emergency procedure (Factory#314)

## Problem

Epic olafkfreund/Factory#314 is still open. A read-only check on 2026-11-14
gives the state below. "Live" means `kubectl get/describe` on context
`k3d-factory`; "repo" means a file in this repo; "record" means an issue, PR or
risk-register entry that this repo cannot re-verify.

| Requirement | State | Evidence |
|---|---|---|
| MinIO server-side encryption | Configured; coverage of existing objects not evidenced | Live: Deployment `minio` takes `MINIO_KMS_SECRET_KEY` from Secret `minio-kms`; Job `minio-create-bucket` succeeded 2026-10-22. Repo: the Job runs `mc encrypt set sse-s3` on `factory-artifacts`, `factory-backups` and `factory-evidence`. The setting applies only to objects written after it; nothing shows that objects (and retained versions) already in the buckets are encrypted. |
| KEK custody | Documented; one part unconfirmed | Record: KEK is in agenix and restored by the cluster bootstrap (owner comment on #314, 2026-07-25). Repo: custody section in `docs/secrets-management.md` (factory-gitops#328), which itself says the offline backup of a decrypting identity is unconfirmed. Until etcd or the disk is encrypted, the KEK also sits in plaintext on the same host as the data it protects. |
| Key-rotation policy + ledger | Done | Repo: `docs/secrets-management.md`, `scripts/rotation-ledger-check.py`, weekly workflow (factory-gitops#328). |
| Postgres at rest | Risk accepted | Record: R-014, review 2027-04-24 (Factory#3653). Live: PVC `data-postgres-0` is on `local-path`. |
| KEK emergency (compromise) procedure | **Gap** | Repo: it exists only as one table cell in `docs/secrets-management.md`, marked "untested". It names two buckets although three are encrypted. It does not say what happens to object versions: all three buckets are versioned, a plain delete leaves old versions wrapped under the old KEK, and `mc mirror` copies only current versions, so the 30-day tamper-recovery history on `factory-evidence` would be lost without anyone deciding that. It has no rollback point, no integrity check beyond counts, and no rule for when the old KEK may be destroyed. |
| Docs describe the real state | **Gap** | Repo: `docs/encryption-at-rest.md` opens with "What is encrypted today: nothing at rest", says SSE is "shipped in this PR", lists two buckets, and puts the storage on p510 at `/mnt/img_pool/k3d/storage`. Record: the owner's host check of 2026-10-24 found it on p620 at `/mnt/code/k3d/storage`. `docs/secrets-management.md` lists the bucket-init Job as a consumer of `minio-kms` (it only uses `minio-creds`) and still says "new, this PR". Factory `docs/compliance/policies/encryption-key-mgmt.md` still lists "no SSE, no KMS", "no custody documentation" and "no rotation policy" as open gaps. |
| Application-level encryption keys | Documented elsewhere, not in the at-rest picture | Repo: `KMS_FERNET_KEY` (aifactory) and `CFACTORY_CREDENTIAL_KEY` (cfactory) are data-encryption roots in the rotation policy, but `docs/encryption-at-rest.md` does not mention them. |
| etcd Secret encryption | Owner action | Live: the server node's `k3s.io/node-args` has no `--secrets-encryption`. It is a k3d/nixos_config change on the host. |
| Redis, Keycloak and other `local-path` volumes | Owner decision | Live: all on `local-path`. Record: covered only by R-003 (open). Same fix as Postgres (node LUKS). |
| FIPS 140 modules | Owner decision | Nothing asserted. The epic scopes it to FedRAMP. |
| KES / external KMS | Owner decision | Would allow scheduled and no-downtime KEK rotation and take the raw KEK out of the pod environment. |

## Proposed outcome

- `docs/encryption-at-rest.md` opens with a dated status table that matches the
  cluster, names all three buckets, says how each line was verified, and is
  plain that SSE does not protect against seizure of the host while the KEK is
  in unencrypted etcd on the same disk. `docs/secrets-management.md` agrees
  with it.
- The KEK emergency procedure is a numbered runbook that covers all three
  buckets and states, per step: which writers to stop, what happens to object
  versions, how integrity is checked, where the rollback point is, and when the
  old KEK may be destroyed. It stays marked **untested** until the owner has
  rehearsed it on a throwaway MinIO and filed a drill record (date, operator,
  versions, checks, result, open limitations).
- The owner can get the exact commands for each step without anything being
  run for them, and a check in CI fails when the runbook's bucket list drifts
  from the buckets the manifest encrypts.
- The Factory policy document marks as closed only what is evidenced (SSE
  configured, custody and rotation policy documented) and keeps the rest open,
  including the untested emergency procedure.
- The epic gets a comment with the table above and the list of owner actions.

## Affected users and systems

The operator (the user) and any assessor reading the compliance docs.
factory-gitops docs, a rehearsal aid and its CI check. Factory:
`docs/compliance/policies/encryption-key-mgmt.md`. No cluster, Secret or
nixos_config change.

## Constraints

- Must not run the KEK emergency procedure, or any write, against the live
  cluster. Read-only `kubectl get/describe` only.
- Whatever aids the rehearsal must not be able to change anything: no option
  that executes the steps, no network, `kubectl` or `mc` call, and it never
  reads or prints key material.
- No change to the backup system (#3681, `docs/restore.md`, `apps/backups`):
  it belongs to another team. The runbook still names the backup and evidence
  writers that must be paused, and must not lose `factory-backups` data.
- The artifacts for both repos live here in factory-gitops (as for #328); the
  Factory PR links to them and merges after this one.
- Postgres at rest stays risk-accepted (R-014). FIPS, KES and etcd encryption
  are described as owner actions, not implemented.

## Open questions

None that block this change. Owner actions that stay open on the epic: enable
k3s `--secrets-encryption`; rehearse the KEK procedure and file the record;
confirm the offline backup of a decrypting identity; confirm which host runs
the secret bootstrap (the docs say p510, the storage is on p620); verify that
objects already in the buckets are encrypted; decide on Redis/Keycloak volumes,
FIPS and KES.
