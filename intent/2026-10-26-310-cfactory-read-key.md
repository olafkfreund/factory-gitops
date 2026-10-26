---
status: approved
issue: 310
author: olafkfreund
---
# Intent: federated search into CFactory authenticates

**Problem:** AIFactory, PFactory and TFactory send no bearer to CFactory's `/api/search`, so federated search gets 401. The Deployments set `CFACTORY_READ_KEY`, but all three settings classes read `APP_CFACTORY_READ_KEY` (`env_prefix="APP_"`). The secret behind it, `factory-secrets/CFACTORY_READ_KEY`, is also not in the CFactory keystore (`cfactory-api-keys/api-keys`).
**Outcome:** The palette search in each of the three portals returns CFactory results instead of a 401.
**Affected:** factory-gitops `apps/{aifactory,pfactory,tfactory}/manifests/manifests.yaml`; the three pods restart once on deploy.
**Constraints:** No new secret value unless no existing keystore credential fits; secret changes go through the lead and the user. Never print secret values.
**Open questions:** None. Lead's decision: reuse a key that is already in the keystore.
