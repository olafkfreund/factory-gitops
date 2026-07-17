# Keycloak SSO — how it's installed, configured, and reproduced

Keycloak is the **central identity provider** for the Factory suite. One shared instance,
one `factory` realm, one OIDC client per app, and **GitHub** as the upstream login. This page
is both the record of how it was set up and a recipe so anyone can stand it up again.

!!! warning "Secrets in this doc are placeholders"
    Every `<...>` below is a placeholder. Real client secrets and the GitHub OAuth App secret
    live only in the `factory-secrets` Kubernetes Secret and in GitHub — **never** commit them.

## Architecture

```
 GitHub (OAuth App)              Keycloak (realm: factory)                Factory apps
 ┌────────────────┐  IdP broker ┌─────────────────────────┐  OIDC       ┌──────────────────┐
 │ login + email  │ ──────────▶ │ user federation + JWT    │ ──────────▶ │ aifactory/pfactory│
 │ read:user      │            │ clients: aifactory,       │  cookie     │ /tfactory         │
 └────────────────┘            │ pfactory, tfactory        │  session    └──────────────────┘
                               └─────────────────────────┘
 public URL: keycloak.freundcloud.org.uk  (in-cluster Cloudflare tunnel → svc keycloak:8080)
```

- **One realm (`factory`)** holds all users and clients. The `master` realm is admin-only —
  do **not** put app users or app clients there (a classic early mistake; see the blog post).
- **GitHub is brokered**, not direct: Keycloak owns the session and mints the app JWT, so the
  apps only ever speak OIDC to Keycloak, not to GitHub.
- **Multi-tenant plan**: a Keycloak **group per tenant** + a `tenant` claim mapper. Identity
  separation now; per-tenant *data* scoping is a product-side follow-up.

## 1. Install (GitOps)

Keycloak ships like any other app in this repo: `infra/keycloak/keycloak.yaml`
(PVC + Service + Deployment) plus `apps/keycloak/application.yaml` for ArgoCD.

Key choices in the manifest (homelab-appropriate, **not** production-hardened):

```yaml
image: quay.io/keycloak/keycloak:26.1
args: ["start-dev"]                       # H2 on a PVC — fine for a homelab, not for prod
env:
  - KC_BOOTSTRAP_ADMIN_USERNAME: admin
  - KC_BOOTSTRAP_ADMIN_PASSWORD: <from factory-secrets: KEYCLOAK_ADMIN_PASSWORD>
  - KC_HOSTNAME: https://keycloak.freundcloud.org.uk
  - KC_HTTP_ENABLED: "true"               # TLS is terminated upstream by Cloudflare
  - KC_PROXY_HEADERS: xforwarded          # trust X-Forwarded-* from the tunnel
  - KC_HOSTNAME_STRICT: "false"
resources: { requests: { memory: 1Gi }, limits: { memory: 2560Mi } }  # OOMs below ~2Gi
```

!!! note "Why `start-dev` / H2"
    This is a homelab. `start-dev` with the embedded H2 DB on a PVC keeps it simple. For
    production you'd run `start`, an external Postgres, and a realm export/import or
    `keycloak-config-cli` instead of the imperative `kcadm.sh` steps below.

The public hostname is served by the **in-cluster Cloudflare tunnel** (`infra/cloudflared/`),
which maps `keycloak.freundcloud.org.uk` → `keycloak:8080`. No Tailscale sidecar.

## 2. Realm + per-app OIDC clients

All admin work uses `kcadm.sh` **inside the Keycloak pod** (so the admin token stays in
process). The pattern: authenticate once against `master`, then operate on the `factory` realm.

```bash
KCPOD=$(kubectl -n factory get pod -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
kubectl -n factory exec "$KCPOD" -c keycloak -- bash -c '
  set -e
  K=/opt/keycloak/bin/kcadm.sh
  $K config credentials --server http://localhost:8080 --realm master \
     --user admin --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"

  # realm (idempotent)
  $K create realms -s realm=factory -s enabled=true || echo "realm exists"

  # one confidential OIDC client per app
  for SVC in aifactory pfactory tfactory; do
    $K create clients -r factory \
      -s clientId=$SVC -s enabled=true -s protocol=openid-connect \
      -s publicClient=false -s standardFlowEnabled=true \
      -s "redirectUris=[\"https://$SVC.freundcloud.org.uk/api/auth/oidc/callback\"]" \
      -s "webOrigins=[\"https://$SVC.freundcloud.org.uk\"]" || echo "$SVC client exists"
  done
'
```

