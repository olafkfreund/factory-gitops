# Encryption at rest

Design and staged rollout for encryption at rest across the factory cluster
(Factory#314, part of the compliance program #310 gap #3).

## Status as of 2026-11-14

Each statement carries its kind of evidence and a date. **Live**: read-only
`kubectl get/describe` on context `k3d-factory`, 2026-11-14. **Repo**: a file
in this repo. **Record**: an issue, PR or risk entry that this repo cannot
re-verify, with its own date.

| Layer | State | Evidence |
|-------|-------|----------|
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

**Limit.** While etcd and the disk are unencrypted, the KEK is on the same
host as the ciphertext. SSE protects a copied bucket or PVC blob, not a seized
host.

The single-node k3s `local-path` provisioner writes PVC data straight to a
directory on the host filesystem (`/mnt/code/k3d/storage/...` on p620 per the
2026-10-24 host check). It offers no encryption hook. That is the hard
constraint this design works within.

### How the Live rows were checked

All read-only, context `k3d-factory`:

```bash
kubectl -n factory describe deploy minio
kubectl -n factory describe job minio-create-bucket
kubectl -n factory get pvc
kubectl get storageclass
kubectl get node -o jsonpath='{.items[*].metadata.annotations.k3s\.io/node-args}'
```

### Open owner checks

- Enable k3s `--secrets-encryption` (section 2).
- Rehearse the KEK emergency runbook on a throwaway MinIO and file the drill
  record (see "KEK compromise" below).
- Confirm an offline backup of a decrypting agenix identity.
- Confirm which host runs the secret bootstrap.
- Check existing objects: a full enumeration with
  `mc stat --versions --recursive --json` over each bucket, delete markers
  excluded. Every entry must show SSE-S3.
- Decide on the Redis and Keycloak volumes (risk acceptance or node LUKS).
- Decide on FIPS 140 scope.
- Decide on KES.

## Threat model

Encryption at rest defends against **offline** disclosure: a stolen disk, a
seized host, a leaked backup blob, a snapshot copied off the box. It does
**not** defend against an attacker with live cluster/root access — they read
plaintext through the running process regardless. So the goal here is: if the
PVC data, an etcd snapshot, or a backup object leaves the trust boundary, it is
useless without keys held elsewhere.

## Layers, and what each requires

| Layer | Protects | Doable on k3s local-path now? |
|-------|----------|-------------------------------|
| MinIO SSE-S3 | Object content in `factory-artifacts` / `factory-backups` / `factory-evidence` | Yes — shipped (manifests; first two buckets in factory-gitops#71) |
| etcd EncryptionConfiguration | Kubernetes Secrets at rest in etcd | No — node/k3s-flag action (runbook below) |
| Node LUKS / encrypted storageClass | The whole PVC block device (Postgres + MinIO + everything) | No — node action, destructive (runbook below) |

MinIO SSE and node LUKS overlap deliberately: SSE encrypts object *content* with
a key MinIO controls; LUKS encrypts the *device* the objects and the wrapped
keys sit on. LUKS is the broader control (it also covers Postgres, which has no
application-level at-rest option here); SSE is the one we can turn on today
without touching the node.

---

## 1. MinIO SSE-S3 (shipped)

Delivered as manifests in `apps/minio/manifests/manifests.yaml`. No node action,
no operator, works on the existing `local-path` PVC.

### How it works

1. MinIO is given a **built-in single-key KMS** via the `MINIO_KMS_SECRET_KEY`
   env var (format `<key-name>:<base64 32-byte key>`). This is MinIO's local
   KMS mode — no external KES server needed, appropriate for a single-node
   deployment.
2. The bucket-init Job runs `mc encrypt set sse-s3` on all three buckets
   (`factory-artifacts`, `factory-backups`, `factory-evidence`). From then
   on every object PUT is auto-encrypted: MinIO generates a per-object data key,
   encrypts the object with it, wraps the data key with the KEK, and writes only
   the ciphertext plus the wrapped key to the PVC.
3. Reads are transparent for any client presenting valid S3 credentials — the
   PARR services need no change.

### Key custody (the KEK)

The KEK is the `MINIO_KMS_SECRET_KEY` value, held in a **separate out-of-band
Secret** `minio-kms` (deliberately not `minio-creds` — different blast radius,
different rotation story). The operator seeds it once, before first sync:

```bash
kubectl -n factory create secret generic minio-kms \
  --from-literal=MINIO_KMS_SECRET_KEY="factory-kek-1:$(openssl rand -base64 32)"
```

Custody rules:

- This KEK is the root of trust for all MinIO object encryption. **Lose it and
  every encrypted object is unrecoverable. Leak it and SSE is void.**
- Keep it in the same custody as the other cluster secrets — agenix in
  nixos_config (`manage-secrets.sh`), see `docs/secrets-management.md` — and never in git.
- It shares a failure domain with the data if it only ever lives in-cluster.
  Store the authoritative copy off-cluster (agenix recipient store) so a full
  cluster wipe does not also destroy the ability to read backups.

### KEK compromise: emergency re-encryption (UNTESTED)

`minio-kms` has no scheduled rotation (see
[Rotation policy](secrets-management.md#rotation-policy)). MinIO's built-in
single-key KMS mode cannot hold an old and a new KEK at the same time, so the
previously documented in-place `mc cp` recipe is not a working rotation. The
only path is a cutover to a fresh volume, for all three buckets
(`factory-artifacts`, `factory-backups`, `factory-evidence`). **This procedure
has never been run.** It needs downtime for every S3 consumer.

Two rules hold throughout: MinIO is never started with a new KEK over data
written under the old one, and nothing is deleted until the last step.

The per-bucket commands for steps 3, 4 and 6 come from
`python3 scripts/minio-kek-drill.py --alias <alias> --staging <dir>`, which
only prints them. Do not retype them. Print one step at a time with
`--step 3`, `--step 4`, `--step 6a` or `--step 6b`, save it to a file and
run it with `bash` (each fragment sets `set -euo pipefail`, which would close
an interactive shell on the first failed check). The fragments need `mc`, `jq`
and `sha256sum` on the machine that holds the staging volume. The script
refuses object keys it cannot handle safely (a newline, a `..` component, a
leading or trailing `/`); handle those objects by hand.

1. **Prepare the new KEK first.** If the compromise came through an agenix
   identity, remove that recipient and re-key first. Make a new KEK with a new
   key name (`factory-kek-2`, same format as above), store it in agenix beside
   the old one and confirm it decrypts. Key values go only through agenix and
   a file under `/dev/shm` fed to `kubectl patch`; never on a command line.
2. **Quiesce.** Pause ArgoCD auto-sync for `minio` and every S3-writing app
   (they have `selfHeal`), pause the KEDA scalers, scale S3 writers to zero,
   suspend the CronJobs `postgres-backup` and `evidence-collector`, and wait
   for running Jobs to finish. Find the writers with
   `grep -rln 'factory-artifacts\|factory-backups\|factory-evidence' apps/`.
   Lifecycle expiry keeps running; what it removes was due to expire anyway.
3. **Export under the old KEK** to persistent encrypted staging (a LUKS
   volume; not `tmpfs`, not the plain node disk). Per bucket: current objects
   (`mc mirror`); every version, current and noncurrent, to a path carrying its
   version id;
   an inventory of versions and delete markers; and the object tags (the
   `factory-artifacts` lifecycle rules filter on the `role` tag).
4. **Verify the export by content**, for current objects and for the
   per-version archive separately: a SHA-256 manifest of the staged files must equal a
   SHA-256 manifest from a second, independent read from MinIO
   (`mc cat | sha256sum`; for the version archive `mc cat --version-id`, with
   the version id in each manifest line). The archive must hold at least one
   file per current key, so an export that silently selected nothing fails. `mc diff` is not evidence. Any
   difference stops the procedure.
5. **Cut over.** Scale MinIO to zero and leave the old PVC untouched. Run the
   Deployment on a new empty PVC with `minio-kms` set to the new KEK, start it,
   and confirm the key in use is the new key name (`mc admin kms key status`).
   Run `minio-create-bucket` **before** restoring.
6. **Restore and verify.** Mirror current objects back, re-apply the tags, and
   recompute the SHA-256 manifest from the new MinIO: it must equal the staged
   one. The newest Postgres backup must pass `gunzip -t`. Restart MinIO once
   more and repeat the read check on a sample.
7. **Resume** the writers, KEDA and ArgoCD sync.
8. **Retire**, last and separately, after a soak the owner sets (suggested:
   one good nightly backup and one evidence run): delete the old PVC, remove
   the old KEK from agenix, and update the `minio-kms` ledger row. Staged
   noncurrent versions stay on the staging volume until their retention would
   have expired (`factory-backups` 7 days, `factory-evidence` 30 days); then
   destroy the volume.

**Rollback boundary.** Through step 6, rollback loses no data: the old PVC and
the old KEK are intact and the writers are still paused. After the writers
resume in step 7, going back to the old PVC loses whatever was written since,
so from step 7 on rollback is a decision with a stated loss. Deleting the old
PVC in step 8 ends the rollback option altogether.

**What is kept.** No backup or evidence data is lost: current objects are
restored and checksum-verified, and noncurrent versions are kept in the
staging archive. In-bucket version history restarts. **Cost:** downtime for
all S3 consumers, and disk for the old PVC, the new PVC and the staging volume
at once.

**Unproven, to be settled by rehearsal:**

- the exact `mc` flags for exporting versions and tags on the pinned image;
- that `mc admin kms key status` reports the key name in single-key mode;
- how the PVC switch is done under ArgoCD.

#### Rehearsal and drill record

Rehearse on a throwaway MinIO: a local container at the digest pinned in
`apps/minio/manifests/manifests.yaml`, with its own KEK and dummy objects,
including overwritten objects (noncurrent versions) and tagged objects. Never
point the drill at the production MinIO.

Record, for each drill: date, operator, MinIO and `mc` versions, the steps run,
each check and its result, time taken, deviations, and open limitations.

This section keeps UNTESTED in its title until a drill record is linked here.

#### Beyond the built-in KMS

If the KEK inventory ever needs to grow (multiple named keys, automatic
rotation), that is the point to graduate from the built-in KMS to a real KES +
KMS backend. KES is not deployed; tracked as future work, not needed for the
current gap.

### Verifying it is on

```bash
kubectl -n factory logs job/minio-create-bucket | grep -i encrypt
# or, from an mc-capable pod:
mc encrypt info fac/factory-artifacts     # -> "Auto encryption 'sse-s3' is enabled"
mc encrypt info fac/factory-backups
mc encrypt info fac/factory-evidence
mc stat fac/factory-artifacts/<some-object> | grep -i encryption
```

This shows the bucket default only, which applies to new writes. For existing
objects, see "Open owner checks" in the status section above.

### Limits (be honest)

- SSE protects object **content**. Object **names/keys** and bucket metadata are
  not encrypted.
- The KEK, while wrapped-at-use, is present in the MinIO process env and in the
  `minio-kms` Secret in etcd — which is itself unencrypted until the etcd layer
  below is done. So SSE alone raises the bar but the etcd + LUKS layers are what
  close the loop.

---

## 2. OPERATOR / NODE ACTION: etcd Secret encryption (runbook — do NOT apply from CI)

Encrypts Kubernetes Secrets at rest in the k3s datastore. This is a **node
action on p510**, applied through the nixos_config k3s module, not through this
GitOps repo. Do not attempt it from ArgoCD.

k3s supports this natively with `--secrets-encryption` (it manages the
`EncryptionConfiguration` and the AES-CBC key for you).

### Steps

1. **Confirm which host runs the cluster and the secret bootstrap.** The
   storage was found on p620 on 2026-10-24; these commands were written for
   p510. Adjust host names before running anything.

2. On p510, enable secrets encryption on the k3s server. In the nixos_config k3s
   module (`modules/containers/k3d.nix` / the k3s server flags), add:

   ```
   --secrets-encryption
   ```

   (For a plain k3s server this is the supported flag. If the cluster is k3d,
   pass it via `--k3s-arg "--secrets-encryption@server:0"`.)

3. Redeploy the node so k3s restarts with the flag:

   ```bash
   just quick-deploy p510
   ```

4. Confirm encryption is active and pick up the generated key:

   ```bash
   ssh p510 'sudo k3s secrets-encrypt status'
   # Encryption Status: Enabled
   # Current Rotation Stage: start
   # Active Key ... aescbc
   ```

5. Encrypt all **existing** Secrets (new ones are encrypted automatically; old
   ones were written plaintext and must be rewritten):

   ```bash
   ssh p510 'sudo k3s secrets-encrypt reencrypt'
   ```

   For a vanilla kube-apiserver (non-k3s-managed) the equivalent is
   `kubectl get secrets -A -o json | kubectl replace -f -` after installing the
   `EncryptionConfiguration` and pointing `--encryption-provider-config` at it.

6. Verify a secret is now ciphertext in the datastore:

   ```bash
   ssh p510 'sudo ETCDCTL_API=3 etcdctl get /registry/secrets/factory/minio-creds | hexdump -C | head'
   # should begin with "k8s:enc:aescbc:v1:" not readable plaintext
   ```

### Key custody

k3s stores the AES key in `/var/lib/rancher/k3s/server/cred/encryption-config.json`
on the node (mode 0600, root). Back it up **off the node** — losing it while the
etcd data survives means the Secrets are unrecoverable. Rotate with
`k3s secrets-encrypt rotate` followed by `reencrypt`.

### Caveat

The encryption key living on the same node as etcd means this defends against a
copied etcd snapshot, not against full root on the live host. Combine with node
LUKS (below) for at-rest protection of the key file itself.

---

## 3. OPERATOR / NODE ACTION: node LUKS / encrypted storageClass (runbook — destructive, do NOT apply from CI)

The broadest control: encrypt the block device under **all** PVC data (Postgres,
MinIO, and the etcd datastore in one go). This is the only at-rest option for
Postgres on `local-path`, which has no application-level encryption here. It is a
**disruptive node action** — it reformats storage — and must be planned as a
maintenance window with a full backup first.

### Option A (recommended): LUKS under the local-path directory

Encrypt the filesystem that backs the k3s `local-path` provisioner
(the local-path storage directory: `/mnt/code/k3d/storage` on p620 per the
2026-10-24 host check).

1. **Confirm which host runs the cluster and the secret bootstrap.** The
   storage was found on p620 on 2026-10-24; the commands below were written
   for p510. Adjust host names before running anything.

2. **Back up everything first.** Trigger a fresh Postgres backup
   (`apps/backups`) and confirm the object is in `factory-backups`, then copy it
   off-cluster. PVC data is destroyed by this procedure.

3. Drain the workloads:

   ```bash
   ssh p510
   sudo systemctl stop k3d-cluster-bootstrap   # or: kubectl -n factory scale deploy,statefulset --all --replicas=0
   ```

4. Create a LUKS container on a spare disk/partition (or a backing file for a
   lab node), open it, format, and mount it at the storage path:

   ```bash
   sudo cryptsetup luksFormat /dev/<disk>           # choose a strong passphrase / key file
   sudo cryptsetup luksOpen  /dev/<disk> factory-data
   sudo mkfs.ext4 /dev/mapper/factory-data
   sudo mount /dev/mapper/factory-data /mnt/code/k3d/storage
   ```

5. Persist it declaratively in nixos_config (this is the NixOS way — do not do it
   imperatively long-term): add the device to
   `boot.initrd.luks.devices."factory-data"` (or `environment.etc.crypttab`) with
   a key file under agenix, and a `fileSystems."/mnt/code/k3d/storage"` entry
   depending on the mapper device. Deploy with `just quick-deploy p510`.

6. Restore data: bring the cluster back up
   (`sudo systemctl start k3d-cluster-bootstrap`), let ArgoCD re-sync the
   manifests, then restore Postgres from the backup per `docs/restore.md`. MinIO
   objects restore from the off-cluster copy if you kept one; otherwise the
   fresh buckets are empty (acceptable for artifacts, not for backups — hence
   step 1).

### Option B: an encrypted storageClass

Replace `local-path` with a CSI driver that encrypts volumes (e.g. LUKS-backed
LVM via TopoLVM, or a LUKS layer under Longhorn). Heavier operationally and a
bigger change than this gap needs on a single node; documented as the path if
the cluster grows beyond one node, where per-node LUKS stops being sufficient.

### Key custody

The LUKS passphrase / key file is the root of trust for everything on disk.
Store it in agenix (off the node), never on the encrypted volume itself, and
protect the initrd/crypttab key file at mode 0400. Losing it after a reboot
means the data is gone; a network-bound unlock (clevis/tang) avoids typing a
passphrase on every boot but adds a dependency — out of scope for now.

### Caveat

LUKS protects the disk **at rest** (powered off / removed). Once the volume is
unlocked and mounted on a running node, data is plaintext to anything with host
access. It does not replace the etcd and SSE layers; it sits underneath them.

---

## Recommended sequencing

1. **Done:** MinIO SSE-S3 — manifests, reviewable, no node action.
2. **Next:** rehearse the KEK emergency runbook on a throwaway MinIO and file
   the drill record (see "KEK compromise" above).
3. **Next maintenance window:** etcd secrets encryption — one k3s flag +
   reencrypt, low risk, big win for the Secret-in-etcd exposure.
4. **Planned maintenance window with backup:** node LUKS under the local-path
   directory — the broad control that finally covers Postgres.

Each step is independently valuable and independently reversible-ish; do them in
that order because the risk/disruption grows down the list.
