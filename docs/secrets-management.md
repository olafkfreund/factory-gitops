# Secrets management

How secrets are handled in the factory cluster today, a full inventory, a
rotation runbook, and the recommended path to encrypting them in git
(Factory#315, part of the compliance program #310).

## How it works today (be honest)

Every Kubernetes Secret in the `factory` namespace is created **out of band** —
it is NOT in this GitOps repo. The pattern, repeated in the header of every app
that needs one (`apps/minio`, `apps/postgres`, `apps/cfactory-auth`,
`apps/observe-auth`, `apps/odin-auth`, ...):

1. The plaintext value lives in **agenix** in the nixos_config repo, edited on
   p510 with `scripts/manage-secrets.sh edit <name>`. agenix encrypts it to the
   recipient set (one user key plus the p510 and p620 host keys — see
   [Decryption-key custody](#decryption-key-custody)); the ciphertext (`*.age`)
   is what is committed to nixos_config.
2. On cluster bootstrap, a script on p510 decrypts the agenix secret and runs
   `kubectl create secret ...` to materialise it in etcd.
3. From then on the Secret lives only in etcd (base64, **not encrypted** — see
   `docs/encryption-at-rest.md`) and the running pods that mount it.

Correcting the record: there is **no SOPS and no sealed-secrets** in this repo
today, despite claims elsewhere in the program. The real mechanism is agenix
(encrypted to the recipient set: one user key plus the p510 and p620 host keys;
see [Decryption-key custody](#decryption-key-custody)) + out-of-band
`kubectl create secret`. This doc is written against that reality.

Consequences:

- Secrets are **not in git**, so they are not encrypted-in-git — the flip side
  is there is also no in-git audit trail or review of secret *rotation*.
- A cluster rebuild depends on the bootstrap re-creating every Secret; a Secret
  whose key drifts from what a consumer expects fails silently (this exact class
  of bug bit the KEDA scaler — see `apps/keda/scaledobjects/triggerauthentication.yaml`).
- No secret rotates itself for good. The cred-broker CronJob only refreshes a
  `claude auth login` credential until its fixed ~30-day lineage ends and watches the
  expiry of a `claude setup-token` one; both need a human re-seed
  ([Re-seeding](#re-seeding-the-claude-oauth-credential)). Everything else is manual,
  on the schedule in [Rotation policy](#rotation-policy).

## Inventory

Every Secret consumed by a workload in this repo. "Owner" = who rotates it.
All are namespace `factory` and seeded via agenix on p510 unless noted.

| Secret | Keys | Consumers | Rotation owner / mechanism |
|--------|------|-----------|----------------------------|
| `factory-secrets` | POSTGRES_PASSWORD, GITHUB_TOKEN, APP_API_TOKEN, CFACTORY_READ_KEY, AIFACTORY_TRUSTED_PLAN_KEY_PFACTORY, PFACTORY_CONTRACT_SIGNING_KEY__PF-2026-10 (Ed25519 seed, TFactory#1432), {PFACTORY,TFACTORY,AIFACTORY}_JWT_SECRET, {PFACTORY,TFACTORY,AIFACTORY}_OIDC_CLIENT_SECRET, OPENAI_API_KEY, OPENAI_COMPATIBLE_API_KEY, GEMINI_API_KEY, CONTEXT7_KEY, LANGCHAIN_API_KEY, RAPIDAPI_KEY, CLAUDE_CODE_OAUTH_TOKEN, OLLAMA_API_KEY, CFACTORY_AUDIT_HMAC_SECRET, CFACTORY_CREDENTIAL_KEY, KMS_FERNET_KEY (aifactory at-rest key; rotation re-encrypts, see AIFactory `python -m server.crypto`) | pfactory, tfactory, aifactory, cfactory, backups, keda triggerauth | Manual (agenix). The catch-all secret — highest blast radius. |
| `minio-creds` | S3_ACCESS_KEY, S3_SECRET_KEY | minio, minio bucket-init, pfactory, tfactory, aifactory, backups | Manual (agenix). Rotate = recreate + bounce minio and every consumer. |
| `minio-kms` | MINIO_KMS_SECRET_KEY | minio | Manual (agenix). The object-encryption KEK — see docs/encryption-at-rest.md; compromise-only rotation, see [Rotation policy](#rotation-policy). |
| `factory-cli-creds` | claude-credentials.json (+ codex/copilot/gemini keys) | pfactory, tfactory, aifactory (mounted) | Claude credential: `claude setup-token` (about 1 year) re-seeded by hand; cred-broker (`apps/cred-broker`) watches the expiry and refreshes only an `auth login` credential. Others manual. |
| `factory-db-pfactory` | DATABASE_URL | pfactory | Manual (agenix). Derived from POSTGRES_PASSWORD; rotate together. |
| `factory-db-tfactory` | DATABASE_URL | tfactory | Manual (agenix). As above. |
| `factory-db-aifactory` | DATABASE_URL | aifactory | Manual (agenix). As above. |
| `cfactory-api-keys` | api-key, api-keys | cfactory, audit-anchor-alert | Manual (agenix). |
| `oauth2-proxy-cfactory` | cookie-secret, client-secret | cfactory-auth | Manual (agenix). |
| `oauth2-proxy-observe` | client-id, client-secret, cookie-secret | observe-auth | Manual (agenix). |
| `oauth2-proxy-odin` | client-id, client-secret, cookie-secret | odin-auth | Manual (agenix). |
| `observe-root` | email, password | observe (OpenObserve) | Manual (agenix). |
| `odin-ssh-key` | SSH key material (mounted as `secretName`) | odin | Manual (agenix). |
| `otel-otlp-auth` | headers | aifactory (OTLP export) | Manual (agenix). |

Operator-managed, not in scope for this inventory (created by their own
controllers, not the app-seeding path): `kedaorg-certs` (KEDA operator TLS),
`argocd-initial-admin-secret` (ArgoCD).

### Observations from the inventory

- `factory-secrets` is a **god-secret**: 20+ keys, 6 consumers, one blast radius.
  A leak of any one key means recreating the whole Secret and bouncing six
  workloads. Splitting it is a natural follow-up but out of scope here.
- `POSTGRES_PASSWORD` appears in three places that must stay in sync:
  `factory-secrets` (Postgres server + KEDA), the three `factory-db-*`
  DATABASE_URLs, and any manual psql. Rotating it is a multi-step dance
  (below) — a good argument for the ESO/SOPS templating recommended below.
- Nothing self-heals past a credential's own expiry: the Claude token needs a
  re-seed (about yearly with `setup-token`) and every other credential is a manual rotation.

## The last-applied-configuration annotation

Client-side `kubectl apply` copies the **entire submitted manifest** — including
every plaintext value in `.data` — into the annotation
`kubectl.kubernetes.io/last-applied-configuration`. ArgoCD's default sync does
the same. `kubectl create`, `kubectl patch` and `kubectl apply --server-side` do
not.

This defeats the redaction people rely on. `kubectl describe secret` redacts
`.data` but **prints annotations**, and RBAC/audit tooling is routinely written
treating `.data` as the sensitive field and metadata as safe. Anyone who can
`get` or `describe` a Secret reads the value.

A sweep on 2026-08-05 found **25 Secrets / 83 keys** leaking this way, including
`factory-secrets` (the fleet credential bundle), `argocd-secret` (ArgoCD's own
signing material), and `ghcr-pull` (a near-admin GitHub PAT). An earlier one-time
sweep had been undone within a day by a single `kubectl apply`, because the cause
is the write path, not any individual Secret.

**This is now enforced, not remembered.** The Kyverno ClusterPolicy
`strip-last-applied-configuration-from-secrets`
(`apps/kyverno-policies/manifests/`) removes the annotation from every Secret on
CREATE and UPDATE, in every namespace except `kube-system` and `kyverno`. It is
`failurePolicy: Ignore` on purpose: a Kyverno outage must degrade the stripping,
never block Secret writes cluster-wide. Read the header comment in that file
before changing it.

Two consequences to expect, both benign:

- Every `kubectl apply` onto an existing Secret now prints a warning that the
  annotation is missing and will be patched automatically. That warning is the
  policy working. The apply succeeds.
- Client-side apply uses this annotation to decide which fields to **delete**.
  With it always absent, apply falls back to a two-way merge, so a key removed
  from a manifest is no longer removed from the live Secret. Use
  `kubectl apply --server-side` if you need that, or delete the key explicitly.

Audit at any time — this must print nothing:

```bash
kubectl --context k3d-factory get secrets -A -o json | jq -r '
  .items[]
  | select(.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")
  | select(.type != "kubernetes.io/service-account-token")
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

Remove it from an existing Secret in place, without recreating it or touching
`.data`:

```bash
kubectl -n <ns> annotate secret <name> \
  kubectl.kubernetes.io/last-applied-configuration-
```

Refs Factory#565, Factory#448.

## Rotation runbook

General shape for the manual (agenix) secrets:

1. Generate the new value.
2. `cd ~/.config/nixos && ./scripts/manage-secrets.sh edit <agenix-name>` on the
   machine holding the agenix recipients; paste the new value.
3. `just quick-deploy p510` so the bootstrap re-materialises the Secret, OR
   patch it directly for a hot rotation — **merge one key, never a bare recreate
   that clobbers sibling keys**:

   ```bash
   kubectl -n factory patch secret <name> --type=merge \
     -p "{\"stringData\":{\"<KEY>\":\"$(cat /dev/shm/newvalue)\"}}"
   ```

   Do NOT use the older `create --dry-run=client -o yaml | kubectl apply -f -`
   pipeline that used to be documented here. Client-side `kubectl apply` writes
   the **complete submitted manifest, including the plaintext value**, into the
   `kubectl.kubernetes.io/last-applied-configuration` annotation — see
   "The last-applied-configuration annotation" below. `kubectl patch` merges
   sibling keys correctly and never writes that annotation.
4. Bounce the consumers so they pick up the new env/mount:
   `kubectl -n factory rollout restart deploy/<svc> statefulset/<svc>`.
5. Where the credential is external (GitHub PAT, an LLM API key), revoke the old
   one at the provider **after** the new one is confirmed working.
6. Stamp the Secret (see [Rotation age report](#rotation-age-report)) and update the
   ledger row in the same window. Re-stamp after any recreate of the Secret, because a
   recreate drops the annotation.

### Per-secret specifics

- **POSTGRES_PASSWORD** (the tricky one — three consumers must stay in sync):
  1. Change it in `factory-secrets`.
  2. `ALTER USER factory WITH PASSWORD '<new>';` inside the running Postgres pod.
  3. Update all three `factory-db-*` `DATABASE_URL`s with the new password.
  4. Restart Postgres consumers AND the KEDA operator picks the new password up
     from `factory-secrets` via the shared TriggerAuthentication.
  Order matters: change the DB password and the Secrets in the same window, or
  connections fail in between.

- **minio-creds**: recreate the Secret, then
  `kubectl -n factory rollout restart deploy/minio` and every S3 consumer
  (pfactory/tfactory/aifactory/backups). MinIO root creds change = all clients
  must present the new key.

- **minio-kms** (the KEK): compromise-only, never a plain swap — see the
  emergency path in [Rotation policy](#rotation-policy).

- **factory-cli-creds** (Claude OAuth): a `claude setup-token` credential lasts about
  a year; cred-broker only watches it. Needs a human at expiry. Full procedure in
  [Re-seeding the Claude OAuth credential](#re-seeding-the-claude-oauth-credential).

- **oauth2-proxy-\*** cookie-secret: must be a 16/24/32-byte value; regenerate
  with `openssl rand -base64 32 | head -c 32`, then restart the proxy.

## Rotation policy

| Class | Credentials | Max age | How it rotates |
|---|---|---|---|
| JWT signing secrets | `{P,T,AI}FACTORY_JWT_SECRET` | 365d | Plain swap and bounce. Every session in that service is logged out. |
| External API keys/tokens | `GITHUB_TOKEN`, `OPENAI_API_KEY`, `OPENAI_COMPATIBLE_API_KEY`, `GEMINI_API_KEY`, `CONTEXT7_KEY`, `LANGCHAIN_API_KEY`, `RAPIDAPI_KEY`, `OLLAMA_API_KEY`, `ghcr-pull` | 365d, or the provider's expiry if sooner | Swap, bounce, then revoke the old key at the provider. |
| Shared service tokens | `APP_API_TOKEN`, `CFACTORY_READ_KEY`, `cfactory-api-keys` | 365d | Shared by several callers and verifiers (e.g. `APP_API_TOKEN` across all three factories). Find every consumer with `grep -rn <KEY> apps/`, swap the token in all of them in one window, then bounce. |
| OIDC client secrets | `{P,T,AI}FACTORY_OIDC_CLIENT_SECRET`, `oauth2-proxy-*` client-secret | 365d | Regenerate in Keycloak (the issuer) first, then swap and bounce. |
| Proxy cookie secrets | `oauth2-proxy-*` cookie-secret | 365d | Swap and bounce. Every proxy session is logged out. The ledger has one row per proxy, so rotate its client-secret and cookie-secret in the same window before updating that row. |
| Outbound auth to another system | `otel-otlp-auth`, `observe-root` | 365d | Change the credential on the receiving service first, then swap and bounce. |
| SSH identity | `odin-ssh-key` | 365d | Generate a new key pair, authorize the new public key at the destination, swap and bounce, then remove the old public key at the destination. |
| DB / object-store creds | `POSTGRES_PASSWORD` + the three `factory-db-*` (one atomic group), `minio-creds` | 365d | Existing per-secret runbook. |
| HMAC keys | `AIFACTORY_TRUSTED_PLAN_KEY_PFACTORY` | 365d | Swap on both pfactory and aifactory in one window. |
| HMAC keys | `CFACTORY_AUDIT_HMAC_SECRET` | **compromise only** | The audit chain is HMAC'd with one unkeyed secret (`CFactory/apps/backend/cfactory/config.py`), so a swap makes every earlier entry unverifiable. Scheduled rotation waits on a key-id'd chain (follow-up, not here). |
| Asymmetric signing | `PFACTORY_CONTRACT_SIGNING_KEY__<KID>` | 365d | **New kid, never overwrite.** Order: (1) add the new seed to `factory-secrets` under the new kid; (2) deploy the new pubkey `TFACTORY_CONTRACT_PUBKEY_PFACTORY__<NEW>` to the verifier, next to the old one; (3) point pfactory's env at the new seed and `PFACTORY_CONTRACT_SIGNING_KID` (a manifest PR); (4) confirm a new contract verifies; (5) delete the old seed. Keep the old pubkey while any contract signed with it may still need verifying. |
| Data-encryption roots | `KMS_FERNET_KEY` (aifactory) | 365d | Envelope: `python -m server.crypto rotate-root` with `KMS_FERNET_KEY_NEW` set re-wraps the data keys, then the env is flipped (AIFactory `server/crypto/__main__.py`). |
| Data-encryption roots | `CFACTORY_CREDENTIAL_KEY` | 365d | Multi-key: prepend `<new-id>:<key>,`, keeping old ids listed until records are re-wrapped (`cfactory/config.py`). |
| Data-encryption roots | `minio-kms` KEK | **compromise only** | Single-key mode can't hold old and new at once, so there's no scheduled rotation until KES. On compromise, follow the emergency runbook (untested, needs downtime) in [`encryption-at-rest.md`](encryption-at-rest.md#kek-compromise-emergency-re-encryption-untested). |
| Claude OAuth | `factory-cli-creds`, `CLAUDE_CODE_OAUTH_TOKEN` | ~360d (`setup-token`) | Manual re-seed; cred-broker opens an issue when the expiry is near. See [Re-seeding](#re-seeding-the-claude-oauth-credential). |

Triggers that force an immediate rotation, whatever the age: suspected or
confirmed leak (including a value seen in a log, an annotation or a
`last-applied-configuration`); compromise or decommission of an agenix
recipient that could decrypt it (see [Decryption-key custody](#decryption-key-custody));
departure of anyone who held it; a provider notice. A compromise-only row still
rotates on these triggers. It just has no schedule.

### Rotation age report

The CronJob `secret-rotation-report` (`apps/secret-rotation`, daily 06:00 UTC) reads one
metadata annotation per Secret in `factory`, compares its age to the policy, writes one
`job_health` record per Secret (`kind: secret_rotation`) and opens one GitHub issue (label
`secret-rotation`) per overdue Secret. It never rotates anything and never reads a value: it asks the API
for metadata only. Policy and owners: Factory
[`docs/compliance/policies/key-rotation.md`](https://github.com/olafkfreund/Factory/blob/main/docs/compliance/policies/key-rotation.md).

After a rotation, stamp the Secret with the **oldest evidenced last-rotated date among every
credential still in it that has a scheduled interval** (not the compromise-only `CFACTORY_AUDIT_HMAC_SECRET`), taken from the ledger rows (not necessarily today: rotating the oldest key
leaves the next-oldest as the stamp):

```bash
kubectl --context k3d-factory -n factory annotate secret <name> --overwrite \
  rotation.factory.dev/rotated-at=<YYYY-MM-DD>
```

Stamping without a rotation does not make a credential newer, it only silences the report; the ledger
is the record. An unstamped Secret is measured from the policy start (2026-11-07). Max age is 90 days for
`factory-secrets` (API tokens, runbook R-016) and 365 days for the other listed Secrets; the ledger
rows for tokens inside `factory-secrets` still say 365 and should be aligned by the owner. Read the
latest result with `kubectl -n factory logs job/<latest secret-rotation-report job>` or the `job_health` stream.

## Rotation ledger

Each row below is one rotation unit (an individual key in `factory-secrets`, a
standalone Secret such as `oauth2-proxy-*`, or an atomic group rotated together
like `POSTGRES_PASSWORD + factory-db-*`). Rows with `Last rotated` set to
`unknown` are measured from the policy start date (`2026-11-07`). A row's
deadline is `(Last rotated, or 2026-11-07 for unknown) + Max age`, or `Expires`
if earlier; it is overdue when `today > deadline` (`none` means compromise-only,
no scheduled deadline unless `Expires` is set). Update the row in the same
change window as the rotation; removing a row needs a PR that says why. Checked
weekly by `.github/workflows/secret-rotation-due.yml` via
`scripts/rotation-ledger-check.py`.

<!-- rotation-ledger:start -->
| Credential | Max age (days) | Last rotated | Expires |
| --- | --- | --- | --- |
| `PFACTORY_JWT_SECRET` | 365 | unknown | - |
| `TFACTORY_JWT_SECRET` | 365 | unknown | - |
| `AIFACTORY_JWT_SECRET` | 365 | unknown | - |
| `GITHUB_TOKEN` | 365 | unknown | - |
| `OPENAI_API_KEY` | 365 | unknown | - |
| `OPENAI_COMPATIBLE_API_KEY` | 365 | unknown | - |
| `GEMINI_API_KEY` | 365 | unknown | - |
| `CONTEXT7_KEY` | 365 | unknown | - |
| `LANGCHAIN_API_KEY` | 365 | unknown | - |
| `RAPIDAPI_KEY` | 365 | unknown | - |
| `OLLAMA_API_KEY` | 365 | unknown | - |
| `ghcr-pull` | 365 | unknown | - |
| `APP_API_TOKEN` | 365 | unknown | - |
| `CFACTORY_READ_KEY` | 365 | unknown | - |
| `cfactory-api-keys` | 365 | unknown | - |
| `PFACTORY_OIDC_CLIENT_SECRET` | 365 | unknown | - |
| `TFACTORY_OIDC_CLIENT_SECRET` | 365 | unknown | - |
| `AIFACTORY_OIDC_CLIENT_SECRET` | 365 | unknown | - |
| `oauth2-proxy-cfactory` | 365 | unknown | - |
| `oauth2-proxy-observe` | 365 | unknown | - |
| `oauth2-proxy-odin` | 365 | unknown | - |
| `observe-root` | 365 | unknown | - |
| `otel-otlp-auth` | 365 | unknown | - |
| `odin-ssh-key` | 365 | unknown | - |
| `POSTGRES_PASSWORD + factory-db-*` | 365 | unknown | - |
| `minio-creds` | 365 | unknown | - |
| `AIFACTORY_TRUSTED_PLAN_KEY_PFACTORY` | 365 | unknown | - |
| `PFACTORY_CONTRACT_SIGNING_KEY__PF-2026-10` | 365 | unknown | - |
| `KMS_FERNET_KEY` | 365 | unknown | - |
| `CFACTORY_CREDENTIAL_KEY` | 365 | unknown | - |
| `CFACTORY_AUDIT_HMAC_SECRET` | none | unknown | - |
| `minio-kms` | none | unknown | - |
<!-- rotation-ledger:end -->

## Decryption-key custody

Secrets in `nixos_config` are encrypted with agenix to the recipient set
`allUsers ++ [ p510 p620 ]` (one user key plus two host keys). No key material
or fingerprints belong in this repo.

- **p510 identities:** the operator user SSH key (`~/.ssh/id_ed25519`) plus the
  host ed25519 and RSA keys (`/etc/ssh/ssh_host_*_key`).
- **p620 identities:** host SSH keys only.
- **Loss of one identity:** recoverable as long as any remaining recipient key
  survives — update `secrets.nix` and re-key with `agenix -r`.
- **Loss of all identities:** before any cluster rebuild, a recovery window
  remains through the live Kubernetes Secrets still present in etcd
  (`kubectl --context k3d-factory -n factory get secret ... -o yaml`), which can be
  used to re-seed agenix under new recipient keys. If that window closes, every
  `factory-secret-*.age` is unreadable and the MinIO KEK, and with it every
  encrypted object, is gone.
- **Compromise of an identity:** remove the compromised recipient from
  `secrets.nix`, run `agenix -r`, **and** rotate every secret value that
  recipient could ever decrypt. Re-keying alone is not enough because git
  history in `nixos_config` retains the old ciphertext.
- **Identity rotation:** recipient keys rotate on immediate-rotation triggers,
  host reinstall, or host decommission, with no fixed schedule.
- **Offline backup:** keep an offline backup of at least one decrypting identity
  outside the cluster hosts. This repo cannot verify that one exists; the
  operator must confirm it.
- **MinIO KEK (`minio-kms`):** for object-encryption KEK custody and limits, see
  [`docs/encryption-at-rest.md`](encryption-at-rest.md#key-custody-the-kek).

### Custody register

No key material or fingerprints here; the register names where each decrypting identity lives and what it recovers. The owner keeps it current (Factory#314).

| Identity | Held by | Where | Decrypts | Recovery use |
|---|---|---|---|---|
| Operator user key | owner | `~/.ssh/id_ed25519` on p510 | every `factory-secret-*.age` | day-to-day `manage-secrets.sh edit` |
| p510 host key | host | `/etc/ssh/ssh_host_*_key` | every `factory-secret-*.age` at activation | boot-time seeding of Secrets |
| p620 host key | host | `/etc/ssh/ssh_host_ed25519_key` | every `factory-secret-*.age` at activation | boot-time seeding on p620 |
| Offline backup identity | owner | outside both hosts (**owner to name the place**) | every `factory-secret-*.age` | rebuild after losing all three above |

### Check the offline backup (owner, read-only)

This proves the backup identity decrypts the KEK slot without printing it. It prints a byte count only:

```bash
cd ~/.config/nixos
age -d -i /path/to/offline-backup-identity secrets/factory-secret-minio-kms.age | wc -c
```

Expect a non-zero count (about 60 for `factory-kek-1:<base64>`). An error means the backup is not a recipient: add it to `secrets.nix`, then re-key as below. Record the date and where the backup lives in the register row, not the key.

### Rotate or retire an identity (owner)

Run in the `nixos_config` checkout, in the directory that holds `secrets.nix` (find it with `git ls-files | grep secrets.nix`), on a host whose identity is still a recipient:

1. Edit `secrets.nix`: add the new public key or remove the old one. Public keys only.
2. Re-key every `.age` file to the new recipient set: `agenix -r -i ~/.ssh/id_ed25519`.
3. Check one file with the new identity (command above), commit the re-keyed `.age` files, deploy the hosts (`just quick-deploy p510`, then p620).
4. If the identity was retired because it was compromised, re-keying is not enough: git history keeps the old ciphertext, so rotate every value that identity could decrypt, in the order of [Rotation policy](#rotation-policy) (the `minio-kms` KEK last, through its cutover runbook).
5. Update the register row and the date. Remove the old private key from where it lived.

Scheduled rotation of identities is not required (no fixed interval); the triggers are in the bullets above.

## Re-seeding the Claude OAuth credential

The broker opens a GitHub issue (label `cred-broker`, on `ALERT_REPO`) on the first
refresh rejected with `invalid_grant`, and on any other failed refresh while the
access token has `ALERT_WITHIN_HOURS` (default 5) or less left. For a refreshable
(`auth login`) credential it also opens one 7 days before, or after, the refresh token's own
expiry (`refresh-token-expiring`, date in `last-detail`). The body carries
`last-outcome`, `access-expires-at` and a pointer to this section (Factory#3687). It needs
`factory-secrets/GITHUB_TOKEN`; without it the broker logs `alerting inert` and still
rotates. It raises nothing for a long-lived credential (more than 30 days left).

### First: read what the broker already told you

Since Factory#437 the broker records every run on the Secret itself, so this
works with no surviving pod:

```sh
kubectl --context k3d-factory -n factory get secret factory-cli-creds \
  -o jsonpath='{.metadata.annotations.cred-broker\.factory\.dev/last-outcome}{"\n"}{.metadata.annotations.cred-broker\.factory\.dev/access-expires-at}{"\n"}'
```

- `access-expires-at` is the **access token** expiry, and it decides urgency.
  A failing broker with months left on that date is a broken rotation, not an
  outage — do not treat it as one.
- `last-outcome` of `refresh-rejected:invalid_grant` (dead lineage) or `no-refresh-token`
  (a `setup-token` credential 30 days from expiry) is what this section covers. While a
  refresh still works, `last-outcome` stays `ok` and the warning shows only in
  `cred-broker.factory.dev/last-detail` (`refresh token expires <date>`).

### Why the credential dies (Factory#3687)

A `claude auth login` refresh-token lineage has a **fixed lifetime of about 30 days from the
login**. Rotating the refresh token does not extend it, so the broker cannot keep an
`auth login` credential alive: the file carries `claudeAiOauth.refreshTokenExpiresAt`, and
the first `invalid_grant` ("Refresh token expired") comes shortly after that date. This is
why the credential seeded on 2026-10-06 stopped on 2026-11-05. Earlier incidents were mostly
cluster rebuilds and outages, not expiries.

### Which login flow

| Flow | Lifetime | Refresh | Owner effort |
|---|---|---|---|
| `claude setup-token` (**default**) | about 1 year | none; the broker reports `not-applicable:long-lived-credential` | one re-seed a year |
| `claude auth login` (alternative) | access 8h, refresh lineage about 30 days | broker refreshes every 4h, cannot extend the lineage | re-login about every 30 days; broker issue 7 days ahead |

A setup-token is inference-only (scope `user:inference`); nothing in this repo needs more.
It is valid for a year if leaked, so treat it like any long-lived secret. Keep the broker
scheduled with a setup-token: at 30 days of runway or less it goes red (`no-refresh-token`)
and opens the issue, which is the yearly reminder.

### Procedure (default: setup-token)

Rotate **both** Secrets. `factory-secrets/CLAUDE_CODE_OAUTH_TOKEN` and
`factory-cli-creds/claude-credentials.json` must carry the same token: the Claude SDK
reads the mounted **file**, so fixing only the env var looks like it worked and does not.
Run the kubectl steps on the host that has the `k3d-factory` context (p620) and step 3 where you
edit agenix. Never paste the token into a command line, a log or an issue.

0. Optional: print only the dead credential's refresh expiry date.

   ```sh
   kubectl --context k3d-factory -n factory get secret factory-cli-creds \
     -o jsonpath='{.data.claude-credentials\.json}' | base64 -d \
     | jq -r '(.claudeAiOauth.refreshTokenExpiresAt // empty) / 1000 | todate'
   ```

1. Mint the token (browser flow, shown once) and hold it without echo or history:

   ```bash
   claude setup-token
   read -rs TOK; test -n "$TOK" || echo "empty: stop"
   ```

2. Patch both Secrets. `expiresAt` is epoch milliseconds, 360 days out, so the broker's
   reminder fires early rather than late:

   ```sh
   EXP=$(( ($(date +%s) + 360*86400) * 1000 ))
   kubectl --context k3d-factory -n factory patch secret factory-cli-creds \
     --type merge --patch-file /dev/stdin <<EOF
   {"data":{"claude-credentials.json":"$(printf %s "$TOK" | jq -Rsc --argjson e "$EXP" \
     '{claudeAiOauth:{accessToken:.,expiresAt:$e,scopes:["user:inference"]}}' | base64 -w0)"}}
   EOF
   kubectl --context k3d-factory -n factory patch secret factory-secrets \
     --type merge --patch-file /dev/stdin <<EOF
   {"data":{"CLAUDE_CODE_OAUTH_TOKEN":"$(printf %s "$TOK" | base64 -w0)"}}
   EOF
   ```

3. Make it survive a reboot. `factory-secrets` is re-applied from agenix on every boot, and
   a cluster rebuild seeds `factory-cli-creds` from the agenix slot or the host snapshot,
   whichever is fresher. In `~/.config/nixos`:
   `./scripts/manage-secrets.sh edit factory-secret-factory-secrets` (interactive terminal),
   set `CLAUDE_CODE_OAUTH_TOKEN` to the same token, and refresh the
   `factory-secret-factory-cli-creds` slot from the live Secret; commit the `.age` files.
   Then `unset TOK`.

4. Confirm the broker before waiting 4h for the schedule:

   ```sh
   J=cred-broker-verify-$(date +%s)   # fresh name: a reused one can show an old outcome
   kubectl --context k3d-factory -n factory create job $J --from=cronjob/cred-broker
   kubectl --context k3d-factory -n factory wait --for=condition=complete job/$J --timeout=120s
   kubectl --context k3d-factory -n factory get secret factory-cli-creds \
     -o jsonpath='{.metadata.annotations.cred-broker\.factory\.dev/last-outcome}{"\n"}'
   ```

   Expect `not-applicable:long-lived-credential`. The annotation is the check that works
   even though the pod is deleted on failure (Factory#438).

5. Roll the consumers, after announcing it on the agent bus. This is required, not optional:
   cred-sync refuses a seed more than 90 days fresher than the file already in a pod, so
   running pods will not adopt the one-year file; a fresh pod's seed step copies it directly.

   ```sh
   kubectl --context k3d-factory -n factory rollout restart deploy/pfactory deploy/tfactory deploy/aifactory
   ```

6. Check TFactory accepts it (its `/v1/models` probe):

   ```sh
   kubectl --context k3d-factory get --raw \
     /api/v1/namespaces/factory/services/tfactory:3103/proxy/api/health \
     | jq '.. | objects | select(has("validity"))'
   ```

   Expect `"validity": "valid"`. Then close the `cred-broker` issue.

### Alternative: `claude auth login` (re-login about every 30 days)

Same two Secrets, same verify and roll steps; only the credential differs.

1. On a machine with the CLI, `claude auth login`. This writes `~/.claude/.credentials.json`.

2. Patch the file into `factory-cli-creds` without clobbering the sibling
   codex/copilot/gemini keys. Keep the value off the command line:

   ```sh
   kubectl --context k3d-factory -n factory patch secret factory-cli-creds \
     --type merge --patch-file /dev/stdin <<EOF
   {"data":{"claude-credentials.json":"$(base64 -w0 ~/.claude/.credentials.json)"}}
   EOF
   ```

3. Patch the matching access token into `factory-secrets`:

   ```sh
   kubectl --context k3d-factory -n factory patch secret factory-secrets \
     --type merge --patch-file /dev/stdin <<EOF
   {"data":{"CLAUDE_CODE_OAUTH_TOKEN":"$(python3 -c 'import json,base64,os;print(base64.b64encode(json.load(open(os.path.expanduser("~/.claude/.credentials.json")))["claudeAiOauth"]["accessToken"].encode()).decode())')"}}
   EOF
   ```

4. Do steps 4 (verify, expect `ok`), 5 (roll the consumers) and 6 (TFactory check, close the
   issue) above. Skip the agenix slots for the credential file: the broker rotates its refresh
   token every 4h, so a stored copy is dead within hours (set only `CLAUDE_CODE_OAUTH_TOKEN`
   from the access token if you want it to survive a reboot). Put the login date in your
   calendar: the broker's issue arrives 7 days before the lineage ends.

### Do not share this credential with a workstation (`auth login` only)

The broker's whole design is that the Secret is the *single* refresher, because
Anthropic rotates the refresh token on every grant and the loser of that race
gets `invalid_grant`. A laptop running `claude` against the same credential
lineage is another refresher and will break the broker within one access TTL.
Seed the cluster from its own login.

## Recommendation: encrypt secrets in git (adopt SOPS or ESO)

The gap (#315) is that secrets are **not in git** and therefore not
encrypted-in-git, not reviewable, and not reproducible without the out-of-band
bootstrap. Two credible fixes, both keep plaintext out of git:

1. **SOPS + age (recommended first move).** It is the smallest step from where we
   already are — the cluster already uses **age keys** via agenix, so the same
   recipient keys can decrypt SOPS files. Encrypt a Secret manifest with SOPS,
   commit the ciphertext, and let either the SOPS ArgoCD plugin (ksops /
   argocd-vault-plugin) or a `sops -d` bootstrap step materialise it. Values are
   encrypted per-key, so diffs stay reviewable. No new operator to run, no new
   trust root — reuse the age keys.

2. **External Secrets Operator (ESO) or sealed-secrets (heavier).** ESO syncs
   from an external store (Vault, cloud KMS); sealed-secrets encrypts to a
   controller-held key. Both add a controller to run and, for ESO, an external
   store to stand up. More robust for many teams / rotation automation, more
   moving parts than a single-node lab needs right now.

**Recommendation:** adopt **SOPS + age** because it reuses the existing agenix
age keys and adds no new controller — the laziest change that closes the
"encrypted in git" gap. Graduate to ESO only if/when automatic rotation from an
external store becomes a requirement.

### Concrete first migration candidate

Migrate **`minio-kms`** (the MinIO KEK) first:

- It has exactly one key and one consumer — the smallest possible blast radius,
  so a botched migration is trivially recoverable.
- It has no scheduled rotation, so there is no rotation habit to disrupt.
- It proves the whole SOPS-in-ArgoCD path end to end (encrypt, commit, decrypt
  on sync, pod picks it up) on a secret whose failure mode is contained to MinIO,
  before touching the god-secret `factory-secrets`.

Migration sketch (do this in a follow-up PR, not here):

```bash
# encrypt the Secret manifest to the cluster's age recipient
sops --encrypt --age <cluster-age-pubkey> \
  --encrypted-regex '^(data|stringData)$' \
  apps/minio/secret.minio-kms.yaml > apps/minio/secret.minio-kms.enc.yaml
# commit the .enc.yaml; wire ksops/avp into the minio Application; drop the
# out-of-band kubectl-create step from the bootstrap for this one secret.
```

Once `minio-kms` is proven, migrate the rest in order of blast radius, ending
with `factory-secrets`. Do **not** rotate or touch existing live Secrets as part
of adopting SOPS — migrate the *storage* of the value, then rotate on the normal
schedule.

## Non-goals of this document

- It does not rotate any live secret.
- It does not modify or delete any existing Secret.
- It does not stand up SOPS/ESO — it recommends the approach and names the first
  candidate. Implementation is a tracked follow-up to #315.