Then read each client secret and store it in `factory-secrets` (the apps read it from there):

```bash
# for each SVC: fetch the generated client secret …
CID=$($K get clients -r factory -q clientId=$SVC --fields id --format csv --noquotes)
SEC=$($K get clients/$CID/client-secret -r factory --fields value --format csv --noquotes)
# … and patch it into the Secret (never echo it into logs / git)
kubectl -n factory patch secret factory-secrets --type merge \
  -p "{\"stringData\":{\"$(echo $SVC | tr a-z A-Z)_OIDC_CLIENT_SECRET\":\"$SEC\"}}"
```

Result keys in `factory-secrets`: `AIFACTORY_OIDC_CLIENT_SECRET`,
`PFACTORY_OIDC_CLIENT_SECRET`, `TFACTORY_OIDC_CLIENT_SECRET`.

!!! danger "Redirect URI must match exactly"
    The client's `redirectUris` must be the app's real callback —
    `https://<app>.freundcloud.org.uk/api/auth/oidc/callback`. A mismatch (e.g. a leftover
    `tail833f7.ts.net` URL from before the Cloudflare cutover, or pointing at
    `/realms/master/...`) yields the dreaded *"redirect_uri not associated"*. When the public
    hostname changes, update the client redirect URIs too.

## 2b. Tenant groups + `tenant` claim (multi-tenancy, #13)

Tenancy = one Keycloak **group per tenant**. A group-membership protocol mapper on the
`cfactory` and `factory-vscode` clients emits the user's groups as a `tenant` claim in the
token; oauth2-proxy (`apps/cfactory-auth/`) turns that claim into an `X-Tenant-Id` request
header for CFactory. Keep users in **exactly one** tenant group — multiple memberships would
yield a comma-joined header value.

```bash
kubectl -n factory exec "$KCPOD" -c keycloak -- bash -c '
  set -e
  K=/opt/keycloak/bin/kcadm.sh
  $K config credentials --server http://localhost:8080 --realm master \
     --user admin --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"

  # tenant group (repeat per tenant; "default" is the single-tenant fallback)
  $K create groups -r factory -s name=default || echo "group exists"
  GID=$($K get groups -r factory -q search=default --fields id --format csv --noquotes | head -1)

  # realm default group: new users (incl. GitHub-brokered JIT users) auto-join "default"
  $K update realms/factory/default-groups/$GID -n

  # add an existing user to a tenant group
  UID=$($K get users -r factory -q username=<username> --fields id --format csv --noquotes)
  $K update users/$UID/groups/$GID -r factory -s realm=factory -s userId=$UID -s groupId=$GID -n

  # tenant claim mapper on the clients whose tokens reach CFactory:
  # cfactory (browser session) + factory-vscode (editor JWT bearer)
  for C in cfactory factory-vscode; do
    CID=$($K get clients -r factory -q clientId=$C --fields id --format csv --noquotes)
    $K create clients/$CID/protocol-mappers/models -r factory \
      -s name=tenant -s protocol=openid-connect \
      -s protocolMapper=oidc-group-membership-mapper \
      -s "config.\"claim.name\"=tenant" \
      -s "config.\"full.path\"=false" \
      -s "config.\"id.token.claim\"=true" \
      -s "config.\"access.token.claim\"=true" \
      -s "config.\"userinfo.token.claim\"=true" || echo "mapper exists on $C"
  done
'
```

Verify without a login round-trip (server-side example token for a user):

```bash
$K get clients/$CID/evaluate-scopes/generate-example-access-token \
  -r factory -q userId=$UID | grep tenant     # expect  "tenant" : [ "default" ]
```

Applied 2026-07-17: group `default` created + set as realm default group, all existing
users joined, mapper on both clients. See [Multi-tenancy](multi-tenancy.md) for the
oauth2-proxy header wiring and the data-scoping status.

## 3. GitHub as an identity provider (broker)

Create a **GitHub OAuth App** (GitHub → Settings → Developer settings → OAuth Apps):

- **Authorization callback URL** (this is the part everyone gets wrong):
  ```
  https://keycloak.freundcloud.org.uk/realms/factory/broker/github/endpoint
  ```
  It points at **Keycloak's broker endpoint for the `factory` realm** — *not* at any app and
  *not* at `realms/master`.

