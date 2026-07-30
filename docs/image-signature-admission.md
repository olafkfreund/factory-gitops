# Image signature verification at admission (audit mode)

Status: AUDIT/WARN ONLY. The policy this PR introduces REPORTS unsigned or
wrongly-signed images; it does NOT deny them. Nothing here is applied to the
cluster by this PR — it is committed to GitOps for review, and ArgoCD will
reconcile it after merge.

Related: Factory#318, compliance program #310 (gap #8). Depends on CFactory#191
(CFactory image signing) before any move to Enforce.

## Where we are today

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

### Two blockers that remain open after this change

Neither is fixed here; both must close before Enforce.

1. **Kyverno cannot read the private GHCR packages.** `aifactory` is a public
   package; `pfactory`, `tfactory`, `cfactory` and `cfactory-frontend` are
   private. The kubelet pulls them with the `ghcr-pull` imagePullSecret in the
   `factory` namespace, but Kyverno verifies anonymously — it has no
   `--imagePullSecrets` flag and no credential secret in the `kyverno`
   namespace — so it cannot even fetch the manifest, let alone the signature:

   ```
   failed to verify image ghcr.io/olafkfreund/pfactory:sha-4452338:
   GET https://ghcr.io/token?scope=repository%3Aolafkfreund%2Fpfactory%3Apull:
   UNAUTHORIZED: authentication required
   ```

   Signing those images will not make this pass. The fix is a read-only GHCR
   credential in the `kyverno` namespace, referenced per rule:

   ```yaml
   imageRegistryCredentials:
     providers: [github]
     secrets: [kyverno-ghcr-pull]     # must exist in the kyverno namespace
   ```

   Deliberately not wired up in this PR: pointing the policy at a secret that
   does not exist yet is another control that looks configured and verifies
   nothing. Wire it and the secret together.

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

Taken verbatim from each repo's release.yml `Verify signature` self-test:

| Image reference                     | OIDC issuer                                      | Certificate subject (regexp)                   |
|-------------------------------------|--------------------------------------------------|------------------------------------------------|
| `ghcr.io/olafkfreund/aifactory:*`   | `https://token.actions.githubusercontent.com`    | `^https://github\.com/olafkfreund/AIFactory/`  |
| `ghcr.io/olafkfreund/pfactory:*`    | `https://token.actions.githubusercontent.com`    | `^https://github\.com/olafkfreund/PFactory/`   |
| `ghcr.io/olafkfreund/tfactory:*`    | `https://token.actions.githubusercontent.com`    | `^https://github\.com/olafkfreund/TFactory/`   |
| `ghcr.io/olafkfreund/cfactory*`     | (not signed yet)                                 | excluded — CFactory#191                        |

The subject is the GitHub Actions **workflow identity** (the release workflow
ref, e.g. `https://github.com/olafkfreund/AIFactory/.github/workflows/release.yml@refs/heads/main`);
the prefix regexp matches it across branches/tags exactly as the repos' own
self-test does.

## Reading the audit results

After merge and sync, check what would have been denied:

```bash
# Violations across the factory namespace
kubectl get clusterpolicyreport -o wide
kubectl get policyreport -n factory -o wide

# Detail for the signature policy
kubectl describe clusterpolicyreport | grep -A5 verify-factory-image-signatures
```

An all-`pass` report for aifactory/pfactory/tfactory Pods is the green light for
the next phase.

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

2. **Sign CFactory (CFactory#191).** Add the cosign keyless sign + verify steps
   to CFactory's release workflow, matching the other three. Then add a
   `verify-cfactory-signature` rule to the ClusterPolicy for
   `ghcr.io/olafkfreund/cfactory:*` and `cfactory-frontend:*` with subject
   `^https://github\.com/olafkfreund/CFactory/`, still in Audit. Confirm CFactory
   Pods report `pass`.

3. **Confirm clean.** Every factory Pod (all four services) must report `pass`
   in the ClusterPolicyReport, over at least one full release cycle of each.
   Any Pod still on an unsigned tag must be redeployed onto a signed image
   first.

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
