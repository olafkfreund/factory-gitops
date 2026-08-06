# Third-party image digest pinning

Every third-party image **declared in this repo** that runs in the `factory`
namespace is pinned to a digest, in the form `image:tag@sha256:...`. Both halves
are load-bearing: the digest is what the kubelet actually resolves, and the tag
is there so a human reading the manifest six months from now can tell what
version is running without a registry round-trip.

One exception, stated so it is a known boundary rather than an oversight:
`pgvector/pgvector:pg17` also runs in `factory`, but `apps/skillai/application.yaml`
points ArgoCD at the `olafkfreund/SkillAi` repo, so its manifest is not here and
cannot be pinned from here. It is unpinned and has already drifted. Tracked in
Factory#588.

Companion to [image signature admission](image-signature-admission.md), which
covers the first-party half and is scoped to `ghcr.io/olafkfreund/*`. These
images cannot be signed and publish no identity we could pin an attestor to, so
digest pinning is the control that actually applies to them. Tracked in
Factory#573, split out of Factory#564.

## What a mutable tag costs, measured rather than argued

A tag is a pointer. The publisher can repush it, and so can anyone who
compromises the publisher; every Pod that restarts or reschedules afterwards
silently gets different bytes and nothing records it.

This is not hypothetical here. On 2026-08-06, before this pinning landed,
`python:3.12-slim` was running **two different images at once** in the `factory`
namespace, split cleanly by node:

| node | digest | image built |
|---|---|---|
| `k3d-agent-0-0` (13 pods) | `sha256:646fb0bc...` | 2026-08-05 |
| `k3d-factory-server-0` (7 pods) | `sha256:57cd7c3a...` | 2026-07-14 |

Same tag, same manifest, different bytes, decided by which node the scheduler
happened to pick. The mechanism is ordinary and applies to every mutable tag:
`imagePullPolicy: IfNotPresent` plus a node-local image cache plus a repointed
tag. The server node had cached the July build; the agent node rejoined the
cluster after a rebuild and pulled whatever the tag pointed at that morning.

Both were Python 3.12.13 -- a Debian base rebuild, not a version change, so
nothing was broken by it. That is the point. The drift was invisible precisely
because it was benign this time.

## Changing a version

A pinned digest makes an upgrade explicit, which is the whole intent: a version
bump is now a two-field edit rather than a silent re-pull.

```bash
# 1. pick the new tag, resolve the INDEX digest (no --platform, or you pin
#    one architecture and break portability)
crane digest postgres:16.5

# 2. edit the manifest to  image: postgres:16.5@sha256:<that digest>
# 3. sanity-check the version behind the digest before committing
crane config --platform linux/amd64 postgres:16.5@sha256:<digest> \
  | jq -r '.config.Env[] | select(test("PG_VERSION"))'
```

`skopeo inspect` and `docker buildx imagetools inspect` work equally well.

## kustomize cannot express `tag@digest`

If a directory has an `images:` transformer in its `kustomization.yaml`, it
**rewrites the ref on every build and strips the digest**, silently returning
the image to a mutable tag. Setting `digest:` instead of `newTag:` keeps the pin
but drops the tag, which costs the legibility the tag is there for.

So for third-party images the rule is: pin in the manifest, and do not add an
`images:` transformer for them. `apps/observe/manifests/kustomization.yaml` had
exactly such a transformer -- a no-op that changed nothing but rewrote the ref,
which quietly unpinned openobserve -- and it was removed for this reason. It is
worth checking the rendered output, not the source, when you touch a pin:

```bash
kubectl kustomize apps/<app>/manifests | grep 'image:'
```

## NOTHING MAINTAINS THESE PINS

Stated plainly, because the failure mode of digest pinning is staleness and the
honest thing is to name it rather than let someone discover it during an
incident.

A pinned digest never updates itself. When one of these upstreams ships a CVE
fix, the tag moves and **this cluster does not**. It will sit on the pinned bytes
indefinitely, and no alert fires.

There is no bot that will fix this:

- **Renovate** is configured in `renovate.json`, but the Renovate GitHub App is
  **not installed on this account**. There are zero Renovate PRs across all five
  Factory repos and no Dependency Dashboard issue. The same file already records
  this discovery for the agent-CLI pins (Factory#90).
- Even if the App were installed, `config:recommended` would not pick these up:
  Renovate's `kubernetes` manager has an empty default file match and needs an
  explicit `managerFilePatterns` entry before it looks at a manifest at all.
- **Dependabot** is not configured in this repo, and its `docker` ecosystem
  parses `FROM` lines in Dockerfiles, not `image:` fields in Kubernetes YAML.

No Renovate config was added here on purpose. Config aimed at a bot that is not
installed produces no PRs while looking, in the file, exactly like coverage --
the same "manufactures the appearance of coverage without any" failure that
Factory#564 exists to avoid, and the reason the previous customManager in
`renovate.json` was deleted rather than fixed. Installing the App is the
prerequisite; the config is the easy part and belongs in the same change.

Tracked in factory-gitops#139. Until it is done, the refresh is manual:

```bash
# what has moved since we pinned
crane digest python:3.12-slim
```
