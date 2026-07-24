# Egress allowlist design (per-task sandbox Jobs)

Status: DESIGN ONLY. Nothing in this document is applied to the cluster by the
PR that introduces it. It exists to replace the current "443 to any public IP"
egress rule with a per-destination allowlist, without breaking legitimate
traffic. Rolling out a tight allowlist blindly WILL break running task Jobs.

Related: Factory#322, compliance program #310 (gap #4). PodSecurity Admission
(the other half of gap #4) ships in this same PR as warn/audit labels on the
`factory` namespace — see `apps/factory-namespace/manifests/namespace.yaml`.

## Where we are today

The per-task sandbox Jobs (AIFactory/TFactory `kube_sandbox` — the Nix
build/verify lanes) already run with, default-on:

- a per-Job NetworkPolicy (AIFactory#812 / TFactory#651), and
- a non-root securityContext.

They run in the **`factory` namespace** — the same namespace as the control
plane (aifactory, tfactory, pfactory, cfactory, postgres, redis, minio,
keycloak, observe). There is no dedicated task namespace. See the `namespace:
factory` destinations in `apps/aifactory/application.yaml`,
`apps/tfactory/application.yaml`, `apps/pfactory/application.yaml`, and the
sandbox RBAC in `apps/tfactory/manifests/manifests.yaml`
(`tfactory-sandbox` Role/RoleBinding/ServiceAccount, scoped to `factory`).

The gap: the per-Job NetworkPolicy egress rule allows **TCP/443 to any public
IP**. That means AI-generated code (or a compromised dependency) running inside
a task Job can reach *any* HTTPS endpoint on the internet — data exfiltration,
C2, SSRF pivots — as long as it uses port 443. There is no per-destination
restriction and no egress proxy.

## Why we cannot just tighten it

A task Job legitimately needs to reach a wide, partly dynamic set of hosts:

- **LLM / inference APIs** — `api.anthropic.com`, `api.openai.com`,
  `generativelanguage.googleapis.com` (Gemini), `ollama.com`, and the
  host-local Ollama at `host.k3d.internal:11434` (see
  `OPENAI_COMPATIBLE_BASE_URL` in the pfactory/aifactory/tfactory manifests).
- **AI-generated code fetching its own dependencies** — this is the hard part.
  The whole point of the factory is to build arbitrary projects, so the set of
  package hosts a Job needs is open-ended and driven by the SUT, not by us.
- **Nix substituters + flake inputs** — `cache.nixos.org`,
  `nix-community.cachix.org`, `channels.nixos.org`, plus GitHub for flake
  inputs.

An allowlist that is too tight silently breaks builds with confusing
"connection timed out" errors deep inside a package manager. So the rollout is
phased: **observe first, allowlist second, enforce last.**

## Legitimate egress destinations (enumeration)

Grounded in the current manifests and the fleet's known model/registry usage.
Ports are 443 unless noted.

### In-cluster (never leaves the cluster — allow to the pod/service CIDR)

All `*.factory.svc.cluster.local`, plus kube-dns:

| Purpose            | Destination                                   |
|--------------------|-----------------------------------------------|
| DNS                | `kube-dns` in `kube-system`, UDP/TCP 53       |
| Postgres           | `factory-postgres.factory.svc` 5432           |
| Redis              | `redis.factory.svc` 6379                      |
| Object store       | `minio.factory.svc` 9000                      |
| Control-plane APIs | `aifactory` / `tfactory` / `pfactory` / `cfactory`.factory.svc |
| SSO                | `keycloak.factory.svc`                        |
| Kube API           | `kubernetes.default.svc` 443 (sandbox dispatch/log RBAC) |

These should be expressed as `to` selectors on namespace/pod labels, not IP
literals.

### LLM / inference APIs

| Provider           | Host(s)                                       |
|--------------------|-----------------------------------------------|
| Anthropic          | `api.anthropic.com`                           |
| OpenAI             | `api.openai.com`                              |
| Google Gemini      | `generativelanguage.googleapis.com`           |
| Ollama Cloud       | `ollama.com`                                  |
| Ollama (host-local)| `host.k3d.internal:11434` (p510 host)         |

### Source control + container/image registries

| Purpose            | Host(s)                                       |
|--------------------|-----------------------------------------------|
| Git over HTTPS     | `github.com`, `codeload.github.com`           |
| GitHub API         | `api.github.com`                              |
| Release assets/LFS | `objects.githubusercontent.com`, `*.githubusercontent.com` |
| Container images   | `ghcr.io`, `*.pkg.github.com`                 |

### Language / package mirrors (driven by the SUT — the open-ended set)

| Ecosystem | Host(s)                                                     |
|-----------|-------------------------------------------------------------|
| Nix       | `cache.nixos.org`, `nix-community.cachix.org`, `channels.nixos.org` |
| Python    | `pypi.org`, `files.pythonhosted.org`                        |
| Node      | `registry.npmjs.org`                                        |
| Rust      | `crates.io`, `static.crates.io`, `index.crates.io`          |
| Go        | `proxy.golang.org`, `sum.golang.org`                        |
| Java      | `repo1.maven.org`, `repo.maven.apache.org`                  |
| OS pkgs   | Wolfi/Alpine `apk` mirrors, Debian `apt` mirrors (base images) |

This table is a starting seed, not a closed set. Confirm it against a real
observation window (phase 1) before enforcing.

## Two mechanisms — and why a proxy wins for this workload

### Option A — per-destination NetworkPolicy

NetworkPolicy `to` blocks take `ipBlock` CIDRs or pod/namespace selectors —
**not DNS names**. Every host above resolves to CDN IP ranges (Fastly,
Cloudflare, GitHub, Google) that rotate and are shared across many unrelated
sites. To allowlist `pypi.org` by IP you would pin Fastly's entire ranges,
which also cover a large slice of the internet — so the "allowlist" barely
narrows anything. NetworkPolicy is the right tool for the **in-cluster**
destinations (selector-based, stable) and to keep the default-deny posture, but
it cannot express a hostname allowlist for the external set.

### Option B — filtering forward (egress) proxy  ← recommended for external traffic

Run a filtering HTTP/HTTPS forward proxy (e.g. a small squid, or a
purpose-built egress gateway) in the `factory` namespace with a **hostname**
allowlist. Then:

- NetworkPolicy for task Jobs: default-deny egress, allow DNS + in-cluster
  services + **only the proxy's ClusterIP:port**. Direct 443-to-any is removed.
- Task Jobs get `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` env pointing at the proxy
  (Nix, pip, npm, cargo, go, git, and the LLM SDKs all honour these).
- The proxy enforces the hostname allowlist (SNI/CONNECT host), logs every
  allowed and denied destination, and is the single chokepoint we curate.

This matches how the sandbox is already dispatched (central `kube_sandbox`
dispatcher) and gives a real audit trail. The allowlist lives in the proxy
config, versioned in git, reviewed like any other policy change.

`NO_PROXY` must include the in-cluster `.svc.cluster.local` suffix, the pod/
service CIDRs, and `host.k3d.internal` so in-cluster and host-local Ollama
traffic bypasses the proxy.

## Phased rollout (observe -> allowlist -> enforce)

1. **Observe (no enforcement).** Deploy the egress proxy in *log-only /
   allow-all* mode. Point task Jobs at it via `HTTPS_PROXY`. Keep the existing
   443-to-any NetworkPolicy in place. Run real PARR jobs (polyglot ladder,
   AWS demo, etc.) for 1-2 weeks and collect the actual destination set from
   the proxy logs. Output: the empirically-complete allowlist, which will be a
   superset of the seed tables above.

2. **Allowlist (proxy enforces, network still open).** Switch the proxy to
   deny-by-default with the curated allowlist. Leave the NetworkPolicy still
   allowing 443-to-any as a safety valve, so a missing entry surfaces as a
   clean proxy `403 Forbidden` (easy to diagnose and add) rather than a
   network black-hole. Iterate until denials are only genuinely-unwanted hosts.

3. **Enforce (network closes the direct path).** Flip the per-Job NetworkPolicy
   to default-deny egress + allow only DNS, in-cluster services, and the proxy
   ClusterIP. Now the proxy is the *only* way out and its allowlist is the real
   control. Direct 443-to-any is gone.

Each phase is its own reviewed PR. Do not skip phase 1: the SUT-driven package
host set is not knowable in advance and is the whole reason a blind allowlist
breaks builds.

## Follow-ups (not in this PR)

- **`readOnlyRootFilesystem` on task Jobs.** Constraint (already known): Nix
  writes `/nix/var` and `$HOME`. Achievable by mounting those as writable
  `emptyDir`/PVC volumes while the rest of the rootfs is read-only — needed
  anyway before PSA `enforce=restricted`.
- **Root verify lanes.** Some verify lanes still run as root; PSA `restricted`
  requires `runAsNonRoot`. Reconcile these before raising the PSA level past
  `baseline`. Tracked alongside the PSA path in
  `apps/factory-namespace/manifests/namespace.yaml`.
- **seccompProfile=RuntimeDefault** on task Jobs — also required by
  `restricted`; verify the Nix lanes tolerate it during the phase-3 observe
  window.
