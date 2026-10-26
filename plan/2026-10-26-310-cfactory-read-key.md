---
status: approved
issue: 310
spec: spec/2026-10-26-310-cfactory-read-key.md
---
# Plan: federated search into CFactory authenticates

Decision: env name `APP_CFACTORY_READ_KEY` (what all three settings classes read), value from `factory-secrets/APP_API_TOKEN` (the only keystore entry, read+write; already mounted in all three pods). No secret change.

## Steps
1. `apps/aifactory/manifests/manifests.yaml:378`, `apps/pfactory/manifests/manifests.yaml:302`, `apps/tfactory/manifests/manifests.yaml:676`: replace `{ name: CFACTORY_READ_KEY, ... key: CFACTORY_READ_KEY }` with `{ name: APP_CFACTORY_READ_KEY, ... key: APP_API_TOKEN }` → verify by `git grep -n CFACTORY_READ_KEY apps/` showing only the three new lines, and YAML parses.
   Also fix the comment above each line ("read-scoped" was no longer true).
   Traps: three identical one-line edits, implemented directly (below the coder handoff threshold). Leave `docs/secrets-management.md` alone: the secret key still exists.

## Tests
`python3 -c 'import yaml,sys;[list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]' apps/{aifactory,pfactory,tfactory}/manifests/manifests.yaml`; CI manifest-validate green.
Post-deploy: `kubectl -n factory exec deploy/aifactory -- python -c "import os,urllib.request as u;print(u.urlopen(u.Request('http://cfactory.factory.svc.cluster.local:3111/api/search?q=factory',headers={'Authorization':'Bearer '+os.environ['APP_CFACTORY_READ_KEY']})).status)"` prints 200 (same for pfactory, tfactory).

## Rollback
Revert the commit; search returns to its current 401.
