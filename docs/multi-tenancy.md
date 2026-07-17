# Multi-tenancy: current state and plan

## Current state: single-tenant data

The Factory suite on this cluster is effectively **single-tenant**. Keycloak
authenticates users (separate logins, roles, per-app OIDC clients — see
[Keycloak SSO](keycloak-sso.md)), but each product runs as one shared instance
with one shared data store. **All authenticated users see all data**: every
CFactory work item, every AIFactory task/project, every PFactory spec/plan,
every TFactory verification run.

In other words: auth gates *access to the apps*, but the data behind them is
unpartitioned. Do not onboard testers or tenants who must not see each other's
work until the items below land.

## Planned path

1. **Access scoping (gitops side)** — [#13](https://github.com/olafkfreund/factory-gitops/issues/13):
   a Keycloak **group per tenant**, a mapper emitting a `tenant` claim, and the
   ingress/oauth2-proxy translating that claim into an `X-Tenant-Id` header on
   requests. CFactory already has the resolution seam
   (`CFACTORY_MULTI_TENANT` + `X-Tenant-Id`, defaulting to `default`).

2. **Data scoping (product side)** — filed from
   [#14](https://github.com/olafkfreund/factory-gitops/issues/14), one issue
   per product; each adds a `tenant_id` to its records, filters its APIs by
   the resolved tenant, and propagates the tenant on cross-service handoffs:

   - CFactory [#172](https://github.com/olafkfreund/CFactory/issues/172) — scope `work_items` and cockpit data
   - AIFactory [#925](https://github.com/olafkfreund/AIFactory/issues/925) — scope tasks, projects, sessions
   - PFactory [#308](https://github.com/olafkfreund/PFactory/issues/308) — scope specs and plans
   - TFactory [#683](https://github.com/olafkfreund/TFactory/issues/683) — scope verification specs and runs

Until both halves are in place, treat the deployment as one trust domain:
everyone who can log in shares one dataset.
