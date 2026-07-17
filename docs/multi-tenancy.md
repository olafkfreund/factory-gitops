# Multi-tenancy: current state and plan

## Current state: identity plumbing live, single-tenant data

The **identity half is in place**
([#13](https://github.com/olafkfreund/factory-gitops/issues/13), 2026-07-17):

- Keycloak `factory` realm has a **group per tenant** (currently just
  `default`, also the realm default group so new/GitHub-brokered users
  auto-join) and a group-membership mapper emitting a `tenant` claim on the
  `cfactory` and `factory-vscode` clients — recipe in
  [Keycloak SSO §2b](keycloak-sso.md).
- oauth2-proxy (`apps/cfactory-auth/`, alpha config) maps the claim into its
  session and injects it as an **`X-Tenant-Id` request header**; verified on
  the wire reaching the CFactory backend (`X-Tenant-Id: default` captured on
  port 3111). Keep each user in exactly one tenant group.

The **data half is not**: `CFACTORY_MULTI_TENANT` stays **off** — the stores
are unpartitioned, so flipping it now would only fragment the single-tenant
cockpit view. CFactory currently ignores the header (its resolution seam
defaults to `default` either way). Each product runs as one shared instance
with one shared data store, so **all authenticated users see all data**: every
CFactory work item, every AIFactory task/project, every PFactory spec/plan,
every TFactory verification run. Do not onboard testers or tenants who must
not see each other's work until the product issues below land.

## Remaining path

1. **Data scoping (product side)** — filed from
   [#14](https://github.com/olafkfreund/factory-gitops/issues/14), one issue
   per product; each adds a `tenant_id` to its records, filters its APIs by
   the resolved tenant, and propagates the tenant on cross-service handoffs:

   - CFactory [#172](https://github.com/olafkfreund/CFactory/issues/172) — scope `work_items` and cockpit data
   - AIFactory [#925](https://github.com/olafkfreund/AIFactory/issues/925) — scope tasks, projects, sessions
   - PFactory [#308](https://github.com/olafkfreund/PFactory/issues/308) — scope specs and plans
   - TFactory [#683](https://github.com/olafkfreund/TFactory/issues/683) — scope verification specs and runs

2. **Flip the flag** — once CFactory data is partitioned
   ([CFactory #172](https://github.com/olafkfreund/CFactory/issues/172)),
   set `CFACTORY_MULTI_TENANT=true` on the backend Deployment; the header is
   already arriving.

Until the data half lands, treat the deployment as one trust domain:
everyone who can log in shares one dataset.
