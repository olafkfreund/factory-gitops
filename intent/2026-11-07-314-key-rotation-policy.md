---
status: draft
issue: 314
author: olafkfreund
---

# Intent: key-rotation policy and decryption-key custody (Factory#314)

## Problem

Epic olafkfreund/Factory#314 has two unchecked items that are not accepted risk:

- "Key-rotation policy + automation for JWT_SECRET, API keys, DB creds, signing keys."
- "Stand up a KMS (or document the SOPS decryption-key custody) with rotation."

`docs/secrets-management.md` has a rotation *runbook* (how) but no *policy*
(when, and what forces a rotation). Nothing records when a secret was last
rotated, and nothing reminds anyone to rotate. The inventory also misses keys
that exist: `factory-secrets` holds `{PFACTORY,TFACTORY,AIFACTORY}_JWT_SECRET`
(consumed as `APP_JWT_SECRET` in `apps/{p,t,ai}factory/manifests/manifests.yaml`).
The table doesn't list them.

There is no SOPS in this repo (the doc says so). The real root of trust is
agenix: every `factory-secret-*.age` file in nixos_config is encrypted to the
user's SSH key plus the p510 and p620 host keys (`secrets.nix`,
`age.identityPaths` per host). Nothing in this repo says who holds those keys,
what losing one means, or how a recipient is added or revoked.

## Proposed outcome

- `docs/secrets-management.md` states a rotation policy per class (JWT secrets,
  API keys/tokens, DB creds, signing/HMAC keys, the MinIO KEK, the Claude OAuth
  cred): the scheduled maximum age, the events that force an immediate rotation,
  and a ledger of when each class was last rotated.
- The same doc has a "Decryption-key custody" section: the three agenix
  identities, where each lives, the impact of losing or leaking one, and how to
  add or revoke a recipient (re-key).
- The inventory lists the JWT secrets.
- Automation: a scheduled check goes red when the quarterly rotation review is
  overdue, so the policy isn't left to memory.

## Affected users and systems

The operator (the user). `docs/secrets-management.md`, one new GitHub workflow in
factory-gitops. No cluster, Secret or nixos_config change.

## Constraints

- Must not rotate, read or touch any live Secret or cluster state.
- Must not touch the cred-broker / Claude OAuth credential (incident Factory#3676
  is the user's). The policy only references its existing automation.
- Postgres at rest (R-014) and FIPS stay out of scope.
- Must not print key material. Public-key fingerprints aren't needed either.

## Open questions

- Should rotation itself be automated (for example, a CronJob that regenerates the
  JWT secrets)? Proposed answer: no. Each rotation here needs a consumer bounce
  and, for external keys, a revoke at the provider. A JWT rotation logs every
  user out. For one operator, an overdue review alarm plus the existing runbook
  is enough.
- Is there an offline backup of the user's agenix identity (`~/.ssh/id_ed25519`)?
  The repo can't tell. The doc will state the requirement and leave it to the
  user to confirm.
