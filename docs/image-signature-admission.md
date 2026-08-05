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

1. **~~Kyverno cannot read the private GHCR packages.~~ CLOSED.** All five
   factory GHCR packages — `aifactory`, `pfactory`, `tfactory`, `cfactory`,
   `cfactory-frontend` — are public as of 2026-08-05, and Kyverno verifies all
   of them anonymously. No `imageRegistryCredentials` wiring is needed.

   What remains true: Kyverno has no GHCR credential at all (it runs with
   `--registryCredentialHelpers=default,google,amazon,azure,github` and there
   is no imagePullSecret in the `kyverno` namespace). Making any factory
   package private again breaks verification immediately — a warning under
   Audit, a denial of every Pod using it under Enforce. Wire the credential
   *before* flipping a package to private, not after:

   ```yaml
   imageRegistryCredentials:
     providers: [github]
     secrets: [kyverno-ghcr-pull]     # must exist in the kyverno namespace
   ```

2. **`background: false` freezes every report at admission.** The `aifactory`
   Deployment is on generation 212; its PolicyReport is dated 2026-07-26 and
   has never been recomputed. A long-lived Pod is evaluated once, ever, and a
   report can stay green across arbitrarily many image changes. Audit results
   are therefore not a live signal today — they are a snapshot of whenever the
   Pod was last admitted.

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

The alternation is load-bearing: `release.yml` publishes `:vX.Y.Z`,
`deploy.yml` publishes `:sha-<short>` (what every running Pod is on), and
`build-nix.yml` publishes `:sha-<short>-nix` (AIFactory's build image). Drop
one and real deployments stop verifying. CFactory publishes only from
`deploy.yml`.

## Reading the audit results

After merge and sync, check what would have been denied:

```bash
# Violations across the factory namespace
kubectl get clusterpolicyreport -o wide
kubectl get policyreport -n factory -o wide

# Detail for the signature policy
kubectl describe clusterpolicyreport | grep -A5 verify-factory-image-signatures

# A fail is ambiguous — always read the reason before acting on it.
# "no signatures found" is a real verdict; anything mentioning tuf / fulcio /
# rekor / DNS is a transport failure, not an unsigned image.
kubectl -n kyverno logs deploy/kyverno-admission-controller \
  | grep 'failed to verify image'
```

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
   not a record. Note also that Factory#444 (stale reports, `background: false`)
   means a green report is only as current as the last admission.

4. **Enforce.** Only then flip `validationFailureAction: Audit` -> `Enforce`.
   Consider also tightening `failurePolicy: Ignore` -> `Fail` at this point so a
   verification outage blocks rather than admits — but weigh that against
   availability, and keep the `factory` namespace scope so a Sigstore outage can
   never wedge system namespaces. From this point unsigned images are denied at
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
