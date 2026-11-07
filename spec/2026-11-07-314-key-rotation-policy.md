---
status: draft
issue: 314
intent: intent/2026-11-07-314-key-rotation-policy.md
---

# Spec: key-rotation policy and decryption-key custody (Factory#314)

## Design

Everything lands in factory-gitops. No manifest, Secret or nixos_config change.

### 1. Rotation policy (`docs/secrets-management.md`, new section "Rotation policy")

One table, one row per class. Every class gets the same scheduled maximum age,
**365 days**, unless its row says otherwise. It's the operator's policy choice:
one number to remember, reviewed when a regulated tenant arrives.

| Class | Credentials | Max age | How it rotates |
|---|---|---|---|
| JWT signing secrets | `{P,T,AI}FACTORY_JWT_SECRET` | 365d | Plain swap and bounce. Every session in that service is logged out. |
| External API keys/tokens | `GITHUB_TOKEN`, `OPENAI_API_KEY`, `OPENAI_COMPATIBLE_API_KEY`, `GEMINI_API_KEY`, `CONTEXT7_KEY`, `LANGCHAIN_API_KEY`, `RAPIDAPI_KEY`, `OLLAMA_API_KEY`, `ghcr-pull` | 365d, or the provider's expiry if sooner | Swap, bounce, then revoke the old key at the provider. |
| Shared service tokens | `APP_API_TOKEN`, `CFACTORY_READ_KEY`, `cfactory-api-keys` | 365d | Shared by several callers and verifiers (e.g. `APP_API_TOKEN` across all three factories). Find every consumer with `grep -rn <KEY> apps/`, swap the token in all of them in one window, then bounce. |
| OIDC client secrets | `{P,T,AI}FACTORY_OIDC_CLIENT_SECRET`, `oauth2-proxy-*` client-secret | 365d | Regenerate in Keycloak (the issuer) first, then swap and bounce. |
| Proxy cookie secrets | `oauth2-proxy-*` cookie-secret | 365d | Swap and bounce. Every proxy session is logged out. |
| Outbound auth to another system | `otel-otlp-auth`, `observe-root` | 365d | Change the credential on the receiving service first, then swap and bounce. |
| SSH identity | `odin-ssh-key` | 365d | Generate a new key pair, authorize the new public key at the destination, swap and bounce, then remove the old public key at the destination. |
| DB / object-store creds | `POSTGRES_PASSWORD` + the three `factory-db-*` (one atomic group), `minio-creds` | 365d | Existing per-secret runbook. |
| HMAC keys | `AIFACTORY_TRUSTED_PLAN_KEY_PFACTORY` | 365d | Swap on both pfactory and aifactory in one window. |
| HMAC keys | `CFACTORY_AUDIT_HMAC_SECRET` | **compromise only** | The audit chain is HMAC'd with one unkeyed secret (`CFactory/apps/backend/cfactory/config.py`), so a swap makes every earlier entry unverifiable. Scheduled rotation waits on a key-id'd chain (follow-up, not here). |
| Asymmetric signing | `PFACTORY_CONTRACT_SIGNING_KEY__<KID>` | 365d | **New kid, never overwrite.** Order: (1) add the new seed to `factory-secrets` under the new kid; (2) deploy the new pubkey `TFACTORY_CONTRACT_PUBKEY_PFACTORY__<NEW>` to the verifier, next to the old one; (3) point pfactory's env at the new seed and `PFACTORY_CONTRACT_SIGNING_KID` (a manifest PR); (4) confirm a new contract verifies; (5) delete the old seed. Keep the old pubkey while any contract signed with it may still need verifying. |
| Data-encryption roots | `KMS_FERNET_KEY` (aifactory) | 365d | Envelope: `python -m server.crypto rotate-root` with `KMS_FERNET_KEY_NEW` set re-wraps the data keys, then the env is flipped (AIFactory `server/crypto/__main__.py`). |
| Data-encryption roots | `CFACTORY_CREDENTIAL_KEY` | 365d | Multi-key: prepend `<new-id>:<key>,`, keeping old ids listed until records are re-wrapped (`cfactory/config.py`). |
| Data-encryption roots | `minio-kms` KEK | **compromise only** | Single-key mode can't hold old and new at once (`docs/encryption-at-rest.md`), so there's no scheduled rotation until KES. On compromise, the emergency path (untested, needs downtime): stop writers, `mc mirror` both buckets out to a local plaintext copy while the old KEK is live, swap `minio-kms` and restart MinIO, mirror back so every object is re-encrypted under the new KEK, verify, then shred the copy. Listed as an operational dependency, not a rehearsed procedure. |
| Claude OAuth | `factory-cli-creds`, `CLAUDE_CODE_OAUTH_TOKEN` | n/a | Automated by cred-broker. Referenced only; unchanged. |

