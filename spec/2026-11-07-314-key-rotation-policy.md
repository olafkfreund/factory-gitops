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
**365 days**, unless its row says otherwise. One number to remember, and it
matches the common annual ISO/SOC 2 control expectation.

| Class | Credentials | Max age | How it rotates |
|---|---|---|---|
| JWT signing secrets | `{P,T,AI}FACTORY_JWT_SECRET` | 365d | Plain swap and bounce. Every session in that service is logged out. |
| External API keys/tokens | `GITHUB_TOKEN`, `OPENAI_API_KEY`, `OPENAI_COMPATIBLE_API_KEY`, `GEMINI_API_KEY`, `CONTEXT7_KEY`, `LANGCHAIN_API_KEY`, `RAPIDAPI_KEY`, `OLLAMA_API_KEY`, `ghcr-pull` | 365d, or the provider's expiry if sooner | Swap, bounce, then revoke the old key at the provider. |
| Internal API keys / OIDC / proxy | `APP_API_TOKEN`, `CFACTORY_READ_KEY`, `cfactory-api-keys`, `{P,T,AI}FACTORY_OIDC_CLIENT_SECRET`, `oauth2-proxy-*`, `observe-root`, `otel-otlp-auth`, `odin-ssh-key` | 365d | Swap and bounce. For OIDC client secrets, regenerate in Keycloak first. |
| DB / object-store creds | `POSTGRES_PASSWORD` + the three `factory-db-*` (one atomic group), `minio-creds` | 365d | Existing per-secret runbook. |
| HMAC keys | `AIFACTORY_TRUSTED_PLAN_KEY_PFACTORY` | 365d | Swap on both pfactory and aifactory in one window. |
| HMAC keys | `CFACTORY_AUDIT_HMAC_SECRET` | **compromise only** | The audit chain is HMAC'd with one unkeyed secret (`CFactory/apps/backend/cfactory/config.py`), so a swap makes every earlier entry unverifiable. Scheduled rotation waits on a key-id'd chain (follow-up, not here). |
| Asymmetric signing | `PFACTORY_CONTRACT_SIGNING_KEY__<KID>` | 365d | **New kid, never overwrite.** Add the new seed and its public key under a new kid, switch `PFACTORY_CONTRACT_SIGNING_KID`, then remove the old pubkey once no contract signed with it is in flight. |
| Data-encryption roots | `KMS_FERNET_KEY` (aifactory) | 365d | Envelope: `python -m server.crypto rotate-root` with `KMS_FERNET_KEY_NEW` set re-wraps the data keys, then the env is flipped (AIFactory `server/crypto/__main__.py`). |
| Data-encryption roots | `CFACTORY_CREDENTIAL_KEY` | 365d | Multi-key: prepend `<new-id>:<key>,`, keeping old ids listed until records are re-wrapped (`cfactory/config.py`). |
| Data-encryption roots | `minio-kms` KEK | **compromise only** | Single-key mode can't hold old and new at once (`docs/encryption-at-rest.md`). Scheduled rotation needs KES first (future work there). |
| Claude OAuth | `factory-cli-creds`, `CLAUDE_CODE_OAUTH_TOKEN` | n/a | Automated by cred-broker. Referenced only; unchanged. |

Triggers that force an immediate rotation, whatever the age: suspected or
confirmed leak (including a value seen in a log, an annotation or a
`last-applied-configuration`); compromise or decommission of an agenix
recipient that could decrypt it (see custody); departure of anyone who held it;
a provider notice. A compromise-only row still rotates on these triggers. It
just has no schedule.

### 2. Rotation ledger (same doc, section "Rotation ledger")

A markdown table between `<!-- rotation-ledger:start -->` and
`<!-- rotation-ledger:end -->`, with columns
`Credential | Max age (days) | Last rotated`. One row per credential, or per
atomic group (the Postgres row). `Max age` is an integer or `none`
(compromise only). `Last rotated` is `YYYY-MM-DD` or `unknown`. Every row
starts as `unknown`: no rotation history is recorded anywhere we can read.
Updating a row is a one-line commit, so git is the rotation audit trail the
doc says is missing today.

### 3. Checker (`scripts/rotation-ledger-check.py`, stdlib Python)

- Parses the ledger block. Fails (exit 1) on: a missing block, an empty
  ledger, a malformed row, an invalid or future date, a non-integer max age
  other than `none`, or a duplicate credential.
- A row is overdue when `today > last_rotated + max_age`. An `unknown` row is
  measured from the policy start `2026-11-07` (a constant in the script and
  stated in the doc), so it falls due 2027-11-07. That gives a defined
  deadline, and the alarm doesn't fire on day one.
- `none` rows are validated but never overdue.
- Prints one line per overdue row and exits 1. Otherwise prints a count and
  exits 0.
- `--self-test` runs assert-based cases offline (same convention as the
  image-pin-freshness comparator).
- `--today YYYY-MM-DD` override, used by the self-test.

### 4. Workflow (`.github/workflows/secret-rotation-due.yml`)

`schedule` (weekly, Monday), `workflow_dispatch`, and `pull_request` limited
to the doc, the script and the workflow. Steps: checkout, then
`python3 scripts/rotation-ledger-check.py --self-test`, then
`python3 scripts/rotation-ledger-check.py docs/secrets-management.md`. A red
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
  every `factory-secret-*.age` unreadable. The live cluster keeps running, but
  a rebuild can't re-seed, and the `minio-kms` KEK (and so every encrypted
  object) is gone. Requirement: keep at least one identity backed up off-host
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
  valid ledger, overdue dated row, overdue unknown row (today past
  2027-11-07), `none` row never overdue, future date, malformed date,
  duplicate, missing block.
- `python3 scripts/rotation-ledger-check.py docs/secrets-management.md`
  exits 0 today.
- `actionlint` (if available) and the repo's existing workflow checks pass on
  the PR. The new workflow runs green on the PR.
- The repo's existing doc checks pass (`mkdocs build --strict` if the repo's
  CI runs it).
- `grep` confirms that no key material and no `age1`/`ssh-` public keys landed
  in the doc.