Then register it as an IdP in the `factory` realm:

```bash
kubectl -n factory exec "$KCPOD" -c keycloak -- bash -c '
  K=/opt/keycloak/bin/kcadm.sh
  $K config credentials --server http://localhost:8080 --realm master \
     --user admin --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"
  $K create identity-provider/instances -r factory \
    -s alias=github -s providerId=github -s enabled=true \
    -s trustEmail=true -s storeToken=false \
    -s "config.clientId=<GITHUB_OAUTH_APP_CLIENT_ID>" \
    -s "config.clientSecret=<GITHUB_OAUTH_APP_CLIENT_SECRET>" \
    -s "config.defaultScope=read:user user:email"
'
```

`trustEmail=true` lets Keycloak just-in-time provision users from their GitHub email without a
separate verification round-trip.

## 4. Wire the apps to OIDC

Each app's Deployment (`apps/<product>/manifests/manifests.yaml`) sets:

```yaml
env:
  - { name: APP_OIDC_ENABLED,       value: "true" }
  - { name: APP_OIDC_ISSUER_URL,    value: "https://keycloak.freundcloud.org.uk/realms/factory" }
  - { name: APP_OIDC_CLIENT_ID,     value: "aifactory" }              # pfactory / tfactory
  - { name: APP_OIDC_CLIENT_SECRET, valueFrom: { secretKeyRef: { name: factory-secrets, key: AIFACTORY_OIDC_CLIENT_SECRET } } }
  - { name: APP_OIDC_REDIRECT_URI,  value: "https://aifactory.freundcloud.org.uk/api/auth/oidc/callback" }
```

The app exposes `/api/auth/oidc/login` (kick off) and `/api/auth/oidc/callback` (exchange code
→ mint an internal JWT → set the `access_token` HttpOnly cookie). Local dev leaves these unset
and runs with `APP_DISABLE_AUTH=true`.

## 5. Verify

```bash
# discovery reachable in-cluster
kubectl -n factory run kcc --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -o /dev/null -w '%{http_code}\n' \
  http://keycloak:8080/realms/factory/.well-known/openid-configuration   # expect 200

# headless end-to-end: login as a realm user, then hit /api/auth/me with the cookie
#   (see /tmp/deploy/me-test.sh) — expect HTTP 200 + user JSON; 401 with no cookie
```

In a browser: open `https://aifactory.freundcloud.org.uk` → **Sign in with SSO** → GitHub →
land **inside** the app. If you bounce back to `/login`, read the troubleshooting table.

## Troubleshooting (hard-won)

| Symptom                                   | Cause                                                                 | Fix |
|-------------------------------------------|----------------------------------------------------------------------|-----|
| `redirect_uri not associated`             | GitHub OAuth callback or client `redirectUris` wrong/stale            | callback = `…/realms/factory/broker/github/endpoint`; client redirect = app `…/api/auth/oidc/callback` |
| `user_not_found` for an admin user        | logging into `master` realm; app users live in `factory`             | log in via the app (→ `factory` realm), not the master console |
| `502 Bad Gateway` on Keycloak             | pod OOMKilled or still booting                                        | bump memory limit (≥2Gi); wait for readiness on `/realms/master` |
| `MismatchingStateError` on callback       | stale/duplicate login attempts, old cookies                          | retry with a clean cookie jar / fresh private window |
| Login succeeds but SPA bounces to `/login`| the **`/api/auth/me` 401 bug** — see the blog post                    | fixed in app images (`get_current_user` + SPA `checkAuth` honor the cookie) |

## Reproduce from scratch (checklist)

1. Seed `factory-secrets` with `KEYCLOAK_ADMIN_PASSWORD` (+ later the client secrets).
2. Deploy `infra/keycloak` + `apps/keycloak` via ArgoCD; wait for readiness.
3. Add the Cloudflare ingress rule + CNAME for `keycloak.freundcloud.org.uk`.
4. Create the `factory` realm + one OIDC client per app (§2); store client secrets.
5. Create the GitHub OAuth App (callback = broker endpoint) + register the IdP (§3).
6. Set `APP_OIDC_*` on each app (§4) and bump their image tags.
7. Verify discovery + a headless login + a browser login (§5).