Triggers that force an immediate rotation, whatever the age: suspected or
confirmed leak (including a value seen in a log, an annotation or a
`last-applied-configuration`); compromise or decommission of an agenix
recipient that could decrypt it (see custody); departure of anyone who held it;
a provider notice. A compromise-only row still rotates on these triggers. It
just has no schedule.

### 2. Rotation ledger (same doc, section "Rotation ledger")

A markdown table between `<!-- rotation-ledger:start -->` and
`<!-- rotation-ledger:end -->`, with exactly the columns
`Credential | Max age (days) | Last rotated | Expires`. One row per
credential, or per atomic group (the Postgres row). `Max age` is an integer
from 1 to 3650, or `none` (compromise only). `Last rotated` is `YYYY-MM-DD` or
`unknown`. `Expires` is an optional provider-side expiry (`YYYY-MM-DD`, or `-`).
The row is due at the earlier of the two deadlines. Removing a row is a
reviewed PR that has to say why. Every row
starts as `unknown`: no rotation history is recorded anywhere we can read.
Updating a row is a one-line commit, so git is the rotation audit trail the
doc says is missing today.

### 3. Checker (`scripts/rotation-ledger-check.py`, stdlib Python)

- Parses the ledger block. Fails (exit 1) on: not exactly one start marker
  followed by one end marker, a header that doesn't match exactly, an empty
  ledger, a row with the wrong number of cells, a strict-`YYYY-MM-DD`
  violation, a future `Last rotated`, a max age outside 1–3650 or not
  `none`, a duplicate credential, or `none` on a credential outside the
  script's allowlist (`CFACTORY_AUDIT_HMAC_SECRET`, `minio-kms`). That last
  rule stops `none` being used to silence an ordinary key.
- Deadline = `last_rotated + max_age` (an `unknown` row is measured from the
  policy start `2026-11-07`, a constant in the script and stated in the doc),
  or `Expires` if that's earlier. A row is overdue when `today > deadline`. So
  an unknown 365d row is due 2027-11-07 and first fails on 2027-11-08, which
  gives a defined deadline without failing on day one.
- `none` rows are validated but never overdue on age. An `Expires` date
  still applies.
- `--validate-only` checks the structure without the age check.
- Prints one line per overdue row and exits 1. Otherwise prints a count and
  exits 0.
- `--self-test` runs assert-based cases offline (same convention as the
  image-pin-freshness comparator).
- `--today YYYY-MM-DD` override, used by the self-test.

### 4. Workflow (`.github/workflows/secret-rotation-due.yml`)

