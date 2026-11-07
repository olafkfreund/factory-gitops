---
status: approved
issue: 314
spec: spec/2026-11-07-314-key-rotation-policy.md
coders:
  1: codex   # small, tricky logic: strict parser, deadline arithmetic, allowlist, self-test edge cases
  2: agy     # large, mostly mechanical doc edit: copying the approved policy/custody/ledger text into an existing 330-line doc
  3: coder   # one short workflow file in the repo's existing pattern; not worth an external handoff
reviewers:
  - codex    # reviews the doc (step 2, written by agy) and the workflow (step 3) for wrong operational claims; it did not write them
  - agy      # reviews the checker (step 1, written by codex) for edge cases against this plan; it did not write it
# Final review: a fresh Opus agent given only this plan and `git diff origin/main`, independent of all three coders.
---

# Plan: key-rotation policy and decryption-key custody (Factory#314)

Repo: factory-gitops, branch `docs/314-key-rotation-policy` off `origin/main`.
Docs, one stdlib script and one workflow. No manifest, Secret, cluster or
nixos_config change. Never rotate or read a live secret.

## Approved decisions (carried from the spec)

- All classes have a scheduled max age of **365 days** (the operator's
  choice), except `CFACTORY_AUDIT_HMAC_SECRET` and `minio-kms`, which are
  **compromise only** (`none`). The Claude OAuth cred is referenced only; it's
  rotated by cred-broker and isn't in the ledger. Do not touch it.
- Immediate-rotation triggers: suspected or confirmed leak (including a value
  in a log, an annotation or `last-applied-configuration`); compromise or
  decommission of an agenix recipient that could decrypt it; departure of a
  holder; a provider notice.
- Per-class mechanics: copy this approved table into the doc as is:

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

- Ledger: one markdown table between `<!-- rotation-ledger:start -->` and
  `<!-- rotation-ledger:end -->`, header exactly
  `| Credential | Max age (days) | Last rotated | Expires |`. Max age is
  1–3650 or `none`. Last rotated is a strict `YYYY-MM-DD` or `unknown`.
  Expires is `YYYY-MM-DD` or `-`. Every row starts `unknown`/`-`.
- Deadline = (last rotated, or policy start 2026-11-07 for `unknown`) +
  max age, or Expires if earlier. Overdue when `today > deadline`.
