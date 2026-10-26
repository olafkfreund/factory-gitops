---
status: approved
issue: 310
intent: intent/2026-10-26-310-cfactory-read-key.md
---
# Spec: federated search into CFactory authenticates

## Design
In each of the three Deployments, replace the one env entry
`CFACTORY_READ_KEY <- factory-secrets/CFACTORY_READ_KEY` with
`APP_CFACTORY_READ_KEY <- factory-secrets/APP_API_TOKEN`.

- Name: every service reads `APP_CFACTORY_READ_KEY` (AIFactory `apps/web-server/server/config.py:156,253`, PFactory `:40,103`, TFactory `:39,137`, origin/dev). AIFactory's agent env scrub already lists `APP_CFACTORY_READ_KEY` (`apps/backend/core/auth.py:153`), so the key stays out of agent sandboxes.
- Value: the keystore holds one entry, scopes read+write; it equals `factory-secrets/APP_API_TOKEN` and `cfactory-api-keys/api-key` (in-memory comparison, no value printed). `factory-secrets/CFACTORY_READ_KEY` matches no entry. `APP_API_TOKEN` is already mounted in all three pods from `factory-secrets`, so this adds no new secret reference.

## Alternatives rejected
- Rename only: still 401, the value is not in the keystore.
- Add `factory-secrets/CFACTORY_READ_KEY` to the keystore as read-only: least privilege, but a secret change (agenix) the lead does with the user. Left as follow-up; switching back is a one-key edit per manifest.
- Use `cfactory-api-keys/api-key`: same value, but pulls another secret into three pods.

## Risks
The portals hold a read+write cockpit key for a read-only call. They already hold the same value as `APP_API_TOKEN`, so exposure does not grow. A future rotation of `APP_API_TOKEN` without the keystore breaks search again.

## Verification
`kubectl kustomize`/manifest-validate CI green; after deploy, a search through each portal's `/api/search?q=...` returns 200 with results, and CFactory logs no 401 for it.
