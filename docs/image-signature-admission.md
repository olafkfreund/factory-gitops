# Image signature verification at admission (audit mode)

Status: AUDIT/WARN ONLY. The policy this PR introduces REPORTS unsigned or
wrongly-signed images; it does NOT deny them. Nothing here is applied to the
cluster by this PR — it is committed to GitOps for review, and ArgoCD will
reconcile it after merge.

Related: Factory#318, compliance program #310 (gap #8). Depends on CFactory#191
(CFactory image signing) before any move to Enforce.

## Where we started

Historical. Read the two corrections that follow before believing any of it —
in particular, CFactory does sign its images now, and the signed tags are no
longer only the semver ones.

The release workflows for PFactory, AIFactory and TFactory sign every pushed
image with **cosign keyless** (Sigstore + GitHub Actions OIDC — no long-lived
keys). See, for example,
[`AIFactory/.github/workflows/release.yml`](https://github.com/olafkfreund/AIFactory/blob/main/.github/workflows/release.yml)
— the `Sign both images (cosign keyless via Sigstore + GitHub OIDC)` and
`Verify signature (release self-test)` steps.

But the **cluster never verified those signatures**. ArgoCD and the kubelet
admit factory workloads purely by image tag (`ghcr.io/olafkfreund/aifactory:v3.4.2`,
etc.). A tag can be repointed at an unsigned or malicious image and the cluster
would admit it. That is compliance gap #8.

CFactory (`ghcr.io/olafkfreund/cfactory`, `cfactory-frontend`) does **not** sign
its images yet — it has no `release.yml` cosign step. Signing is tracked in
CFactory#191. This is the reason the policy must stay in audit mode: an Enforce
policy would block every CFactory Pod.

### Correction — Factory#430 (the audit was failing 100%)

Everything above was true and still left the control verifying nothing. Once
the policy went live it reported `fail: unverified image` for **every** factory
image. Three separate defects, all of which had to be fixed:

1. **The signed images are not the images that run.** `release.yml` signs only
   on a semver bump and publishes `:vX.Y.Z`. Nothing in the cluster runs a
   `:vX.Y.Z` tag — ArgoCD is pinned by `deploy.yml`/`build-nix.yml` to
   `:sha-<short>` and `:sha-<short>-nix`, and *those* workflows had no cosign
   step at all. The audit was correctly measuring a genuine absence:

   ```
   $ cosign verify --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
       --certificate-identity-regexp='olafkfreund/AIFactory' \
       ghcr.io/olafkfreund/aifactory:sha-0ffa542
   Error: no signatures found          # the tag the cluster runs

   $ cosign verify ... ghcr.io/olafkfreund/aifactory:v3.6.73
   Verification for ghcr.io/olafkfreund/aifactory:v3.6.73 --  # the tag nobody runs
   ```

   Fixed by adding cosign keyless sign + a verify self-test to the CD
   workflows (AIFactory `deploy.yml` + `build-nix.yml`, PFactory `deploy.yml`,
   TFactory `deploy.yml`, CFactory `deploy.yml`). The policy was **not**
   loosened.

2. **The live policy had silently lost its `subjectRegExp`.** The manifest in
   git pins each repo's signer identity; the object in the cluster carried only
   `issuer: https://token.actions.githubusercontent.com`. Any GitHub Actions
   workflow in any repo on earth would have satisfied it. A control that
   fails 100% of the time hid a second control that would have passed too
   easily.

3. **ArgoCD had been unable to sync this Application since the Kyverno
   v1.12.6 -> v1.18.2 bump**, which is why (2) was never corrected:

   ```
   admission webhook "validate-policy.kyverno.svc" denied the request:
   spec.rules[0].verifyImages[0].attestors[0].entries[0].keyless:
   Invalid value: {...}: Either Rekor URL or roots are required
   ```

   The app sat `OutOfSync` + `SyncError` while reporting `Healthy`, so the
   drift was invisible. Fixed by adding an explicit
   `rekor.url: https://rekor.sigstore.dev` to each keyless attestor.

That missing `rekor` was also producing a **false `pass`**. The live
PolicyReport for the `aifactory` Deployment read `pass: image verified` while
the image it runs has no signature at all:

```
$ cosign verify ... ghcr.io/olafkfreund/aifactory:sha-0bfadd9
Error: no signatures found
```

Replaying the policy through the Kyverno CLI (v1.18.2, same version as the
cluster) isolates the cause to exactly that one field:

```
# live shape: no rekor, no roots
$ kyverno apply live-shape-policy.yaml --resource pod-running.yaml
Policies Skipped (as required variables are not provided by the user):
1. verify-factory-image-signatures
pass: 0, fail: 0, warn: 0, error: 1, skip: 0

# same policy, rekor added, nothing else changed
$ kyverno apply rekor-only-policy.yaml --resource pod-running.yaml
verify-aifactory-signature failed to verify image
  ghcr.io/olafkfreund/aifactory:sha-0bfadd9: no signatures found
pass: 0, fail: 2, warn: 0, error: 0, skip: 0
```

So the policy was not merely failing everything — it was unevaluable, and one
of the three services was being reported green on that basis. Treat a `pass`
from before this change as meaningless.

### Second correction — Factory#430 (the audit was still failing 100%)

Signing was fixed, the identities were pinned, ArgoCD could sync again — and
the audit still reported `fail: unverified image` for every factory Pod. The
third cause was not in this repo at all.

`cosign verify` on the workstation passed for all four running images, with
subjects matching this policy exactly. Kyverno disagreed. Replaying an
admission with a server-side dry run gave the reason the PolicyReport omits:

```
$ kubectl apply -f probe-pod.yaml --dry-run=server
Warning: policy verify-factory-image-signatures.verify-aifactory-signature:
  failed to verify image ghcr.io/olafkfreund/aifactory:sha-6b116ee:
  .attestors[0].entries[0].keyless: failed to get roots from fulcio:
  initializing tuf: updating local metadata and targets: error updating to TUF
  remote mirror: tuf: failed to download 13.root.json:
  Get "https://tuf-repo-cdn.sigstore.dev/13.root.json":
  dial tcp: lookup tuf-repo-cdn.sigstore.dev on 10.43.0.10:53: server misbehaving
```

Kyverno was not rejecting a signature. It could not resolve DNS — and neither
could anything else in the cluster. ArgoCD had every Application on
`SYNC: Unknown` because `argocd-repo-server` could not resolve `github.com`,
and CoreDNS was returning SERVFAIL for every external name:

```
[ERROR] plugin/errors: 2 github.com. A: read udp 10.42.0.221:45830->172.18.0.1:53: i/o timeout
[ERROR] plugin/errors: 2 tuf-repo-cdn.sigstore.dev. A: read udp 10.42.0.221:46528->172.18.0.1:53: i/o timeout
```

Root cause: **Docker Engine 29 changed the address of its embedded resolver.**
The k3d node containers' `/etc/resolv.conf` now reads:

```
# Generated by Docker Engine.
nameserver 172.18.0.1
# Based on host file: '/run/systemd/resolve/resolv.conf' (internal resolver)
```

`172.18.0.1` is the k3d bridge gateway, and it only works inside the node
container's own network namespace, via netns-local NAT that Docker installs
there:

```
$ docker exec k3d-factory-server-0 iptables-save -t nat | grep 172.18.0.1
-A DOCKER_OUTPUT -d 172.18.0.1/32 -p udp -m udp --dport 53 -j DNAT --to-destination 127.0.0.11:38949
```

Docker's older embedded-resolver address was `127.0.0.11`, and k3s has a guard
that substitutes a public resolver when the node's resolv.conf is a loopback
address. `172.18.0.1` is not loopback, so the guard does not fire and k3s
passes the address straight through to CoreDNS. CoreDNS runs in a *pod* network
namespace, which has none of those NAT rules, so its queries reach the real
bridge gateway on the host — where nothing listens. Every pod in the cluster
lost external DNS; the signature policy was simply the loudest reporter of it.

Two consequences worth carrying forward:

- **`fail: unverified image` is ambiguous.** Kyverno emits the identical
  PolicyReport result for "this image has no valid signature" and for "Kyverno
  could not reach Sigstore or GHCR". The distinguishing detail only exists in
  the admission-controller log. Always check it before acting on a fail:

  ```bash
  kubectl -n kyverno logs deploy/kyverno-admission-controller \
    | grep 'failed to verify image'
  ```

- **The failure is sticky per process.** After DNS was restored, the running
  admission-controller Pod kept returning the same TUF error; it only started
  verifying after `kubectl -n kyverno rollout restart
  deploy/kyverno-admission-controller`. A connectivity repair alone is not
  enough to clear the audit.

The DNS fix itself is not in this repo. The k3d cluster is created by
`k3d-cluster-bootstrap.service` on p510 (declared in `nixos_config`), and the
durable fix belongs there — see olafkfreund/nixos_config#1232. Until that
lands, the node containers carry a hand-edited `/etc/resolv.conf`, which is
lost if the cluster is ever recreated.

### Blockers after this change

1. **~~Kyverno cannot read the private GHCR packages.~~ CLOSED — Factory#563.**

   All five service packages — `aifactory`, `pfactory`, `tfactory`, `cfactory`,
   `cfactory-frontend` — went public on 2026-08-05. The gap reopened for the
   runner images on the same day (Factory#524): two of the eleven
   `tfactory-runner-*` packages, `tfactory-runner-nix` and
   `tfactory-runner-portal-ui`, were private. They were correctly signed and
   unverifiable anyway, because Kyverno has no GHCR credential at all — it runs
   with `--registryCredentialHelpers=default,google,amazon,azure,github` and no
   imagePullSecret in the `kyverno` namespace, so it reads ghcr.io anonymously.

   **Closed on 2026-08-07 by making both packages public**, matching the nine
   framework runners and all five service packages. `verify-tfactory-runner-signature`
   already named them — its glob is `ghcr.io/olafkfreund/tfactory-runner-*` — so
   **no policy rule changed and none needed to. The gap was read access, never
   coverage.** Verified with an empty credential store, which is exactly what
   Kyverno has:

   ```
   $ DOCKER_CONFIG=<empty> cosign verify \
       --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
       --certificate-identity-regexp='^https://github\.com/olafkfreund/TFactory/\.github/workflows/(nix-runner-image|portal-ui-runner-image|runner-images)\.yml@refs/heads/main$' \
       ghcr.io/olafkfreund/tfactory-runner-nix:latest
   Subject: .../workflows/nix-runner-image.yml@refs/heads/main

   ... tfactory-runner-portal-ui:latest
   Subject: .../workflows/portal-ui-runner-image.yml@refs/heads/main
   ```

   and through the live webhook, no Secret in the `kyverno` namespace, a server
   dry-run of a Pod carrying both plus a public runner — zero warnings, and the
   annotation Kyverno writes onto what it admits:

   ```
   kyverno.io/verify-images: {"ghcr.io/olafkfreund/tfactory-runner-nix:latest":"pass",
     "ghcr.io/olafkfreund/tfactory-runner-portal-ui:latest":"pass",
     "ghcr.io/olafkfreund/tfactory-runner-pytest:latest":"pass"}
   ```

   All eleven runner packages and all five service packages now answer an
   anonymous `ghcr.io/token` request with a token that reads their manifests.

   `odin` was still 403ing when this was written and went public later the same
   day, so **no first-party package is private any more**. That unblocks the
   rule it was denied — Factory#572, which owns both the rule and the section
   below.

#### The credential path, built and then removed

   A `--imagePullSecrets=kyverno-ghcr-pull` flag on both verifying controllers
   was the first fix attempted, on the assumption that visibility could not be
   changed (`PATCH user/packages/container/<name>` returns 404; it is a UI-only
   operation, and the toggle would not commit at the time). **The flag is now
   removed**, and not for tidiness:

   - the Secret it named was never created — `kubectl -n kyverno get secret
     kyverno-ghcr-pull` returns NotFound — so it was inert; and
   - the mutation check on it found a new Enforce blocker, Factory#566.

   | State | Warnings | Which |
   | --- | --- | --- |
   | No flag, no credential | 2 | the two private runners |
   | Flag live, credential absent | 2 | the two private runners |
   | Flag live, credential **wrong** | 16 | everything |
   | Both packages public, no flag, no credential | **0** | — |

   Row 3 is why the flag is gone. A wrong or **expired** credential does not
   degrade to the anonymous path — it unverifies the whole fleet, and classic
   PATs default to 30-day expiry. `failurePolicy: Ignore` does not cover it,
   because Kyverno is healthy and returning a considered fail. Leaving a dormant
   flag pointing at a Secret nobody maintains puts that failure mode in front of
   Factory#522's Enforce flip in exchange for nothing. Row 4 is the state today.

   The rule deliberately does *not* exclude the two images. An accurate red
   naming a real gap was the point while the gap stood, and an exclusion would
   have permanently unverified the sandbox that generated code executes in.

#### If a factory package goes private again

   Then the credential comes back, and it goes on **both** verifying
   controllers. They build registry clients independently
   (`internal.WithRegistryClient()` in `cmd/kyverno/main.go` and
   `cmd/reports-controller/main.go`): `kyverno-admission-controller` verifies at
   admission, `kyverno-reports-controller` verifies on the background scan. A
   credential on only one leaves half the evidence broken — admission-time
   warnings clearing while the PolicyReport board keeps the same images red, or
   the reverse. `kyverno-background-controller` builds no registry client
   (generate / mutateExisting only) and `kyverno-cleanup-controller` verifies
   nothing, so neither needs it.

   ```yaml
   - target: { group: apps, version: v1, kind: Deployment,
               name: '^kyverno-(admission|reports)-controller$' }
     patch: |-
       - op: add
         path: /spec/template/spec/containers/0/args/-
         value: --imagePullSecrets=kyverno-ghcr-pull
   ```

   The Secret is not in this repo — there is no SOPS and no sealed-secrets
   (`docs/secrets-management.md`), so it is created out-of-band exactly like
   `factory/ghcr-pull` and `minio-creds`. Create it with `kubectl create secret
   docker-registry`, never `kubectl apply`: an apply writes the full plaintext
   into the `kubectl.kubernetes.io/last-applied-configuration` annotation, which
   is Factory#448 and already happened to `factory/ghcr-pull` (Factory#565).

   ```bash
   printf '%s' "$PAT" > /dev/shm/pat            # never on the command line
   kubectl create secret docker-registry kyverno-ghcr-pull -n kyverno \
     --docker-server=ghcr.io --docker-username=olafkfreund \
     --docker-password="$(cat /dev/shm/pat)"; shred -u /dev/shm/pat
   ```

   The PAT needs `read:packages` **and nothing else** — this credential sits in
   a component that reads every image reference in the fleet. A fine-grained PAT
   cannot be used: the runner packages are unlinked from any repository
   (TFactory#952 — their Dockerfiles omit `org.opencontainers.image.source`) and
   fine-grained package permissions are repository-scoped, so a classic PAT with
   the single `read:packages` scope is the least privilege GHCR offers.

   Applying the flag before the Secret exists is safe:
   `generateKeychainForPullSecrets` in `pkg/registryclient/utils.go` treats a
   NotFound secret as skip-and-continue. The keychain is re-resolved from the
   secret lister on every image resolution (`autoRefreshSecrets.Resolve` in
   `pkg/registryclient/authn.go`), so creating the Secret later needs no
   redeploy — though the verify cache holds a failed result for
   `--imageVerifyCacheTTLDuration` (1h default), so
   `kubectl -n kyverno rollout restart` on both Deployments makes it immediate.

#### Telling the two failures apart

   Kyverno writes `unverified image` for a registry-read failure and for a
   signature verdict alike. That is the whole of Factory#430, so the
   distinguishing evidence is recorded rather than left to be re-derived. A read
   failure names the token endpoint:

   ```
   failed to verify image ghcr.io/olafkfreund/tfactory-runner-nix:latest:
   .attestors[0].entries[0].keyless: GET https://ghcr.io/token?scope=
   repository%3Aolafkfreund%2Ftfactory-runner-nix%3Apull&service=ghcr.io:
   UNAUTHORIZED: authentication required
   ```

   A signature verdict reads `no matching signatures`, `subject mismatch` or
   `issuer mismatch`, and never touches `ghcr.io/token`. Settle the read half
   without the cluster:

   ```bash
   curl -s "https://ghcr.io/token?scope=repository%3Aolafkfreund%2F<pkg>%3Apull&service=ghcr.io"
   ```

   A private package answers `denied` and 403s the manifest.

2. **`background: false` froze every report at admission.** A long-lived Pod was
   evaluated once, ever, and its report stayed green across arbitrarily many
   image changes. Audit results were a snapshot of whenever the Pod was last
   admitted, not a live signal.

   **Fixed 2026-08-05 (Factory#444)** — see [Evidence model: how fresh is a
   report?](#evidence-model-how-fresh-is-a-report) below.

## What this PR adds

Two ArgoCD Applications, auto-discovered by `bootstrap/argocd-root-app.yaml`:

1. `apps/kyverno/` — installs the **Kyverno** admission controller, rendered
   from the pinned upstream release `v1.12.6` via a kustomize remote resource
   (the same pattern `bootstrap/kustomization.yaml` uses for argo-cd). No
   admission controller (Kyverno or sigstore policy-controller) existed in the
   cluster before this.
   - Footprint: admission/background/cleanup/reports controllers in the
     `kyverno` namespace, Kyverno CRDs, and one ValidatingWebhookConfiguration.

2. `apps/kyverno-policies/` — the `verify-factory-image-signatures`
   **ClusterPolicy** (`verifyImages`), scoped to Pods in the `factory`
   namespace.

### The audit-mode policy

`apps/kyverno-policies/manifests/verify-factory-image-signatures.yaml`:

- `validationFailureAction: Audit` — violations go to a ClusterPolicyReport and
  a PolicyViolation event; the Pod is **admitted regardless**.
- `failurePolicy: Ignore` — if Kyverno is down or GHCR/Sigstore is unreachable,
  Pods are admitted (verification is a signal here, not a gate).
- One `verifyImages` rule per signed repo, each pinning that repo's keyless
  signer identity.

### Exact signer identities verified

The issuer is `https://token.actions.githubusercontent.com` (GitHub Actions
OIDC) for every rule. The subject is the GitHub Actions **workflow identity**,
anchored at both ends — see the Factory#522 note in the manifest for why the
old repo-prefix form was not good enough.

| Image reference                            | Certificate subject (regexp)                                                                    |
|--------------------------------------------|-------------------------------------------------------------------------------------------------|
| `ghcr.io/olafkfreund/aifactory:*`          | `^https://github\.com/olafkfreund/AIFactory/\.github/workflows/(deploy\|release\|build-nix)\.yml@refs/heads/main$` |
| `ghcr.io/olafkfreund/pfactory:*`           | `^https://github\.com/olafkfreund/PFactory/\.github/workflows/(deploy\|release)\.yml@refs/heads/main$`             |
| `ghcr.io/olafkfreund/tfactory:*`           | `^https://github\.com/olafkfreund/TFactory/\.github/workflows/(deploy\|release)\.yml@refs/heads/main$`             |
| `ghcr.io/olafkfreund/cfactory:*`, `cfactory-frontend:*` | `^https://github\.com/olafkfreund/CFactory/\.github/workflows/deploy\.yml@refs/heads/main$`           |
| `ghcr.io/olafkfreund/tfactory-runner-*`    | `^https://github\.com/olafkfreund/TFactory/\.github/workflows/(nix-runner-image\|portal-ui-runner-image\|runner-images)\.yml@refs/heads/main$` |

The alternation is load-bearing: `release.yml` publishes `:vX.Y.Z`,
`deploy.yml` publishes `:sha-<short>` (what every running Pod is on), and
`build-nix.yml` publishes `:sha-<short>-nix` (AIFactory's build image). Drop
one and real deployments stop verifying. CFactory publishes only from
`deploy.yml`.

### Runner images (Factory#524)

The first four rules cover the five **service** images — the control plane.
`verify-tfactory-runner-signature` covers the eleven **runner** images, which
are the sandbox that generated code is built and executed in:

| env var / consumer            | image                                                                                  |
|-------------------------------|----------------------------------------------------------------------------------------|
| `AIFACTORY_SANDBOX_IMAGE`     | `tfactory-runner-nix`                                                                    |
| `TFACTORY_VAL3_K8S_JOB_IMAGE` | `tfactory-runner-nix`                                                                    |
| `TFACTORY_NIX_RUNNER_IMAGE`   | `tfactory-runner-nix`                                                                    |
| `PORTAL_UI_IMAGE`             | `tfactory-runner-portal-ui`                                                              |
| lane dispatch                 | `tfactory-runner-{pytest,jest,playwright,vitest,cypress,java,selenium,cucumber,cloud}`    |

One rule covers all eleven. Unlike `cfactory` / `cfactory-frontend`, nothing
here is stopped by a literal `:`, and the bare `tfactory-runner-*` glob was
confirmed against kyverno **v1.18.2** — the cluster's exact version — to match
`ghcr.io/olafkfreund/tfactory-runner-<x>:<tag>`.

**Two of the eleven are expected to report `fail`.** `tfactory-runner-nix` and
`tfactory-runner-portal-ui` are private GHCR packages; the other nine are
public. Kyverno reads ghcr.io anonymously, so it cannot retrieve a signature it
cannot read. See [Blockers after this change](#blockers-after-this-change).

### Coverage: the rules only speak about images their globs name (Factory#564)

**User story.** I am on call, I open the signature board, and it says
`65 pass / 0 fail`. I want to know whether that sentence means the namespace is
verified. It did not. It meant *every image that happened to match a glob
verified*, and fourteen images were running that matched nothing at all.

`required: true` on a `verifyImages` rule means **a matched image must have a
signature**. It does *not* mean **every image must match a rule**. An image no
`imageReferences` glob names is admitted unverified and produces **no result at
all** — not a pass, not a fail, nothing. Under Enforce that is a silent bypass:
anything published under a name outside the globs is admitted without
verification.

This is the same green-from-absence shape as Factory#562, one level up. There,
a rule matched but ephemeral Job Pods left no standing result. Here, no rule
exists. In both cases "the audit is clean" is read off a report that was never
asked the question.

#### The fourteen, and what was done about each

| image | class | disposition |
|-------|-------|-------------|
| `ghcr.io/olafkfreund/skillai` | first-party, was unsigned | signed (SkillAi#303), rule `verify-skillai-signature` added |
| `ghcr.io/olafkfreund/skillai-migrator` | first-party, was unsigned | signed (SkillAi#303), same rule |
| `ghcr.io/olafkfreund/odin` | first-party, was unsigned | signed (Odin#4), rule `verify-odin-signature` added once the package went public (Factory#572) |
| `busybox`, `postgres`, `pgvector/pgvector`, `redis`, `python`, `quay.io/keycloak/keycloak`, `quay.io/minio/minio`, `quay.io/minio/mc`, `quay.io/oauth2-proxy/oauth2-proxy`, `docker.io/cloudflare/cloudflared`, `public.ecr.aws/zinclabs/openobserve`, `registry.k8s.io/sig-storage/nfs-provisioner` | third-party | out of scope by design, see below |

`skillai` deserves a note: it was the known-**unsigned** control used in the
Factory#522 deny experiment, chosen precisely because it was public, readable
and carried no signature — while running in this namespace the whole time.

#### Never put a rule in front of an image Kyverno cannot read

This section used to be headed "Why `odin` is signed but has no rule". Factory#572
closed that on 2026-08-07 and `verify-odin-signature` now exists. The heading
changed rather than the section being deleted, because the rule of order it
records is not about odin and outlives it.

**The order is: sign it, confirm the signature is READABLE the way Kyverno reads
it, and only then write the rule. Never the other way round.**

Skipping the middle step is the expensive mistake. A rule in front of an image
Kyverno cannot read does not report "no signature". It reports a **registry-auth
failure in the same words as a signature verdict** — the Factory#430 ambiguity —
and leaves a permanent misleading red on exactly the board Factory#522's Enforce
criterion is phrased against. `odin` was deliberately left ruleless for eleven
days on this reasoning while its GHCR package was private:

```bash
$ curl -s "https://ghcr.io/token?scope=repository%3Aolafkfreund%2Fodin%3Apull&service=ghcr.io"
{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}
```

That was the right call, and it cost nothing, because the absence was **not
silent**: `require-first-party-signature-coverage` reported odin accurately as an
uncovered first-party image, in the language of coverage rather than the language
of signatures. An honest gap on the board beats a misleading red on it.

##### How to confirm readability — not the obvious way

`docker pull`, `crane manifest` and a `ghcr.io/token` probe all read the
**manifest**. What Kyverno fetches in order to verify is the **`.sig` tag**
derived from the image digest (`sha256-<digest>.sig`). Those are different
objects and a package can serve one without the other, so check the one that
matters, with an empty keychain, the way Kyverno has no credential:

```bash
mkdir -p /tmp/nocreds && echo '{}' > /tmp/nocreds/config.json
DOCKER_CONFIG=/tmp/nocreds cosign verify \
  --certificate-identity-regexp '^https://github\.com/olafkfreund/Odin/\.github/workflows/deploy\.yml@refs/heads/main$' \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/olafkfreund/odin:sha-39ecd91
```

**Use `cosign`, not a hand-rolled `curl`, and if you must hand-roll it get the
`Accept` header right.** The `.sig` tag is an OCI **image manifest**; reusing the
index/list `Accept` header from a digest lookup returns **404 on every package,
public ones included**. That was hit for real while cross-checking this
(factory-gitops#180), and it is worse than an ordinary bug: a 404 there looks
exactly like the registry-auth failure a triager is already hunting, so the tool
being used to diagnose the Factory#430 ambiguity reintroduces it. `cosign`
negotiates this correctly and is the reason the recipe above is safe.

##### And read the identity off the signature, do not copy a neighbour

The other half of writing an honest rule. A `subjectRegExp` that is well-formed
but wrong admits nothing, and looks exactly like one that works until the day it
denies something. `verify-skillai-signature` is the standing proof: it anchors on
`refs/heads/core-mvp-foundation`, so a rule copied from any main-anchored
neighbour would silently reject every signature SkillAi produces.

Decode the certificate rather than assuming:

```bash
cosign download signature ghcr.io/olafkfreund/odin:sha-39ecd91 \
  | jq -r '.Cert.Raw' | base64 -d \
  | openssl x509 -inform der -noout -text | grep -A2 'Subject Alternative Name'
```

```
X509v3 Subject Alternative Name: critical
  URI:https://github.com/olafkfreund/Odin/.github/workflows/deploy.yml@refs/heads/main
```

Then mutate the rule to prove it is load-bearing. Measured for odin — wrong
subject `pass:0 fail:2`, wrong issuer `pass:0 fail:2`, restored `pass:2 fail:0`.
The wrong-subject failure has the engine name the true identity back at you,
which is the confirmation worth having:

```
subject mismatch:
expected ^https://github\.com/olafkfreund/CFactory/\.github/workflows/deploy\.yml@refs/heads/main$,
received https://github.com/olafkfreund/Odin/.github/workflows/deploy.yml@refs/heads/main
```

One mutation that does **not** go red: narrowing the glob (`odin:*` → `odin:v*`)
gives `pass: 0, fail: 0, skip: 0` — silence, not a verdict. Nothing offline
catches it. See factory-gitops#181.

#### The control that closes the class: `require-first-party-signature-coverage`

Signing `odin` and `skillai` fixes two instances. The reason fourteen
accumulated is that **nothing objected**, so the fix that matters is the one
that makes the *next* unmatched first-party image fail on its own.

`apps/kyverno-policies/manifests/require-first-party-signature-coverage.yaml`
is a separate ClusterPolicy that reports any `ghcr.io/olafkfreund/*` image
running in `factory` that no glob in `verify-factory-image-signatures` names.

Read its board as:

| result | meaning |
|--------|---------|
| `fail` | a real coverage gap — this image is admitted with no signature check |
| `skip` | this Pod was checked and has no uncovered first-party image |
| `pass` | never emitted; this rule verifies nothing itself |

There are a lot of `skip` rows — roughly one per Pod, and this namespace runs
about 140 including retained Job Pods. That is deliberate. `skip` says "this
rule looked here and had nothing to say"; silence is indistinguishable from the
rule not running, and that indistinguishability *is* the bug being fixed.

**Known limitation (Factory#574): this rule emits no admission warning.** At
`Audit`, a `verifyImages` rule returns both a `Warning` header and a standing
report result; a `validate` rule returns only the standing result. So
`kubectl apply --dry-run=server` of a Pod carrying an uncovered image comes back
clean even though the rule fails that Pod in its PolicyReport. An uncovered
first-party image used *only* by ephemeral Job Pods is therefore caught by
neither channel — no standing result because the Pod is gone (Factory#562), no
warning because of the rule type. Every first-party image today is used by a
long-running workload, which is fully covered. Do not "fix" this by switching
the rule to `verifyImages`; that loses the standing result, which is the point.

**Options considered, and why this shape.**

| option | verdict |
|--------|---------|
| A sixth `verifyImages` rule in the existing policy: `imageReferences: ghcr.io/olafkfreund/*`, `required: true`, no attestor | **Rejected, measured.** It is schema-valid and works beautifully at admission (warns `unverified image ...` with no registry call). But `required: true` reads the `kyverno.io/verify-images` annotation Kyverno writes at admission time, which absent Pods do not have on a background scan. The reports controller logs `missing image metadata in annotation key=kyverno.io/verify-images` and emits nothing. Measured on this cluster: five of five uncovered images warned at admission, and **zero** rows were added to the PolicyReports over a full scan. It would have left the board reading `66 pass / 0 fail` — the exact defect, reintroduced by its own fix. |
| The same, with any real attestor | **Rejected.** Any attestor means Kyverno must read the image. `odin` was private when this was decided, so the failure would have read `UNAUTHORIZED: authentication required` — Factory#430 all over again. Every first-party package is public today (Factory#563, #572), so that is no longer a live example, but the property is why this shape was chosen and it does not depend on today's visibility: the `validate` form never touches a registry, so it **cannot** produce that ambiguity for any image, including one made private tomorrow. A coverage control has to keep answering "is this covered?" when the registry is unreachable — that is precisely when an unnoticed gap does the most damage. |
| An explicit allowlist rule naming the twelve third-party images | **Rejected.** A rule that lists twelve images and then does nothing is ceremony: it creates a maintenance burden and the appearance of coverage without any. The declaration belongs in this document, which is where it now is. |
| Digest-pinning third-party images | **Right control, wrong change.** It is genuinely valuable — a pinned digest cannot be repointed under a running cluster — but it is a different policy against manifests owned elsewhere, and it would add twelve standing Audit failures that nobody intends to clear soon, directly harming Factory#522. Tracked in Factory#573. |
| Do nothing and document the limit | **Rejected.** Cheapest, but leaves the board over-claiming, which is the whole complaint. |

**Why a separate policy rather than a sixth rule in the same file.** It needs
`pod-policies.kyverno.io/autogen-controllers: none`, and that annotation is
policy-wide. The five `verifyImages` rules depend on autogen — most of their 66
results come from autogen'd ReplicaSets and Deployments — so setting it there
would gut the existing board. It also keeps the two tallies separable, which
matters because Factory#522's criterion is phrased in terms of the signature
board specifically.

#### Third-party images are out of scope by design, not by oversight

Twelve third-party images run in `factory`. We cannot sign them, and they do not
publish cosign signatures under an identity we could pin, so no attestor honest
enough to be worth writing exists for them. Inventing one would be theatre: a
rule that passes because it asks nothing is exactly the failure mode this issue
is about.

The coverage policy is therefore scoped to `ghcr.io/olafkfreund/*` **so that its
silence about third-party images is a stated boundary rather than an accident of
which globs someone happened to write.** The appropriate control for them is
digest pinning (Factory#573), not signature verification.

#### When you add a rule, update the mirror in the same commit

The coverage policy carries a regex mirroring the globs in
`verify-factory-image-signatures`. It is duplication and it can drift.

- A glob added **there** but not **here** produces a false `fail` for an image
  that is in fact covered. Noisy, self-correcting, someone investigates.
- A glob added **here** but not **there** reopens the silent hole. This is the
  dangerous direction. When in doubt, leave an entry out.

Both directions are covered by the test suite. It runs offline against the same
Kyverno version the cluster runs:

```bash
kubectl -n kyverno get deploy kyverno-admission-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}'   # match this version
kyverno test apps/kyverno-policies/tests/
```

That test proves rule *logic* only; it reaches no registry and does not test
signature verification. Policy files must additionally survive the live webhook,
because a file Kyverno rejects is a file ArgoCD cannot apply — and ArgoCD then
keeps serving the previous version while reporting healthy, which is how
Factory#430 lost its `subjectRegExp` for weeks:

```bash
kubectl apply --dry-run=server -f apps/kyverno-policies/manifests/
```

Confirm that check is not vacuous before trusting it. Delete the `rekor:` block
from a keyless attestor and re-run: the webhook must answer
`Either Rekor URL or roots are required`. If it does not, you are validating
nothing.

#### A note on the SkillAi ref anchor

`verify-skillai-signature` anchors on `refs/heads/core-mvp-foundation`, not
`refs/heads/main`. That is SkillAi's default branch, the only branch its
`deploy-image.yml` publishes from, and what ArgoCD tracks in
`apps/skillai/application.yaml`. Every other rule in the file anchors on main;
copying one of them for a new SkillAi image would silently reject its signature.

`skillai` and `skillai-migrator` are listed as two globs for the same reason
`cfactory` and `cfactory-frontend` are: the literal `:` in
`ghcr.io/olafkfreund/skillai:*` stops it matching `skillai-migrator:*`.

## Reading the audit results

After merge and sync, check what would have been denied:

```bash
# Violations across the factory namespace
kubectl get clusterpolicyreport -o wide
kubectl get policyreport -n factory -o wide

# Detail for the signature policy
kubectl describe clusterpolicyreport | grep -A5 verify-factory-image-signatures

# Always read the reason before acting on a fail. Since Factory#444 turned on
# `background: true` the stored result message carries the specific reason, so
# this is usually enough on its own — see "Triage: the message is specific now".
kubectl get policyreport -n factory -o jsonpath='{range .items[*].results[?(@.result=="fail")]}{.rule}{": "}{.message}{"\n"}{end}'

# Fallback, and still the only source for an admission-time (non-background)
# verdict.
kubectl -n kyverno logs deploy/kyverno-admission-controller \
  | grep 'failed to verify image'
```

### Triage: the message is specific now (correction to Factory#430)

The manifest header and an earlier revision of this page both said the report
does not distinguish "the signature is bad" from "Kyverno could not reach the
registry or Sigstore", and that you must read the admission-controller log to
tell them apart. **That is no longer true of the stored report.** It was true of
the summary columns and of the flattened admission warning, and it was measured
before `background: true`.

Verified 2026-08-05 under Factory#522 (see "Observing a deny", below). Three
different causes, three different `results[].message` values in the PolicyReport
written by the background scan:

| Cause | `results[].message` |
| --- | --- |
| Signed, but by an identity the rule does not accept | `subject mismatch: expected <regexp>, received <actual subject>` |
| No signature at all | `no signatures found` |
| Registry unreadable (private package, anonymous Kyverno) | `GET https://ghcr.io/token?scope=...: UNAUTHORIZED: authentication required` |

The first two are signature verdicts. The third is a transport failure. The
Factory#430 DNS outage is also a transport failure and names `tuf` / `fulcio` /
`rekor` in the same position.

The `subject mismatch` message is the most useful of the three: it prints both
the pinned regexp and the subject actually presented, which makes an identity
typo self-diagnosing rather than a bisect.

What *is* still flattened is the admission-time warning pair. Creating a Pod
under Audit emits **two** warnings for one failure — the specific one and a
generic one:

```
Warning: policy ...probe-deny-unsigned: failed to verify image ghcr.io/olafkfreund/skillai:42578c7dc32a: .attestors[0].entries[0].keyless: no signatures found
Warning: policy ...probe-deny-unsigned: unverified image ghcr.io/olafkfreund/skillai:42578c7dc32a
```

Read the first. `unverified image` on its own carries no cause and is the line
that produced the Factory#430 ambiguity.

To replay verification for a specific image without deploying anything, submit
a throwaway Pod through admission with a server-side dry run. Kyverno evaluates
it and returns the reason as a warning; nothing is persisted:

```bash
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: sig-probe, namespace: factory }
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: ghcr.io/olafkfreund/aifactory:sha-6b116ee
      command: ["sleep", "1"]
EOF
```

A clean `pod/sig-probe created (server dry run)` with no warning is a pass.

An all-`pass` report for aifactory/pfactory/tfactory/cfactory Pods is the green
light for the next phase.

## Observing a deny (Factory#522)

Factory#522 requires the policy be *seen denying* before it is trusted to deny:
"Audit -> Enforce should not be a one-line change taken on trust." A policy that
has only ever been observed passing has never demonstrated the half of its
behaviour that the flip actually turns on.

The obstacle is that **an Audit policy cannot deny**. Running the dry-run probe
above against an unsigned image returns a *warning* and `created (server dry
run)`. That is the policy declining to block, which is not evidence that it
would block.

### Experiment

Run 2026-08-05. A temporary `Enforce` copy of the policy, scoped to a throwaway
namespace, carrying the **same attestor configuration** as the real rules, with
`useCache: false` so every case was a real registry and Rekor round trip rather
than a cached verdict.

Scoping, which is the load-bearing safety property — an over-broad Enforce
policy wedges the fleet:

- `match.any[].resources.namespaces: [sigpolicy-probe]` on every rule, so it
  could not match anything in `factory`.
- `kinds: [Pod]` only, and `pod-policies.kyverno.io/autogen-controllers: none`
  so Kyverno generated no Deployment/ReplicaSet variants.
- `background: false` for the Enforce phase, so it wrote no PolicyReports.
- Created directly with `kubectl`, never committed, and deliberately **not**
  labelled for ArgoCD, so the `kyverno-policies` app (which runs
  `prune: true, selfHeal: true`) did not track it and could not act on it.

Four cases, chosen so that each isolates one variable:

| Case | Image | Attestor | Expected |
| --- | --- | --- | --- |
| A | `aifactory:sha-6b116ee` | real AIFactory rule, verbatim | admit |
| B | `pfactory:sha-2089d44` | real PFactory rule with the ref changed to `refs/heads/attacker-branch` | deny, signature verdict |
| C | `skillai:42578c7dc32a` | AIFactory rule | deny, signature verdict |
| D | `tfactory-runner-nix:latest` | real runner rule, verbatim | deny, transport verdict |

Case C uses `ghcr.io/olafkfreund/skillai` because it is public (so Kyverno can
read it anonymously) and carries no cosign signature — the same registry and the
same anonymous auth path as case A, so the only variable is the signature.

Case B is the scenario the Factory#522 `subjectRegExp` anchoring exists to
close: a correctly signed image, from the right repo and the right workflow, on
the wrong ref.

### Result: it denies

Case B — wrong identity. A genuine rejection, not a warning:

```
$ kubectl apply --dry-run=server -f pod-b.yaml
Error from server: error when creating "pod-b.yaml": admission webhook
"mutate.kyverno.svc-ignore" denied the request:

resource Pod/sigpolicy-probe/probe-b-wrong-identity was blocked due to the following policies

tmp-sigpolicy-deny-probe:
  probe-deny-wrong-identity: 'failed to verify image ghcr.io/olafkfreund/pfactory:sha-2089d44:
    .attestors[0].entries[0].keyless: subject mismatch: expected ^https://github\.com/olafkfreund/PFactory/\.github/workflows/deploy\.yml@refs/heads/attacker-branch$,
    received https://github.com/olafkfreund/PFactory/.github/workflows/deploy.yml@refs/heads/main'
```

Case C — no signature at all:

```
$ kubectl apply --dry-run=server -f pod-c.yaml
Error from server: error when creating "pod-c.yaml": admission webhook
"mutate.kyverno.svc-ignore" denied the request:

resource Pod/sigpolicy-probe/probe-c-unsigned was blocked due to the following policies

tmp-sigpolicy-deny-probe:
  probe-deny-unsigned: 'failed to verify image ghcr.io/olafkfreund/skillai:42578c7dc32a:
    .attestors[0].entries[0].keyless: no signatures found'
```

### Result: it admits

A gate that denies everything is not a working gate. Case A, the real AIFactory
attestor against the real running image, under the same Enforce policy:

```
$ kubectl apply --dry-run=server -f pod-a.yaml
pod/probe-a-admit created (server dry run)
```

That on its own is weak — a rule that never matched would look identical. So the
same rule was also run under an Audit copy with `background: true`, which records
what it actually did:

```
rule   : probe-admit-correct-identity
result : pass
message: 'verified image signatures for ghcr.io/olafkfreund/aifactory:sha-6b116ee'
```

The rule evaluated, fetched, and verified. The admit is a verification, not a
non-match.

### Result: the two failure modes are distinguishable

This is the Factory#430 lesson, and the experiment puts both modes on the record
side by side. Case D is a correctly signed image that Kyverno cannot read:

```
$ kubectl apply --dry-run=server -f pod-d.yaml
Error from server: error when creating "pod-d.yaml": admission webhook
"mutate.kyverno.svc-ignore" denied the request:

resource Pod/sigpolicy-probe/probe-d-unreadable was blocked due to the following policies

tmp-sigpolicy-deny-probe:
  probe-deny-unreadable: 'failed to verify image ghcr.io/olafkfreund/tfactory-runner-nix:latest:
    .attestors[0].entries[0].keyless: GET https://ghcr.io/token?scope=repository%3Aolafkfreund%2Ftfactory-runner-nix%3Apull&service=ghcr.io:
    UNAUTHORIZED: authentication required'
```

Same policy, same anchored identity, same `Enforce` — and the image *is*
correctly signed. `cosign verify` on a workstation that holds a GHCR read
credential returns its signature with subject
`.../TFactory/.github/workflows/nix-runner-image.yml@refs/heads/main`. The
in-cluster failure is purely that Kyverno reads ghcr.io anonymously.

So: **cases B and C are signature verdicts and mean the image is untrustworthy.
Case D is a transport verdict and means the verifier is blind.** Both deny under
Enforce, and the difference is only visible in the message. Never triage a red
without reading it.

The experiment also reproduced the ambiguity by accident, which is the best
evidence that it is a live hazard and not a historical footnote. Case C first
pointed at `ghcr.io/olafkfreund/odin`, chosen as an unsigned image because
`cosign verify` on a workstation reported `no signatures found`. In-cluster it
denied with `UNAUTHORIZED: authentication required` instead: `odin` **was** a
private package at the time, and the workstation had a credential the cluster
did not. (Both facts have since changed — odin is signed as of Odin#4 and its
package is public as of Factory#572 — but the ambiguity this accident exposed is
not historical, and the next private or unreachable image reproduces it.)
The local tool and the cluster disagreed about the same image for reasons that
had nothing to do with signing. Case C was repointed at `skillai`, which is
public, to get an actual signature verdict.

Practical rule from that: verifying with `cosign` on a workstation does not
predict what Kyverno will do, because your Docker config is not Kyverno's.
Reproduce with `docker logout ghcr.io` or a clean `DOCKER_CONFIG`.

### Cleanup

The temporary policy and namespace were deleted and the cluster confirmed back
at baseline, not assumed:

```
$ kubectl get cpol
NAME                              ADMISSION   BACKGROUND   READY   AGE   MESSAGE
verify-factory-image-signatures   true        true         True    10d   Ready

$ kubectl get ns | grep -c probe
0

$ kubectl get cpol verify-factory-image-signatures \
    -o jsonpath='{.spec.validationFailureAction} {.spec.background} {.spec.failurePolicy}'
Audit true Ignore

# board tally, all results across all namespaces
{'pass': 65} total 65
reports per namespace: {'factory': 65}
```

One ClusterPolicy, still `Audit`, still five rules, 65 results all passing, all
in `factory` — identical to the pre-experiment baseline.

## Evidence model: how fresh is a report?

Since 2026-08-05 the policy runs `background: true` (Factory#444). Before that,
a resource was verified exactly once — at admission — and its PolicyReport held
that verdict until the resource was replaced. "Audit is quiet" was a statement
about the last rollout, not about the cluster now.

### Do not read `metadata.creationTimestamp`

The PolicyReport object is created once per resource UID and then **updated in
place**. Its `creationTimestamp` is the age of the object, not the age of the
verdict, and it never advances. Five Deployment-scoped reports in `factory`
still carry creation dates of 2026-07-26 through 07-31 while holding results
recomputed the same hour you read them.

The field that actually advances is `results[].timestamp`, and
`results[].properties.process` says which mechanism produced it —
`admission review` or `background scan`:

```bash
kubectl --context factory -n factory get policyreport -o json | jq -r '
  .items[] | "\(.scope.kind)/\(.scope.name)  \(.results[0].result)  " +
  "\(.results[0].properties.process)  " +
  (.results[0].timestamp.seconds | todate)'
```

### Which controller does the work

The background scan is run by **`kyverno-reports-controller`**, not by the
deployment named `kyverno-background-controller`. The relevant flags all live on
the reports controller:

```
--backgroundScan=true
--backgroundScanInterval=1h
--backgroundScanWorkers=2
--enableReporting=validate,mutate,mutateExisting,imageVerify,generate
```

Each resource re-queues itself for `--backgroundScanInterval` after its own
reconcile, so a "sweep" is a rolling band of about six minutes rather than an
instant, and resources drift onto their own phase. Writing to the policy
short-circuits all of it: a change to the ClusterPolicy re-enqueues every
matched resource immediately, which is why an ArgoCD sync of this file is
followed within seconds by a full recompute — and, because the cache key
contains the policy `resourceVersion`, by a fully cold cache.

`kyverno-background-controller` handles `generate` and `mutateExisting` rules and
has nothing to do with this policy. Factory#561 (background- and
cleanup-controller restart loops) therefore does not make these reports
unreliable. What *would* is the reports controller restarting; watch that one:

```bash
kubectl --context factory -n kyverno get pod \
  -l app.kubernetes.io/component=reports-controller
```

### The `useCache` ceiling

`useCache: true` is pinned on every rule (it is also Kyverno's default). The
image verify cache is:

- **positive-only** — only a `pass` is cached, a failure is never remembered;
- **in-process** — the admission controller and the reports controller keep
  separate caches, and a restart empties them;
- keyed on `policyUID;policyResourceVersion;ruleName;imageRef`, so **any edit to
  the policy file invalidates every entry**;
- expiring on `--imageVerifyCacheTTLDuration`, unset here, so the **60m default**
  applies.

The theoretical consequence is that a background scan could serve a `pass`
computed up to 60 minutes earlier, pushing detection of a revoked signature out
towards two intervals.

**Measured, it does not.** TTL (60m) is not longer than the scan interval (60m),
so an entry set during one sweep has expired by the next. Three consecutive
sweeps on 2026-08-05, the third with no policy write in between so the cache was
genuinely warm:

| Sweep | Window (UTC) | Fresh | From cache | Distinct images verified |
|---|---|---|---|---|
| 1 | 14:50:45–14:51:04 | 52 | 13 | 45 |
| 2 | 15:22:47–15:28:34 | 42 | 23 | 45 |
| 3 | 16:22:47–16:28:35 | **53** | **12** | 46 |

Sweep 3 followed sweep 2 by exactly one hour with nothing touching the policy,
and still re-verified 53 of 65 results against GHCR and Rekor. The dozen cache
hits are *intra*-sweep: the same image reference sits on several retained
ReplicaSets, and the first one to be scanned populates the entry for the rest.
Nothing carries across a sweep boundary.

So `useCache: true` behaves as deduplication within a scan, not as a mechanism
that keeps a stale positive alive across one. A revoked signature or a repointed
tag surfaces on the next sweep, within the hour.

This holds only while the TTL is not raised above the scan interval. If anyone
sets `--imageVerifyCacheTTLDuration` higher than `--backgroundScanInterval`, the
theoretical staleness above becomes real, and the check for it is the
fresh-versus-cached split below.

Note the key is the **image reference**, not the digest, because this policy
runs `verifyDigest: false`. A tag repointed to a different digest keeps the same
cache key, which is precisely the case the TTL bounds.

If that window ever needs to be tighter, lower
`--imageVerifyCacheTTLDuration` on `kyverno-reports-controller`. Do **not** set
`useCache: false`: the same field governs the admission hot path, and turning it
off puts a full Rekor round trip in front of every AIFactory build Job and
TFactory verify Job Pod.

### Cost

Measured on the first background sweep after the flip, 2026-08-05T14:50:47Z:

| Quantity | Value |
|---|---|
| Resources walked per scan (whole namespace) | ~250 |
| Resources producing a result | 65 |
| — of which ReplicaSet / Deployment / Pod | 55 / 5 / 5 |
| Results served from cache within the sweep | 13 |
| Fresh cosign verifications | 52 |
| Distinct `(rule, image reference)` pairs verified | 45 |
| **Registry + Rekor calls per hour** | **~50** |
| Per day, ghcr.io and rekor.sigstore.dev | ~1,200 |

Confirmed in steady state: the third sweep, an hour later with a warm cache, did
53 fresh verifications. The rate is not a cold-start artefact.

Both numbers are far below either service's limits, but note where the cost
actually comes from — it is **not** the five running images.

**ReplicaSets dominate.** Kyverno's autogen rules match every pod controller, and
`kyverno-reports-controller` runs with `--skipResourceFilters=true`, so the
`[ReplicaSet,*,*]` entry in the `kyverno` ConfigMap's `resourceFilters` does not
apply to background scans. Every retained ReplicaSet of every service is
therefore verified each interval, each on the historical `sha-*` tag it was
created with — 41 distinct image references, not 5.

**The load is bounded by `revisionHistoryLimit`, not by traffic.** All five
services run the default 10, so the ceiling is 5 x (10 old + 1 current) = 55
ReplicaSets, plus 5 Deployments and 5 Pods = 65, which is exactly what is
observed. Raising `revisionHistoryLimit` raises this linearly; a service that
deploys more often does not.

The ~110 `python:3.12-slim` CronJob Pods match no glob and produce no report and
no registry call.

### Watching the cache work

Kyverno says which path it took, in the report message itself:

```bash
kubectl --context factory -n factory get policyreport -o json \
  | jq -r '.items[].results[].message' | sort | uniq -c | sort -rn | head
```

- `verified image signatures for ghcr.io/olafkfreund/<image>:<tag>` — a real
  round trip to GHCR and Rekor happened.
- `verified from cache` — served from the TTL cache described above.

That is the instrument for the ceiling: if a sweep is entirely
`verified from cache`, nothing was actually re-verified that hour.

### DNS fragility, now continuous

With `background: false` a Sigstore outage produced one bad report per admission.
With `background: true` it produces failing reports across the whole namespace,
every scan interval, until connectivity returns. That is the correct behaviour —
it is a live signal — but it means olafkfreund/nixos_config#1232 (the
non-declarative resolv.conf repair behind Factory#430) now shows up as sustained
fleet-wide red rather than a quiet one-off. Before treating a red sweep as a
signing problem, check the transport first, exactly as the manifest header says.

## Phased path to Enforce

Do NOT skip a phase. Each is a separate, small PR.

1. **Audit (this PR).** Land the policy in `Audit`. Watch PolicyReports for a
   sustained period across real runs. Confirm the three signed services report
   `pass` and there are no false negatives (registry timeouts, identity typos).

   Concretely, after Factory#430 this phase is not complete until **every**
   currently-running Pod has been rebuilt by a signing workflow. Signing the CD
   workflows does not retroactively sign the images already deployed — the
   `sha-*` images live in the cluster today were built before the cosign step
   existed and can never verify. Each service must land one more commit on
   `main` (or a `workflow_dispatch` re-run of `deploy.yml`) before its Pods can
   report `pass`. Check with:

   ```bash
   kubectl --context factory get pods -n factory \
     -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u
   ```

   and verify each tag directly:

   ```bash
   cosign verify \
     --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
     --certificate-identity-regexp='^https://github\.com/olafkfreund/AIFactory/' \
     ghcr.io/olafkfreund/aifactory:<the-tag-actually-running>
   ```

   **Done 2026-08-05** (Factory#430). Every running fleet Pod reports `pass`:

   ```
   $ kubectl -n factory get policyreport \
       -o custom-columns=SCOPE:.scope.name,PASS:.summary.pass,FAIL:.summary.fail
   SCOPE                                PASS   FAIL
   aifactory-6747449559-znpmp           1      0
   pfactory-597ddb58fc-bhgjr            1      0
   tfactory-5c4c587c6-j2ptc             1      0
   cfactory-8484f659c5-rbkj5            1      0
   cfactory-frontend-788cc886f5-ptsdj   1      0
   ```

2. **Sign CFactory (CFactory#191).** **Done.** CFactory signs both images from
   `deploy.yml` (CFactory#191 + #247) and the `verify-cfactory-signature` rule
   covers `ghcr.io/olafkfreund/cfactory:*` and `cfactory-frontend:*`.

3. **Confirm clean.** Every factory Pod (all four services) must report `pass`
   in the ClusterPolicyReport, over at least one full release cycle of each.
   Any Pod still on an unsigned tag must be redeployed onto a signed image
   first.

   First clean sweep observed 2026-08-05 (above). Phase 1's "sustained period
   across real runs" is deliberately not claimed yet — one sweep is a start,
   not a record.

   Factory#444 is now closed, so a green report is recomputed every hour rather
   than dating from the last admission. That is what makes a *record* possible:
   the evidence for this phase is consecutive clean background sweeps, read via
   `results[].timestamp` and `results[].properties.process` as described in
   [Evidence model](#evidence-model-how-fresh-is-a-report), never via
   `creationTimestamp`.

3b. **Cover the runner images (Factory#524).** **Done.**
   `verify-tfactory-runner-signature` covers all eleven `tfactory-runner-*`
   images. Nine verified anonymously from the start; `tfactory-runner-nix` and
   `tfactory-runner-portal-ui` failed with `UNAUTHORIZED: authentication
   required` because they were private GHCR packages. Closed by Factory#563 on
   2026-08-07 — both packages were made public, so all eleven verify
   anonymously and Kyverno needs no credential. See [Blockers after this
   change](#blockers-after-this-change).

3c. **Observe a deny (Factory#522).** **Done 2026-08-05.** The policy has been
   seen rejecting a wrong-identity image and an unsigned image, admitting a
   correctly signed one, and distinguishing a signature verdict from a transport
   failure — all under a scoped, temporary `Enforce` copy carrying the real
   attestor configuration. Full method, exact output and cleanup verification in
   [Observing a deny](#observing-a-deny-factory522).

4. **Enforce.** Flip `validationFailureAction: Audit` -> `Enforce`.

   **Not yet.** Two preconditions remain, and three of the five are settled.

   | # | Precondition | State |
   | --- | --- | --- |
   | 0 | The policy has been observed denying and admitting | **Met**, 2026-08-05 |
   | 1 | Every image a rule matches is readable by Kyverno | **Met**, 2026-08-07 — Factory#563 |
   | 1b | The credential that makes it readable cannot go stale unnoticed | **Moot** — there is no credential; Factory#566 |
   | 2 | Runner coverage is actually evidenced | Open — Factory#562 |
   | 3 | The DNS repair behind Factory#430 is declarative | Open — olafkfreund/nixos_config#1232 |

   **1. Two runner packages are private (Factory#563). Closed.**
   `tfactory-runner-nix` and `tfactory-runner-portal-ui` were private GHCR
   packages. Kyverno holds no registry credential and reads ghcr.io
   anonymously, so it got `UNAUTHORIZED: authentication required` — the exact
   case D deny quoted above. Under Enforce that would have denied **every build
   and verify Job in the fleet**, because those two images are
   `AIFACTORY_SANDBOX_IMAGE`, `TFACTORY_NIX_RUNNER_IMAGE`,
   `TFACTORY_VAL3_K8S_JOB_IMAGE` and `PORTAL_UI_IMAGE`. Both images are
   correctly signed; it was purely a read permission.

   **Closed 2026-08-07 by making both packages public.** Both now verify
   anonymously against the rule's anchored identity, and a server dry-run of a
   Pod carrying both returns zero warnings with
   `kyverno.io/verify-images` reporting `pass` for each. No rule changed —
   the runner glob already named them. See
   [Blockers after this change](#blockers-after-this-change).

   **1b. The credential single point of failure (Factory#566). Moot, by
   removal.** Mutation-checking the credential path found that a wrong, revoked
   or **expired** credential in `kyverno/kyverno-ghcr-pull` does not degrade to
   the anonymous path — it breaks verification for **every image in the fleet**,
   including the fourteen that verify fine with no credential at all:

   ```
   credential absent  ->  2 warnings   (the two private runners only)
   credential wrong   -> 16 warnings   (all 5 services + all 11 runners)
   ```

   `go-containerregistry`'s keychain resolves ghcr.io to the pull-secret
   credential and returns it. There is no fallback: an authenticated request
   that fails auth is a failed request, not a cue to retry anonymously.
   `failurePolicy: Ignore` does not cover it either — Ignore covers Kyverno
   being unreachable, and here Kyverno is healthy and returning a considered
   fail. Classic PATs default to 30-day expiry, and nothing watched it.

   **There is no credential today.** The `--imagePullSecrets=kyverno-ghcr-pull`
   flag was removed along with the private packages it existed for, so this
   blocker does not stand in front of the flip. It comes back the moment a
   factory package goes private again, and the mitigation is recorded with the
   recipe: no expiry on the PAT, plus an authenticated registry probe alerting
   on 401/403. Kyverno offers no per-rule credential for `verifyImages` that
   would contain the blast radius — `imageRegistryCredentials` exists only
   under `rules[].context[].imageRegistry`, checked against the live v1.18.2
   CRD.

   **2. A green board is not evidence of runner coverage (Factory#562).**
   This one directly undermines the rollout criterion this document has used
   since phase 1, and it should be said plainly: **"Audit is quiet" does not
   mean "Enforce is safe."**

   Runner Pods are ephemeral Job Pods. They are created, they run, they are
   collected. They contribute **zero standing PolicyReport results**, so the
   board reads 65 pass / 0 fail *while two runner images are unverifiable* —
   the very condition that would deny every Job under Enforce. The board is
   green precisely because the failing workloads are not there to be counted.

   Phases 1 and 3 above tell you to wait for a sustained all-`pass` sweep. That
   criterion is sound for the five long-lived service Deployments and blind for
   the eleven runner images, which are the more security-relevant half — they
   are the sandbox generated code is built and executed in. Do not read a green
   board as coverage. Until Factory#562 gives runner verification a standing
   signal, the only evidence for the runner rule is direct: `cosign verify`
   against each of the eleven tags, plus a scoped Enforce probe of the kind
   described above.

   **3. The DNS repair is not declarative (olafkfreund/nixos_config#1232).**
   Factory#430's root cause was that no Pod could resolve external names, so
   Kyverno could not fetch the Sigstore TUF root. The repair is applied **by
   hand inside the node containers**. A `k3d cluster delete && create` reopens
   it, silently, and the first symptom under Enforce would be a fleet-wide
   admission failure rather than a report turning red. Enforcing on a control
   whose dependency is repaired manually and undeclared is how the gate takes
   the cluster down. This should be declarative before the flip, or the flip
   should be accompanied by a documented, rehearsed rollback.

   ### `failurePolicy`: keep `Ignore`

   An earlier revision of this section suggested tightening
   `failurePolicy: Ignore` -> `Fail` at the flip "so a verification outage
   blocks rather than admits". **That reasoning is wrong in both directions**,
   and the Factory#522 experiment shows why.

   `failurePolicy` governs only what the API server does when the webhook call
   itself fails — Kyverno unreachable, non-200, or past
   `webhookTimeoutSeconds: 30`. It does **not** govern what happens when
   Kyverno is reached, runs, and reports that it could not verify an image.
   That is a successful webhook call returning a deny.

   Case D is the proof. The image was unverifiable for a pure transport reason,
   and the request was rejected by the webhook named `mutate.kyverno.svc-ignore`
   — the `failurePolicy: Ignore` webhook denied it anyway:

   ```
   admission webhook "mutate.kyverno.svc-ignore" denied the request
   ```

   So there are two distinct regimes:

   - **Verifier reachable, verification fails** (bad signature, DNS failure that
     returns an error, registry 401). Kyverno denies. `failurePolicy` is not
     consulted. Under Enforce the fleet is blocked either way. This is the
     common case and the one that matters.
   - **Webhook unreachable or times out** (Kyverno down, upgrading, a Sigstore
     hang exceeding 30s). Only here does `failurePolicy` decide: `Ignore`
     admits, `Fail` blocks.

   `Fail` therefore buys coverage of a narrow slice — the *slow* subset of
   transport outages — while converting every Kyverno restart, upgrade or
   eviction into a cluster-wide deployment outage. Given precondition 3, where
   the DNS dependency can regress without warning, that is trading a small
   amount of theoretical bypass for a large amount of real, self-inflicted
   downtime.

   **Recommendation: keep `failurePolicy: Ignore` at the flip.** The concern
   that "under Enforce with Ignore a DNS outage admits everything unverified" is
   not what the evidence shows — a DNS outage that produces an error produces a
   *deny*, as Factory#430 did. Revisit `Fail` only once the DNS dependency is
   declarative and Kyverno itself is highly available; it is a separate change
   with its own blast radius, not a rider on the Enforce flip.

   ### Also worth knowing before the flip

   The policy verifies an image only if that image matches a rule glob.
   `required: true` means "a matched image must carry a signature", not "every
   image must match a rule". When Factory#564 was filed, 14 images ran in
   `factory` that no rule named, including two first-party ones (`odin`,
   `skillai`) that were also unsigned. Both are now signed and both have rules
   (SkillAi#303 + `verify-skillai-signature`; Odin#4 + `verify-odin-signature`,
   Factory#572), and `require-first-party-signature-coverage` reports **zero**
   uncovered first-party images. The remaining 12 are third-party and out of
   scope by design — digest pinning is their control, tracked in Factory#573.

   This is no longer a reason the green board over-claims. The reason it still
   might is narrower and is recorded above: a narrowed glob makes a rule fall
   silent rather than fail, and nothing offline catches it
   (factory-gitops#181).

   From the point of the flip, unsigned images matching a rule are denied at
   admission.

## Notes

- Scope is deliberately the `factory` namespace only. System namespaces
  (`kube-system`, `argocd`, `kyverno`, ...) are never subject to this policy.
- `verifyDigest: false` / `mutateDigest: false` in the audit phase: we verify
  the signature but do not yet require digest-pinned references or rewrite tags
  to digests. Digest pinning is a separate hardening step that can ride along
  with the Enforce move if desired.
- Kyverno version is pinned; bump it deliberately in
  `apps/kyverno/manifests/kustomization.yaml`, never track `latest`.
