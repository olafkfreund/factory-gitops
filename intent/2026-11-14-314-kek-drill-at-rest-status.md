---
status: draft
issue: 314
author: olafkfreund
---

# Intent: at-rest status of record and a rehearsable KEK emergency procedure (Factory#314)

## Problem

Epic olafkfreund/Factory#314 is still open. A read-only check on 2026-11-14
(`kubectl get/describe` on context `k3d-factory`, plus the repos) gives this
state per requirement:

| Requirement | State | Evidence |
|---|---|---|
| MinIO server-side encryption | Done | Deployment `minio` takes `MINIO_KMS_SECRET_KEY` from Secret `minio-kms`; the `minio-create-bucket` Job (completed) runs `mc encrypt set sse-s3` on `factory-artifacts`, `factory-backups` and `factory-evidence` and is not allowed to fail silently. |
| KEK custody | Done | KEK is in agenix (`factory-secret-minio-kms.age`) and restored by the cluster bootstrap (owner comment on #314, 2026-07-25); custody section merged in factory-gitops#328. |
| Key-rotation policy + ledger | Done | factory-gitops#328 (`docs/secrets-management.md`, weekly ledger check). |
| Postgres at rest | Risk accepted | R-014, review 2027-04-24 (Factory#3653). PVC `data-postgres-0` is on `local-path`, no LUKS on the host. |
| KEK emergency (compromise) procedure | **Gap** | It exists only as one long table cell in `docs/secrets-management.md`, marked "untested". Nobody can rehearse it step by step, and it names two buckets although three are encrypted. |
| Docs describe the real state | **Gap** | `docs/encryption-at-rest.md` still opens with "What is encrypted today: nothing at rest", says SSE is "shipped in this PR", lists two buckets, and puts the cluster on p510 at `/mnt/img_pool/k3d/storage` (it is on p620 at `/mnt/code/k3d/storage`). Factory `docs/compliance/policies/encryption-key-mgmt.md` still lists "no SSE, no KMS", "no custody documentation" and "no rotation policy" as open gaps. An assessor reading either gets the wrong picture. |
| etcd Secret encryption | Owner action | Server node args have no `--secrets-encryption` (`k3s.io/node-args` annotation). It is a k3d/nixos_config change on the host. |
| Redis, Keycloak and other `local-path` volumes | Owner decision | Unencrypted, covered only by R-003 (open). Same fix as Postgres (node LUKS). |
| FIPS 140 modules | Owner decision | FedRAMP only; nothing asserted. |
| KES / real KMS | Owner decision | Needed only for scheduled KEK rotation. |

## Proposed outcome

- `docs/encryption-at-rest.md` opens with a dated status table that matches the
  cluster, names the right host, path and all three buckets, and says how each
  line was verified.
- The KEK emergency procedure is a numbered runbook, and a script prints the
  exact command for each step **without running any of them**. The script has
  no execute mode. The owner can read it top to bottom, rehearse it against a
  throwaway MinIO, and record the result.
- The Factory policy document marks the closed gaps as closed and keeps the
  open ones open, with links to the evidence.
- The epic gets a comment with the table above and the list of owner actions.

## Affected users and systems

The operator (the user) and any assessor reading the compliance docs.
factory-gitops: `docs/`, one new script under `scripts/`, one CI step.
Factory: `docs/compliance/policies/encryption-key-mgmt.md`. No cluster, Secret
or nixos_config change.

## Constraints

- Must not run the KEK emergency procedure, or any write, against the live
  cluster. Read-only `kubectl get/describe` only.
- The script must not be able to change anything: no execute flag, no network
  call, no `kubectl`/`mc` invocation. It must never print or read key material.
- Backups and restore (#3681, `docs/restore.md`, `apps/backups`) belong to
  another team and are not touched.
- The artifacts for both repos live here in factory-gitops (as for #328); the
  Factory PR links to them.
- Postgres at rest stays risk-accepted (R-014). FIPS, KES and etcd encryption
  are described as owner actions, not implemented.

## Open questions

None for this change. Owner decisions that stay open on the epic: whether to
enable k3s `--secrets-encryption`, when to run the KEK drill, and whether
Redis/Keycloak volumes get their own risk acceptance or wait for node LUKS.
