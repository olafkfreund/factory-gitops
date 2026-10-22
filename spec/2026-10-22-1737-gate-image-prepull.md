---
status: draft
issue: AIFactory#1737
intent: intent/2026-10-22-1737-gate-image-prepull.md
---

# Spec: gate-image-prepull DaemonSet

## Design

Chosen by the user (option 1 of AIFactory#1737): a DaemonSet
`gate-image-prepull` in `apps/aifactory/manifests/manifests.yaml`,
namespace `factory`.

- One initContainer per image, `command: ["sh","-c","true"]` (both images
  carry `sh`: AIFactory's kube_sandbox and build_backend already run
  `sh -c` in them). Running the initContainer forces the pull; the pod staying
  alive keeps the image referenced so kubelet image GC does not remove it.
- Main container `rancher/mirrored-pause:3.6` pinned by digest
  (`sha256:74c4244...`), the sandbox image k3s already caches on the node
  (checked with `kubectl get nodes -o json`).
- Image refs come from the Deployment env values through kustomize
  `replacements` in `kustomization.yaml`, not by copying the strings. This is
  required, not style: the kustomization's `images:` transformer rewrites
  every `ghcr.io/olafkfreund/aifactory` image field to `newTag`, so a literal
  `aifactory:sha-6231576-nix` in the DaemonSet would render as
  `aifactory:sha-6231576` (measured with kustomize 5.8.1). `replacements`
  run after `images`, and the env value is not an image field, so the
  rendered DaemonSet carries exactly the env strings. Drift is impossible, so
  no separate sync check is needed; a renamed env var makes `kustomize build`
  fail in CI.
- Security context as in the file: pod `runAsNonRoot`, numeric
  `runAsUser: 65532`, `seccompProfile: RuntimeDefault`; each container
  `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, drop ALL.
  `automountServiceAccountToken: false`, `enableServiceLinks: false`,
  `imagePullSecrets: ghcr-pull`. Requests 1m/4Mi, limits 10m/16Mi.
- A comment next to both env values says the DaemonSet follows them.

## Alternatives rejected

- Raise `AIFACTORY_GATE_TIMEOUT_SECONDS`: lengthens every real hang; the user
  chose the pre-pull.
- One-off `crictl pull`: not declarative, lost on GC or a new node.
- Literal image strings plus a CI equality check: broken by the `images:`
  transformer (above) and adds a second place to edit.
- Gate output naming the pending phase (option 3): diagnostic only, separate
  AIFactory change.

## Risks

- ~2.25 GB+ pulled per node once per pin bump; disk use the Jobs already need.
- If ArgoCD's kustomize ordered `replacements` before `images`, the build
  image would render with the Deployment's tag; ArgoCD bundles kustomize 5.x,
  same ordering as CI.

## Verification

- `kustomize build apps/aifactory/manifests` shows the DaemonSet images equal
  to the env values; CI manifest-validate (build, kubeconform, immutability)
  green.
- After sync: `kubectl -n factory get ds gate-image-prepull` ready 1/1, and
  `kubectl get nodes -o json` lists both image refs.
