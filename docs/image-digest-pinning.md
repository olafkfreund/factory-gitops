# Image digest pinning

Every third-party image **declared in this repo**, in **every** namespace, is
pinned to a digest in the form `image:tag@sha256:...`. Both halves are
load-bearing: the digest is what the kubelet actually resolves, the tag is there
so a human reading the manifest six months from now can tell what version is
running without a registry round-trip, **and** the tag is what the freshness
watchdog re-resolves to ask whether the pin has fallen behind.

First-party images (`ghcr.io/olafkfreund/*`) are held to the same standard by a
different means: a build tag this fleet never repoints -- `sha-<short>`, or the
40-char commit sha `olafkfreund/fides` publishes -- or a digest. `:latest` and
`:main` are pointers and are rejected.

The scope was `factory` only until #161/#162. It is now every namespace,
because the union of the old boundaries had a hole in it: `fides-server` ran on
`:latest` in a namespace where neither the digest gate nor either signature
policy looked, and Kyverno's own five images -- the component that enforces
supply-chain policy for everything else -- ran on a mutable tag.

One exception, stated so it is a known boundary rather than an oversight:
`pgvector/pgvector:pg17` also runs in `factory`, but `apps/skillai/application.yaml`
points ArgoCD at the `olafkfreund/SkillAi` repo, so its manifest is not here and
cannot be pinned from here. It is pinned **in that repo** instead
(olafkfreund/SkillAi#304, Factory#588), to the digest that was already running
rather than to registry HEAD -- `pg17` is a floating major-line tag and the
image is a live database, so adopting HEAD is an upgrade that should be its own
change.

Nothing in this repo can verify that pin, and the CI gate below says so out
loud rather than passing over it in silence. If it regresses, it regresses in
`olafkfreund/SkillAi` and this repo will not notice.

Companion to [image signature admission](image-signature-admission.md), which
covers the first-party half and is scoped to `ghcr.io/olafkfreund/*`. These
images cannot be signed and publish no identity we could pin an attestor to, so
digest pinning is the control that actually applies to them. Tracked in
Factory#573, split out of Factory#564.

## What asserts this, and what asserted it before

`manifest validation (blocking)` has a step, **Assert every image this repo
deploys is pinned to something immutable**, that fails the PR if any of them is
not.

Before that step existed, **nothing did**. The pins were made once by hand and
then went unobserved: no workflow read them, and none of the three Kyverno
policies covers them -- `verify-factory-image-signatures` and
`require-first-party-signature-coverage` are both scoped to
`ghcr.io/olafkfreund/*`, and the latter's own closing comment records that
third-party digest pinning "is a separate policy against a separate set of
manifests". So the eleven pinned images were not passing a check; there was no
check, and a revert or a stray `images:` transformer would have unpinned any of
them with nothing to say so.

The step is worth reading for what it deliberately does not do:

- **Scope is derived, never listed**, on two legs: every ArgoCD Application, in
  every namespace, plus every kustomization directory no Application's
  `source.path` names. There is no list of images anywhere in it, so a new app
  is covered the day it lands.
- **The second leg is `bootstrap/`, and today only `bootstrap/`** -- which is
  precisely why it is derived rather than named. bootstrap is not an
  Application, it is what *installs* ArgoCD, so no Application-derived scope
  can reach it however wide the namespace filter gets. Naming the directory
  would close today's hole and leave its shape open.
- **It reads rendered output, not source files.** Twice necessary: because of
  the observe transformer described below, and because the `kyverno`, `keda`
  and `bootstrap` pins exist *only* in rendered output -- they are `images:`
  transformers over remote resources, so their digests appear in no `image:`
  line in git.
- **An Application it cannot read fails.** Multi-source and Helm sources are
  not parsed, and rather than skip them the step errors.
- **An app-of-apps is skipped on what it declares**, not by name:
  `directory.recurse` means it points at a directory of Applications, each of
  which the same loop reads independently.
- **An Application from another repo must be declared** in
  `is_external_declared()` with its tracking issue -- `skillai` and
  `fides-reporter`. An undeclared one fails, which is the guard that would have
  caught Factory#588 at the time instead of eleven images later.

It does not check that a pinned digest is the *right* image (these upstreams
publish no signature we could pin an attestor to -- see Factory#573), and it
does not look at the cluster. It does nothing about staleness either, on
purpose: that is answered out of band, below, because a pull request does not
make a pin stale and failing PRs for something they did not cause is how a gate
gets muted.

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

**Pin the index, compare the platform** -- the two are not in tension, and the
distinction is what keeps the freshness watchdog quiet. Pinning the index keeps
the manifest portable across architectures. Asking "has this pin fallen
behind?" at the index grain would answer yes whenever an architecture we do not
run gets rebuilt, so that question is asked with `--platform linux/amd64`. See
the watchdog section for the measurement that forced this.

## kustomize CAN express `tag@digest`, and this section used to say it could not

The correction matters, because the false version of it shaped three files.

What is true: an `images:` transformer **rewrites the ref on every build**. A
`newTag:` holding a bare tag therefore strips a digest already in the source,
silently returning the image to a mutable tag --
`apps/observe/manifests/kustomization.yaml` had exactly such a no-op
transformer, and it quietly unpinned openobserve. And `digest:` does replace
the tag, rendering `image@sha256:...` with the version gone.

What is **not** true is the conclusion drawn from those two: that both halves
cannot be kept. kustomize concatenates `name` + `:` + `newTag`, so the digest
can go **inside** `newTag`:

```yaml
images:
  - name: reg.kyverno.io/kyverno/kyverno
    newTag: "v1.18.2@sha256:0a540e2ddf74d0d2d3d45f9ef248d7dbc96576accdbcc6a2dd7eaff9fea56504"
```

renders `reg.kyverno.io/kyverno/kyverno:v1.18.2@sha256:0a540e2d...`, both halves
intact. Verified in rendered output, and it is how `apps/kyverno`, `apps/keda`
and `bootstrap` are pinned -- none of which could have been pinned any other
way, because they render from remote release URLs or from a file that
`helm template` regenerates.

**Losing the tag is not a cosmetic cost, and that is the real reason to care.**
The freshness watchdog below answers "has this pin fallen behind?" by
re-resolving the **tag**. A digest with no tag is a pin nothing can ever tell
you is stale -- the exact trap of the section below, dug one level deeper. So
`digest:` is not merely discouraged here, it is rejected: the comparator raises
on a tagless ref rather than skipping it.

The rule that survives unchanged: **check the rendered output, not the source**,
whenever you touch a pin.

```bash
kubectl kustomize apps/<app>/manifests | grep 'image:'
```

## What maintains these pins

This section used to be headed **NOTHING MAINTAINS THESE PINS**, and it was
accurate when written. factory-gitops#139 is that gap, and it is closed by
`.github/workflows/image-pin-freshness.yml` -- weekly, Monday 05:41.

The problem it solves is worth stating precisely, because "pinned" reads like
"handled". A pinned digest never updates itself. When one of these upstreams
ships a CVE fix, the tag moves and this cluster does not. Before pinning the
drift was silent but the patches arrived; after pinning the bytes are honest
but the patches do not arrive at all. **A pin with nothing watching it turns
"we pinned it" into "we froze a known-vulnerable digest and stopped looking."**

No bot was ever going to close this. **Renovate** is configured in
`renovate.json` but the GitHub App is **not installed on this account** -- zero
Renovate PRs across all five Factory repos, no Dependency Dashboard issue --
and even installed, `config:recommended` would not see these, because
Renovate's `kubernetes` manager has an empty default file match. **Dependabot**
is not configured here and its `docker` ecosystem parses `FROM` lines in
Dockerfiles, not `image:` fields in Kubernetes YAML. No Renovate config was
added, then or now: config aimed at a bot that is not installed produces no PRs
while looking, in the file, exactly like coverage. Installing the App remains
the fuller fix and is complementary; this needs no third-party app and can be
verified from inside the repo.

### The two decisions that keep it quiet

An alarm that fires every week on every image gets muted, and then the pins are
unwatched again with a green tick on top. Both of these were measured on the
real pins on 2026-08-08, not guessed.

**It compares the platform digest, not the index digest.** Of 23 pins, 22
resolved to exactly their pinned index and one did not. Diffing the two
`python:3.12-slim` indexes showed what had actually changed:

```
image        linux/amd64    sha256:d657ab0a...   IDENTICAL in both
image        linux/riscv64  sha256:2c7493e4...  ->  sha256:43f469a4...
attestation  unknown        one added, one removed
```

A riscv64 rebuild. Both cluster nodes are `linux/amd64`, so nothing this
cluster runs had changed at all. An index-digest comparison would have alerted
in week one on a non-event, and one non-event is all it takes to train everyone
to ignore the signal.

**The grace budget is on the age of the bytes we run**, not on how recently
upstream rebuilt. "How recently did upstream rebuild" is always a small number
for a fast-moving tag, so a fast-moving tag would stay silent forever however
far behind we fell. Default 30 days, matching `cli-freshness.yml` in the hub.

### The verdicts

| verdict | meaning | alerts |
|---|---|---|
| `CURRENT` | the tag still resolves to our bytes on `linux/amd64` | no |
| `PROPAGATING` | it moved, and our bytes are younger than the budget | no |
| `STALE` | it moved, and our bytes are older than the budget | **yes** |
| `UNDATED` | it moved, and the image declares no usable creation time | **yes** |
| `UNREADABLE` | the registry could not be read | **exit 2** |

`UNDATED` and `UNREADABLE` alert on purpose. "I could not check this" must
never look like "this is fine".

### Refreshing a pin

The watchdog reports; it does not bump. A bad upstream rebuild must not reach
the cluster because a bot merged it unattended.

```bash
crane digest python:3.12-slim      # the new index digest
```

Commit it in the same `image:tag@sha256:...` shape, read the upstream release
notes first, and let the immutability gate in `manifest-validate.yml` check the
result.