`schedule` (weekly, Monday), `workflow_dispatch`, and `pull_request` limited
to the doc, the script and the workflow. Steps: checkout,
`python3 scripts/rotation-ledger-check.py --self-test`, then the ledger
check. It runs with `--validate-only` on `pull_request` (time makes a row
overdue, a PR doesn't; same reasoning as `image-pin-freshness.yml`) and in
full on schedule and dispatch. A red
scheduled run emails the owner. No issue is auto-filed, matching the reasoning
in `image-pin-freshness.yml`. `permissions: contents: read`. No secrets.

### 5. Decryption-key custody (same doc, section "Decryption-key custody")

- The root of trust is agenix, not SOPS or a KMS. Recipient set for every
  `factory-secret-*.age`: `allUsers ++ [ p510 p620 ]` in nixos_config
  `secrets.nix`, which today is one user SSH key plus two host keys.
  Identities: p510 `age.identityPaths` = the user's `~/.ssh/id_ed25519` plus
  the host ed25519/rsa keys. p620 = host keys only.
- Loss: losing one identity is recoverable from another recipient. Re-key with
  `agenix -r` from a machine that still decrypts. Losing all of them makes
  every `factory-secret-*.age` unreadable. The live Secrets (including
  `minio-kms` in etcd and in MinIO's env) still hold plaintext copies, so that
  is a recovery window: before any cluster rebuild or delete, mint a new
  identity, read the live values back and re-encrypt them. If that window
  closes, the KEK and every encrypted object are gone. Requirement: keep at least one identity backed up off-host
  and offline. The repo can't verify that this backup exists; the operator
  confirms it.
- Leak or compromise of an identity: remove that recipient from `secrets.nix`,
  `agenix -r`, **and rotate every value that recipient could decrypt**.
  Re-keying doesn't un-leak: old ciphertext stays in nixos_config git history
  and in any copy taken.
- Identity rotation: no schedule. Rotate on the triggers above, on a host
  reinstall (a new host key means re-key) and on a host decommission (remove
  the recipient, re-key, rotate).
- No key material or fingerprints in the doc.

### 6. Inventory fix

Add `{PFACTORY,TFACTORY,AIFACTORY}_JWT_SECRET`, `KMS_FERNET_KEY` and
`CFACTORY_CREDENTIAL_KEY` to the `factory-secrets` row (`CFACTORY_AUDIT_HMAC_SECRET` is
already listed). Also update the "Only one secret rotates automatically" bullet
to point at the new policy.

## Alternatives rejected

- **Automated rotation (CronJob regenerating secrets).** Each rotation needs a
  consumer bounce, provider-side revocation, or re-encryption, and JWT
  rotation logs everyone out. That's a lot of machinery for one operator, and
  it would touch live state this task must not touch.
- **A hard-coded expected credential list in the checker.** It would be a
  second source of truth that drifts from the doc. Row removal is caught in
  PR review instead, and the `none` allowlist covers the silent-exemption
  case.
- **A review-date alarm only.** Codex's intent review confirmed it can stay
  green while credentials are overdue. Rejected for per-row max-age checks.
- **Using nixos_config `.age` git log as "last rotated".** One file covers
  20+ independently rotated keys, and `agenix -r` bumps the date without
  rotating anything. It would report "fresh" when it isn't.
- **Annotations on live Secrets.** It writes cluster state, and the annotation
  dies with a cluster rebuild.
- **A separate YAML ledger file.** It would need PyYAML on the runner, and it
  splits the ledger from the policy it enforces. A markdown table keeps one
  readable source.
- **Standing up KES/Vault now.** It isn't needed for the gap, and the existing
  doc already defers it to when multiple KEKs are needed.

## Risks

- The ledger drifts if the operator rotates and forgets the row. Then the
  check fires early, which is the safe direction.
- All rows fall due 2027-11-07 at once. Acceptable: it's one annual pass, and
  rows reset as they are rotated.
- Markdown table parsing is brittle to reformatting (e.g. a doc linter
  realigning columns). The parser splits on `|` and trims, so alignment
  doesn't matter. A broken row fails loudly, never silently.
- mkdocs renders the HTML comment markers invisibly. No risk to the docs site.
- No host or cluster is touched.

## Verification

- `python3 scripts/rotation-ledger-check.py --self-test` passes. Its cases:
  valid ledger; dated row on its deadline (passes) and the day after (fails);
  unknown row on 2027-11-07 (passes) and 2027-11-08 (fails); an `Expires`
  earlier than the age deadline; an allowlisted `none` row never overdue; a
  `none` row not on the allowlist (fails); a future date; a malformed date;
  max age 0; a duplicate; a missing block, a repeated block and reversed
  markers; a wrong header; an empty ledger; `--validate-only` ignoring an
  overdue row.
- `python3 scripts/rotation-ledger-check.py docs/secrets-management.md`
  exits 0 today.
- `actionlint` (if available) and the repo's existing workflow checks pass on
  the PR. The new workflow runs green on the PR.
- The repo's existing doc checks pass (`mkdocs build --strict` if the repo's
  CI runs it).
- `grep` confirms that no key material and no `age1`/`ssh-` public keys landed
  in the doc.
