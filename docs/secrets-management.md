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
   host's age key; the ciphertext (`*.age`) is what is committed to nixos_config.
2. On cluster bootstrap, a script on p510 decrypts the agenix secret and runs
   `kubectl create secret ...` to materialise it in etcd.
3. From then on the Secret lives only in etcd (base64, **not encrypted** — see
   `docs/encryption-at-rest.md`) and the running pods that mount it.

Correcting the record: there is **no SOPS and no sealed-secrets** in this repo
today, despite claims elsewhere in the program. The real mechanism is agenix
(host key) + out-of-band `kubectl create secret`. This doc is written against
that reality.

Consequences:

- Secrets are **not in git**, so they are not encrypted-in-git — the flip side
  is there is also no in-git audit trail or review of secret *rotation*.
- A cluster rebuild depends on the bootstrap re-creating every Secret; a Secret
  whose key drifts from what a consumer expects fails silently (this exact class
  of bug bit the KEDA scaler — see `apps/keda/scaledobjects/triggerauthentication.yaml`).
- Only **one** secret rotates automatically (the Claude OAuth cred, via the
  cred-broker CronJob). Everything else is manual.

## Inventory

Every Secret consumed by a workload in this repo. "Owner" = who rotates it.
All are namespace `factory` and seeded via agenix on p510 unless noted.

| Secret | Keys | Consumers | Rotation owner / mechanism |
|--------|------|-----------|----------------------------|
| `factory-secrets` | POSTGRES_PASSWORD, GITHUB_TOKEN, APP_API_TOKEN, CFACTORY_READ_KEY, AIFACTORY_TRUSTED_PLAN_KEY_PFACTORY, {PFACTORY,TFACTORY,AIFACTORY}_OIDC_CLIENT_SECRET, OPENAI_API_KEY, OPENAI_COMPATIBLE_API_KEY, GEMINI_API_KEY, CONTEXT7_KEY, LANGCHAIN_API_KEY, RAPIDAPI_KEY, CLAUDE_CODE_OAUTH_TOKEN, OLLAMA_API_KEY, CFACTORY_AUDIT_HMAC_SECRET | pfactory, tfactory, aifactory, cfactory, backups, keda triggerauth | Manual (agenix). The catch-all secret — highest blast radius. |
| `minio-creds` | S3_ACCESS_KEY, S3_SECRET_KEY | minio, minio bucket-init, pfactory, tfactory, aifactory, backups | Manual (agenix). Rotate = recreate + bounce minio and every consumer. |
| `minio-kms` (new, this PR) | MINIO_KMS_SECRET_KEY | minio, minio bucket-init | Manual (agenix). The object-encryption KEK — see docs/encryption-at-rest.md; rotation is re-encrypt, not drop-in. |
| `factory-cli-creds` | claude-credentials.json (+ codex/copilot/gemini keys) | pfactory, tfactory, aifactory (mounted) | AUTOMATIC — cred-broker CronJob (`apps/cred-broker`) refreshes the Claude OAuth token every 4h. Others manual. |
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

- `factory-secrets` is a **god-secret**: 16 keys, 6 consumers, one blast radius.
  A leak of any one key means recreating the whole Secret and bouncing six
  workloads. Splitting it is a natural follow-up but out of scope here.
- `POSTGRES_PASSWORD` appears in three places that must stay in sync:
  `factory-secrets` (Postgres server + KEDA), the three `factory-db-*`
  DATABASE_URLs, and any manual psql. Rotating it is a multi-step dance
  (below) — a good argument for the ESO/SOPS templating recommended below.
- Only `factory-cli-creds`' Claude token self-heals. Every other credential is a
  manual, undocumented-until-now rotation.

## Rotation runbook

General shape for the manual (agenix) secrets:

1. Generate the new value.
2. `cd ~/.config/nixos && ./scripts/manage-secrets.sh edit <agenix-name>` on the
   machine holding the agenix recipients; paste the new value.
3. `just quick-deploy p510` so the bootstrap re-materialises the Secret, OR
   patch it directly for a hot rotation:
   `kubectl -n factory create secret generic <name> --from-literal=... --dry-run=client -o yaml | kubectl apply -f -`
   (use `--dry-run | apply` to **merge**, never a bare recreate that clobbers
   sibling keys).
4. Bounce the consumers so they pick up the new env/mount:
   `kubectl -n factory rollout restart deploy/<svc> statefulset/<svc>`.