- Custody: recipients `allUsers ++ [ p510 p620 ]` (one user key + two host
  keys). p510 identities: user `~/.ssh/id_ed25519` + host ed25519/rsa. p620:
  host keys only. Losing one is recoverable (`agenix -r`). Losing all leaves
  a recovery window through the live Secrets before any rebuild. Compromise
  means remove the recipient, `agenix -r`, **and** rotate every value it could
  read (git history keeps old ciphertext). Identities rotate on triggers,
  host reinstall or decommission, with no schedule. Keep an offline backup of
  at least one identity (the operator confirms; the repo can't). No key
  material or fingerprints anywhere.

## Steps

1. **Create `scripts/rotation-ledger-check.py`** (stdlib only, `#!/usr/bin/env python3`, executable).
   - Usage: `rotation-ledger-check.py [--validate-only] [--today YYYY-MM-DD] FILE`, or `--self-test`.
   - Constants: `POLICY_START = date(2026, 11, 7)` and `NONE_ALLOWED = {"CFACTORY_AUDIT_HMAC_SECRET", "minio-kms"}`.
   - Fail (exit 1, message to stderr naming the line) when: there isn't exactly one start marker and one end marker, in that order; the first table line inside isn't the exact header; the separator row is missing; there are no data rows; a row has the wrong cell count; a date isn't strict `\d{4}-\d{2}-\d{2}` that parses; `Last rotated` is in the future; max age isn't an int in 1–3650 or `none`; `none` is used outside `NONE_ALLOWED`; a credential is duplicated. Credential cells may be wrapped in backticks. Strip them for comparison.
   - When not `--validate-only`, print `OVERDUE <credential> (due <deadline>)` for each overdue row and exit 1. Otherwise print `ok: <n> rows` and exit 0. Exit 2 on usage errors.
   - `--self-test`: assert-based, offline, covering every case in the spec's Verification list (deadline day passes and the day after fails, for both a dated row and `unknown`; earlier Expires; allowlisted `none`; disallowed `none`; future date; bad date; max age 0; duplicate; missing, repeated and reversed markers; wrong header; empty ledger; `--validate-only` ignoring an overdue row). Prints `self-test: ok`.
   → verify by `python3 scripts/rotation-ledger-check.py --self-test`.
   Traps: no PyYAML or third-party imports. The script must not read anything but FILE.

2. **Edit `docs/secrets-management.md`**:
   a. Inventory row `factory-secrets` (line ~44): add `{PFACTORY,TFACTORY,AIFACTORY}_JWT_SECRET` and `CFACTORY_CREDENTIAL_KEY` to the Keys cell (`KMS_FERNET_KEY` is already listed; keep its existing text). Leave the other keys as they are.
   a2. Lines ~14–24 ("How it works today"): change "agenix encrypts it to the host's age key" and "agenix (host key)" to say it's encrypted to the recipient set (one user key plus the p510 and p620 host keys), linking to [Decryption-key custody](#decryption-key-custody).
   b. In "How it works today", change the "Only **one** secret rotates automatically" bullet to add: "Everything else is manual, on the schedule in [Rotation policy](#rotation-policy)."
   c. After "Per-secret specifics" (before "## Re-seeding the Claude OAuth credential"), add `## Rotation policy` (the spec §1 table plus the triggers paragraph, with the decisions above), then `## Rotation ledger`. The ledger section has: a short explanation (what a row is, `unknown` measured from 2026-11-07, deadline rule, "update the row in the same change window as the rotation; removing a row needs a PR that says why", checked weekly by `.github/workflows/secret-rotation-due.yml`), then the marked table with one row per credential, all `unknown` and `-`. Rows: `PFACTORY_JWT_SECRET`, `TFACTORY_JWT_SECRET`, `AIFACTORY_JWT_SECRET`, `GITHUB_TOKEN`, `OPENAI_API_KEY`, `OPENAI_COMPATIBLE_API_KEY`, `GEMINI_API_KEY`, `CONTEXT7_KEY`, `LANGCHAIN_API_KEY`, `RAPIDAPI_KEY`, `OLLAMA_API_KEY`, `ghcr-pull`, `APP_API_TOKEN`, `CFACTORY_READ_KEY`, `cfactory-api-keys`, `PFACTORY_OIDC_CLIENT_SECRET`, `TFACTORY_OIDC_CLIENT_SECRET`, `AIFACTORY_OIDC_CLIENT_SECRET`, `oauth2-proxy-cfactory`, `oauth2-proxy-observe`, `oauth2-proxy-odin`, `observe-root`, `otel-otlp-auth`, `odin-ssh-key`, `POSTGRES_PASSWORD + factory-db-*`, `minio-creds`, `AIFACTORY_TRUSTED_PLAN_KEY_PFACTORY`, `PFACTORY_CONTRACT_SIGNING_KEY__PF-2026-10`, `KMS_FERNET_KEY`, `CFACTORY_CREDENTIAL_KEY` (all 365), plus `CFACTORY_AUDIT_HMAC_SECRET` and `minio-kms` (`none`).
   d. Then add `## Decryption-key custody` with the custody decisions above, and a pointer to `docs/encryption-at-rest.md` for the KEK.
   e. In `docs/encryption-at-rest.md` "Rotating the KEK" (lines ~92–109): replace the code block and its lead-in with a short statement. The KEK is compromise-only (single-key mode can't hold two keys, so the old in-place `mc cp` recipe isn't a working rotation). The emergency path is the untested mirror-out/swap/mirror-back in `secrets-management.md` [Rotation policy](secrets-management.md#rotation-policy). Keep the closing paragraph about graduating to KES.
   → verify by `python3 scripts/rotation-ledger-check.py --today 2026-11-07 docs/secrets-management.md` (exit 0, `ok: 32 rows`), and by `grep -rnE 'age1[0-9a-z]{20,}|ssh-(ed25519|rsa) AAAA|SHA256:[A-Za-z0-9+/]{20,}' docs/; test $? -eq 1` (exit 1 means no match; 2 is an error).
   Traps: keep the house style (plain prose, `kubectl --context factory`). Don't touch the Claude OAuth section. No live values or fingerprints.

3. **Create `.github/workflows/secret-rotation-due.yml`**: `on: schedule: cron "17 6 * * 1"`, `workflow_dispatch`, `pull_request` with `paths: [docs/secrets-management.md, scripts/rotation-ledger-check.py, .github/workflows/secret-rotation-due.yml]`. `permissions: contents: read`. One job on `ubuntu-latest`: `actions/checkout` pinned to the same SHA the repo's other workflows use, then `python3 scripts/rotation-ledger-check.py --self-test`, then `python3 scripts/rotation-ledger-check.py ${{ github.event_name == 'pull_request' && '--validate-only' || '' }} docs/secrets-management.md`. Add a short header comment on why it's scheduled and doesn't auto-file issues (point at `image-pin-freshness.yml`).
   Use exactly `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` (all 13 existing uses).
   → verify by `actionlint .github/workflows/secret-rotation-due.yml` (or `nix run nixpkgs#actionlint -- …` if it isn't installed), and `python3 -c 'import yaml,sys;yaml.safe_load(open(sys.argv[1]))' .github/workflows/secret-rotation-due.yml`.
   Traps: none known locally. `manifest-validate.yml` runs on the PR and is the remote check.

4. **Lead: checks, review, PR.** Run every verify command above, the final Opus review (plan path + `git diff origin/main`), then push and open the PR. Not a coder step.

## Tests

- `python3 scripts/rotation-ledger-check.py --self-test` → `self-test: ok`, exit 0.
- `python3 scripts/rotation-ledger-check.py --today 2026-11-07 docs/secrets-management.md` → `ok: 32 rows`, exit 0.
- `python3 scripts/rotation-ledger-check.py --today 2027-11-07 docs/secrets-management.md` → exit 0 (deadline day).
- `python3 scripts/rotation-ledger-check.py --today 2027-11-08 docs/secrets-management.md` → exit 1, 30 OVERDUE lines (the `none` rows aren't overdue).
- The new workflow and the existing PR checks are green on the PR.

## Rollback

Revert the PR. Nothing is deployed, and no secret or cluster state changes.
