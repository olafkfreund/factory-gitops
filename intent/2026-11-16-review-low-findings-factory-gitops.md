---
status: draft
issue: 337
author: olafkfreund
---

# Intent: LOW findings from the wave-8 cross-PR review (#337, #340, #341)

## Problem

1. (#337) The MinIO PostSync hook (`apps/minio/manifests/manifests.yaml`, `set -e`) runs
   `mc admin policy attach` on every Argo CD sync. `attach` fails when the policy is already
   attached, so the hook fails on every re-sync after the first. Rotating `STS_ACCESS_KEY`
   also leaves the previous user enabled with the `aifactory-sts` policy.
2. (#341) The cred-broker's 7-day warning keys on `claudeAiOauth.refreshTokenExpiresAt`.
   The review could not see that the credentials file contains it.
3. (#340) The review said three new CronJobs inject the shared `factory-secrets`
   `GITHUB_TOKEN` and some may not need it.

## Verified against `main` (cb32391)

- #337 confirmed: attach is the last unguarded call in the STS block; no step touches an old user.
- #341 refuted: the Claude CLI (2.1.325 binary) builds its stored credential object with
  `refreshTokenExpiresAt` next to `expiresAt`, and keeps it across refreshes. The broker reads only
  that key, accepts only an epoch-millisecond number, and its refresh keeps the other keys. A
  setup-token has no refresh token, so the warning is simply inert there. Nothing to change.
- #340 refuted: every consumer (`cred-broker`, `secret-rotation`, `endpoint-guard`,
  `restart-watchdog`, `job-watchdog`, `fleet-match`) already uses a single-key `secretKeyRef`;
  no `envFrom` of `factory-secrets` exists in `apps/`. The two CronJobs added in this wave
  (cred-broker, secret-rotation) both use the token to open GitHub issues. Nothing to drop.
  Owner action only: replace the shared token with a fine-grained one.

## Proposed outcome

Re-syncing apps/minio succeeds with the STS user already attached, and a rotated STS key
disables the previous aifactory-sts user. A CI test runs that hook block against a stub `mc`.

## Affected users and systems

apps/minio PostSync hook (Argo CD syncs main). Nothing else.

## Constraints

Hook stays idempotent and safe to sync; do not touch apps/security-alerts; no secrets read.

## Open questions

None. The old user is disabled, not removed: reversible; removal is an owner step. If the
installed `mc` prints no `policyName` in `user list --json`, nothing is disabled (logged
nothing) and the owner disables the old user by hand.
