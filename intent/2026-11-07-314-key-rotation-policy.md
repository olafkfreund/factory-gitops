---
status: approved
issue: 314
author: olafkfreund
---

# Intent: key-rotation policy and decryption-key custody (Factory#314)

## Problem

Epic olafkfreund/Factory#314 has two unchecked items that are not accepted risk:

- "Key-rotation policy + automation for JWT_SECRET, API keys, DB creds, signing keys."
- "Stand up a KMS (or document the SOPS decryption-key custody) with rotation."

`docs/secrets-management.md` has a rotation *runbook* (how) but no *policy*
(when, and what forces a rotation). Apart from the cred-broker's own run
annotations on the Claude OAuth Secret, nothing records when a manually managed
credential was last rotated, and nothing alerts when one is overdue. The
inventory also misses keys that exist in `factory-secrets`:
`{PFACTORY,TFACTORY,AIFACTORY}_JWT_SECRET` (consumed as `APP_JWT_SECRET`),
`KMS_FERNET_KEY` (aifactory) and `CFACTORY_CREDENTIAL_KEY` (cfactory).

The existing runbook (patch, bounce, revoke) covers plain credentials, but not
the classes where the old key has to stay readable:

- Ed25519 contract signing: `apps/tfactory/manifests/manifests.yaml` says
  "Rotate with a new kid; never overwrite this one".
- Data-encryption keys (`KMS_FERNET_KEY`, `CFACTORY_CREDENTIAL_KEY`, the
  `minio-kms` KEK) need re-encryption. MinIO's single-key mode can't hold the
  old and new KEK at once (`docs/encryption-at-rest.md`, "Rotating the KEK").

There is no SOPS in this repo (the doc says so). The real root of trust is
agenix: every `factory-secret-*.age` file in nixos_config is encrypted to the
recipient set `allUsers ++ [ p510 p620 ]` (`secrets.nix`). Today `allUsers` is
one user key, so that's three recipients. They're decrypted with the identities
in each host's `age.identityPaths`: on p510 the user's `~/.ssh/id_ed25519` plus
the host keys, on p620 the host keys only. Nothing in this repo says who holds
those keys, what losing one (or all) of them means, when they rotate, or that
removing a recipient doesn't revoke ciphertext already copied (git history).

## Proposed outcome

- `docs/secrets-management.md` states a rotation policy per class (JWT
  secrets, API keys/tokens, DB creds, HMAC keys, asymmetric signing keys,
  data-encryption keys): the scheduled maximum age, the events that force an
  immediate rotation, and how each class rotates (plain swap, new kid, or
  re-encrypt). The Claude OAuth cred is only referenced; its policy doesn't
  change.
- A machine-readable rotation ledger: one row per credential or atomic rotation
  group (a row covers only keys that are always rotated together), with the
  last-rotated date. History we can't verify is recorded as `unknown`, not as
  today's date.
- Automation: a scheduled workflow goes red when any ledger row is past its
  maximum age, or has an invalid or future date. Rotation itself stays manual.
- The same doc has a "Decryption-key custody" section: the recipient set and
  identity paths, the impact of losing one versus all identities, of leaking
  one, the rotation triggers for the identities themselves, and the fact that
  re-keying doesn't un-leak: after a recipient compromise, the values it could
  read must be rotated too.
- The inventory lists the JWT, Fernet and credential keys.

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

- How long should an `unknown` row get before it counts as overdue? Proposed:
  it's due one maximum age after the policy start (2026-11-07). That way the
  check doesn't go red on day one for history nobody recorded.
- Should rotation itself be automated (for example, a CronJob that regenerates the
  JWT secrets)? Proposed answer: no. Each rotation here needs a consumer bounce
  and, for external keys, a revoke at the provider. A JWT rotation logs every
  user out. For one operator, an overdue review alarm plus the existing runbook
  is enough.
- Is there an offline backup of the user's agenix identity (`~/.ssh/id_ed25519`)?
  The repo can't tell. The doc will state the requirement and leave it to the
  user to confirm.