5. Where the credential is external (GitHub PAT, an LLM API key), revoke the old
   one at the provider **after** the new one is confirmed working.

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

- **minio-kms** (the KEK): NOT a plain rotation — re-encryption of existing
  objects is required. See `docs/encryption-at-rest.md` "Rotating the KEK".

- **factory-cli-creds** (Claude OAuth): normally hands-off (cred-broker). Only
  needs a human when the refresh token is consumed/expired. Full procedure in
  [Re-seeding the Claude OAuth credential](#re-seeding-the-claude-oauth-credential).

- **oauth2-proxy-\*** cookie-secret: must be a 16/24/32-byte value; regenerate
  with `openssl rand -base64 32 | head -c 32`, then restart the proxy.

## Re-seeding the Claude OAuth credential

### First: read what the broker already told you

Since Factory#437 the broker records every run on the Secret itself, so this
works with no surviving pod:

```sh
kubectl --context factory -n factory get secret factory-cli-creds \
  -o jsonpath='{.metadata.annotations.cred-broker\.factory\.dev/last-outcome}{"\n"}{.metadata.annotations.cred-broker\.factory\.dev/access-expires-at}{"\n"}'
```

- `access-expires-at` is the **access token** expiry, and it decides urgency.
  A failing broker with months left on that date is a broken rotation, not an
  outage — do not treat it as one.
- `last-outcome` of `refresh-rejected:invalid_grant` is the case this section
  covers.

### Which login flow — this is the part that bites

Two different Claude credentials can land in this Secret and only one of them
works with the broker.

| Flow | Access TTL | Refresh token usable by cred-broker? |
|---|---|---|
| `claude auth login` | ~8h | **Yes** — this is what the broker is built for |
| `claude setup-token` | ~1 year | **No** — the broker fails `invalid_grant` forever |

Factory#437 was a `setup-token` credential: the fleet was fine (364 days of
access left) but every 4h refresh failed and would have kept failing after any
number of re-seeds using the same flow. If you re-seed, use `claude auth login`.

If you deliberately want the long-lived `setup-token` instead, then cred-broker
is the wrong control for this credential — suspend it and monitor the expiry
date rather than leaving a job to fail six times a day.

### Procedure

Rotate **both** Secrets. `factory-secrets/CLAUDE_CODE_OAUTH_TOKEN` and
`factory-cli-creds/claude-credentials.json` must carry the same access token —
the Claude SDK reads the mounted **file**, so fixing only the env var looks like
it worked and does not.

1. On a machine with the CLI, `claude auth login`. This writes
   `~/.claude/.credentials.json`.

2. Patch the file into `factory-cli-creds` without clobbering the sibling
   codex/copilot/gemini keys. Keep the value off the command line:

   ```sh
   kubectl --context factory -n factory patch secret factory-cli-creds \
     --type merge --patch-file /dev/stdin <<EOF
   {"data":{"claude-credentials.json":"$(base64 -w0 ~/.claude/.credentials.json)"}}
   EOF
   ```

3. Patch the matching access token into `factory-secrets`:

   ```sh
   kubectl --context factory -n factory patch secret factory-secrets \
     --type merge --patch-file /dev/stdin <<EOF
   {"data":{"CLAUDE_CODE_OAUTH_TOKEN":"$(python3 -c 'import json,base64,os;print(base64.b64encode(json.load(open(os.path.expanduser("~/.claude/.credentials.json")))["claudeAiOauth"]["accessToken"].encode()).decode())')"}}
   EOF
   ```

4. Confirm the broker before waiting 4h for the schedule:

   ```sh
   kubectl --context factory -n factory create job cred-broker-verify --from=cronjob/cred-broker
   kubectl --context factory -n factory get secret factory-cli-creds \
     -o jsonpath='{.metadata.annotations.cred-broker\.factory\.dev/last-outcome}{"\n"}'
   ```

   Expect `ok`. The annotation is the check that works even though the pod is
   deleted on failure (Factory#438).

5. Bounce the consumers so they re-seed from the mount:

   ```sh
   kubectl --context factory -n factory rollout restart deploy/pfactory deploy/tfactory deploy/aifactory
   ```

### Do not share this credential with a workstation

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

Migrate **`minio-kms`** (the new secret this PR introduces) first:

- It has exactly one key and two consumers — the smallest possible blast radius,
  so a botched migration is trivially recoverable.
- It is brand new, so there is no established rotation habit to disrupt.
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
