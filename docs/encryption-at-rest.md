# Encryption at rest

Design and staged rollout for encryption at rest across the factory cluster
(Factory#314, part of the compliance program #310 gap #3).

## What is encrypted today: nothing at rest

Be honest about the starting point. As of this document, **no data is encrypted
at rest** anywhere in the cluster:

- **Postgres** (`apps/postgres`) stores every control-plane database
  (pfactory / tfactory / aifactory / cfactory + globals) on a plain k3s
  `local-path` PVC. The files on the node disk are plaintext.
- **MinIO** (`apps/minio`) stores all PARR artifacts and the Postgres logical
  backups (`factory-artifacts`, `factory-backups`) on a plain `local-path` PVC,
  with no server-side encryption. Objects on the node disk are plaintext.
- **etcd** (k3s embedded) stores every Kubernetes Secret base64-encoded but
  **unencrypted** — there is no `EncryptionConfiguration`. Anyone who can read
  `/var/lib/rancher/k3s/server/db` on the node can read every secret.
- **The node disk itself** is not LUKS-encrypted, so all of the above is
  readable from the raw block device if the disk is removed or the host is
  seized.

The single-node k3s `local-path` provisioner writes PVC data straight to a
directory on the host filesystem (`/mnt/img_pool/k3d/storage/...` on p510). It
offers no encryption hook. That is the hard constraint this design works within.

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
| MinIO SSE-S3 | Object content in `factory-artifacts` / `factory-backups` | Yes — shipped in this PR (manifests) |
| etcd EncryptionConfiguration | Kubernetes Secrets at rest in etcd | No — node/k3s-flag action (runbook below) |
| Node LUKS / encrypted storageClass | The whole PVC block device (Postgres + MinIO + everything) | No — node action, destructive (runbook below) |

MinIO SSE and node LUKS overlap deliberately: SSE encrypts object *content* with
a key MinIO controls; LUKS encrypts the *device* the objects and the wrapped
keys sit on. LUKS is the broader control (it also covers Postgres, which has no
application-level at-rest option here); SSE is the one we can turn on today
without touching the node.

---

## 1. DOABLE NOW: MinIO SSE-S3 (shipped in this PR)

Delivered as manifests in `apps/minio/manifests/manifests.yaml`. No node action,
no operator, works on the existing `local-path` PVC.

### How it works

1. MinIO is given a **built-in single-key KMS** via the `MINIO_KMS_SECRET_KEY`
   env var (format `<key-name>:<base64 32-byte key>`). This is MinIO's local
   KMS mode — no external KES server needed, appropriate for a single-node
   deployment.
2. The bucket-init Job runs `mc encrypt set sse-s3` on both buckets. From then
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
- Keep it in the same custody as the other cluster secrets — agenix on p510
  (`manage-secrets.sh`), see `docs/secrets-management.md` — and never in git.
- It shares a failure domain with the data if it only ever lives in-cluster.
  Store the authoritative copy off-cluster (agenix recipient store) so a full
  cluster wipe does not also destroy the ability to read backups.

### Rotating the KEK

Not a drop-in replace: existing objects have their data keys wrapped by the old
KEK. To rotate you add a new key and re-wrap:

```bash
# 1. Add a second key to MINIO_KMS_SECRET_KEY is NOT supported in single-key
#    mode — instead run KES, or re-encrypt objects under a new default key:
# 2. Seed a new KEK name (keep the old one available for decryption):
#    update minio-kms to `factory-kek-2:<new base64 key>` ONLY after all objects
#    are re-encrypted, otherwise old objects become unreadable.
# 3. Re-encrypt in place by copying each object onto itself under the new key:
mc cp --recursive --encrypt "sse-s3" fac/factory-artifacts/ fac/factory-artifacts/
```

For a small artifact store the copy-in-place re-encryption is fine. If the KEK
inventory ever needs to grow (multiple named keys, automatic rotation), that is
the point to graduate from the built-in KMS to a real KES + KMS backend —
tracked as future work, not needed for the current gap.

### Verifying it is on

```bash
kubectl -n factory logs job/minio-create-bucket | grep -i encrypt
# or, from an mc-capable pod:
mc encrypt info fac/factory-artifacts     # -> "Auto encryption 'sse-s3' is enabled"
mc stat fac/factory-artifacts/<some-object> | grep -i encryption
```

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

1. On p510, enable secrets encryption on the k3s server. In the nixos_config k3s
   module (`modules/containers/k3d.nix` / the k3s server flags), add:

   ```
   --secrets-encryption
   ```

   (For a plain k3s server this is the supported flag. If the cluster is k3d,
   pass it via `--k3s-arg "--secrets-encryption@server:0"`.)

2. Redeploy the node so k3s restarts with the flag:

   ```bash
   just quick-deploy p510
   ```

3. Confirm encryption is active and pick up the generated key:

   ```bash
   ssh p510 'sudo k3s secrets-encrypt status'
   # Encryption Status: Enabled
   # Current Rotation Stage: start
   # Active Key ... aescbc
   ```

4. Encrypt all **existing** Secrets (new ones are encrypted automatically; old
   ones were written plaintext and must be rewritten):

   ```bash
   ssh p510 'sudo k3s secrets-encrypt reencrypt'
   ```

   For a vanilla kube-apiserver (non-k3s-managed) the equivalent is
   `kubectl get secrets -A -o json | kubectl replace -f -` after installing the
   `EncryptionConfiguration` and pointing `--encryption-provider-config` at it.

5. Verify a secret is now ciphertext in the datastore:

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
(`/mnt/img_pool/k3d/storage` on p510).

1. **Back up everything first.** Trigger a fresh Postgres backup
   (`apps/backups`) and confirm the object is in `factory-backups`, then copy it
   off-cluster. PVC data is destroyed by this procedure.

2. Drain the workloads:

   ```bash
   ssh p510
   sudo systemctl stop k3d-cluster-bootstrap   # or: kubectl -n factory scale deploy,statefulset --all --replicas=0
   ```

3. Create a LUKS container on a spare disk/partition (or a backing file for a
   lab node), open it, format, and mount it at the storage path:

   ```bash
   sudo cryptsetup luksFormat /dev/<disk>           # choose a strong passphrase / key file
   sudo cryptsetup luksOpen  /dev/<disk> factory-data
   sudo mkfs.ext4 /dev/mapper/factory-data
   sudo mount /dev/mapper/factory-data /mnt/img_pool/k3d/storage
   ```

4. Persist it declaratively in nixos_config (this is the NixOS way — do not do it
   imperatively long-term): add the device to
   `boot.initrd.luks.devices."factory-data"` (or `environment.etc.crypttab`) with
   a key file under agenix, and a `fileSystems."/mnt/img_pool/k3d/storage"` entry
   depending on the mapper device. Deploy with `just quick-deploy p510`.

5. Restore data: bring the cluster back up
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

1. **Now (this PR):** MinIO SSE-S3 — manifests, reviewable, no node action.
2. **Next maintenance window:** etcd secrets encryption — one k3s flag +
   reencrypt, low risk, big win for the Secret-in-etcd exposure.
3. **Planned maintenance window with backup:** node LUKS under the local-path
   directory — the broad control that finally covers Postgres.

Each step is independently valuable and independently reversible-ish; do them in
that order because the risk/disruption grows down the list.
