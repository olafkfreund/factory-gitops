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
