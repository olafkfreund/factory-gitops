# Why no Tailscale Operator?

The [Tailscale Kubernetes Operator](https://tailscale.com/docs/features/kubernetes-operator)
is the obviously-right answer in most contexts — one annotation per
Service and the operator handles everything (proxy pods,
hostnames, key rotation). We're not using it. The reason is
specific and not strategic; if it goes away, we'd migrate.

## The constraint

The operator's Helm chart requires `oauth.clientId` + `oauth.clientSecret`
inputs. Both come from a Tailscale **OAuth client** — a separate
admin-console resource from an auth key:

| | OAuth client | Auth key |
|---|---|---|
| Admin URL | `/admin/settings/oauth` | `/admin/settings/keys` |
| Format | `client_id: k…` + `client_secret: tskey-client-…` | Single `tskey-auth-…` token |
| Required scopes for operator | Devices Core, Auth Keys, Services (write) | n/a |
| Required ACL tags | Tag like `tag:k8s-operator` listed in `tagOwners` | None |

The operator **cannot** accept an auth key. It mints fresh ephemeral
auth keys per Service via the API, which requires the OAuth flow.

## Why we don't have OAuth credentials right now

The homelab is wired with a plain reusable auth key generated under
`Settings → Keys`. Generating an OAuth client is a separate workflow
that requires editing the ACL to declare a `tagOwners` entry for the
operator's tag. We tried, didn't end up with OAuth credentials, and
chose to ship rather than block.

## The trade-off we accepted

| Concern | Operator | Sidecars (us) |
|---|---|---|
| Pod-shape boilerplate | One annotation | Sidecar container + 2 env refs + a ConfigMap |
| Hostname creation | Automatic | Hard-coded in `TS_HOSTNAME` |
| Key rotation | Automatic (operator mints per-service) | Manual every ~90d (Tailscale auth-key TTL cap) |
| CRDs | Yes (`ProxyClass`, `Connector`, `DNSConfig`, …) | None |
| Extra control-plane pods | `operator`, sometimes `nameserver` | None |
| Cluster-wide effect | Operator running, watching all namespaces | Pure per-Pod |
| Auth model | OAuth (per-service ephemeral keys) | Shared reusable auth key |

For a homelab with a small handful of services, the per-Pod boilerplate
is fine. For a fleet of dozens of services with frequent churn, the
operator wins.

## Migration path if OAuth becomes available

1. Generate the OAuth client (Tailscale admin → OAuth clients, scopes
   listed above, plus add `tag:k8s-operator` to ACL `tagOwners`).
2. Replace the contents of `secrets/tailscale-k8s-operator-oauth.age`
   in nixos_config with the JSON pair `{"client_id":"…","client_secret":"…"}`.
3. Swap the Nix module's option:
   - `modules.containers.k3d.tailscaleAuthKey.enable = false`
   - `modules.containers.k3d.tailscaleOperator.enable = true` (reintroduce the option group, mostly the previous version)
4. Add an ArgoCD `Application` here under `infrastructure/tailscale-operator/`
   pulling the [official Helm chart](https://pkgs.tailscale.com/helmcharts).
5. Drop sidecars from each Deployment, replace with `loadBalancerClass: tailscale`
   on the Service.

The structure of this repo (apps/ + bootstrap/) doesn't change; only the
exposure mechanism does.
