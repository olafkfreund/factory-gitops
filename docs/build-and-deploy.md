# Build & Deploy — how a Factory service ships to the cluster

This is the end-to-end path a change takes from your editor to the running
`k3d-factory` cluster on **p510**. It applies to all four products
(**AIFactory, PFactory, TFactory, CFactory**). If you read one ops doc, read this one.

## The model in one sentence

> **You develop locally; the cluster runs released image tags only; an upgrade is a
> one-line tag bump in `factory-gitops` that ArgoCD reconciles.**

Nothing is `kubectl apply`'d by hand. The Git repo is the desired state; ArgoCD makes the
cluster match it. If it isn't in `factory-gitops`, it isn't real.

```
   your laptop                 ghcr.io                     factory-gitops                k3d-factory @ p510
 ┌────────────┐   build+push  ┌──────────────┐   tag bump  ┌────────────────┐   sync     ┌──────────────────┐
 │ edit source│ ───────────▶  │ <product>:tag │ ◀───PR────  │ kustomization  │ ◀───────── │ ArgoCD app-of-apps│
 │ run locally│               │  (immutable)  │            │  newTag: <tag>  │   ArgoCD   │ Deployments/Pods  │
 └────────────┘               └──────────────┘            └────────────────┘   pulls img └──────────────────┘
```

## Ground rules

- **Never deploy `latest`.** The cluster pins an explicit tag (`newTag`). `latest` is a
  lie waiting to happen — you can't tell what's running and rollbacks become archaeology.
- **Tags are immutable.** A new build = a new tag. Don't re-push an existing tag.
- **Local dev never touches the cluster.** Run from source on loopback with
  `APP_DISABLE_AUTH=true`. The cluster always runs real auth.
- **Secrets live in `factory-secrets`** (a k8s Secret in the `factory` namespace), seeded
  out-of-band — never in Git. Manifests reference keys via `secretKeyRef`.

## Step 1 — Build the image

Each product repo ships a `Dockerfile` that builds the backend **and** the frontend SPA into
one image. Build for `linux/amd64` (the cluster node arch) and tag with the **next** version.

```bash
cd <ProductRepo>

# AIFactory bundles the rmux "Live Agent Console" + the multi-provider CLIs,
# so it takes a build arg. The others are a plain build.
docker build --build-arg WITH_RMUX=true \
  -t ghcr.io/olafkfreund/aifactory:v3.4.4-rmux-ssofix .

# PFactory / TFactory / CFactory:
docker build -t ghcr.io/olafkfreund/pfactory:0.6.2 .
```

**Tag conventions**

| Product   | Example tag             | Notes                                            |
|-----------|-------------------------|--------------------------------------------------|
| aifactory | `v3.4.4-rmux-ssofix`    | `-rmux` = rmux + CLIs bundled (`WITH_RMUX=true`) |
| pfactory  | `0.6.2`                 | plain semver                                     |
| tfactory  | `0.5.2`                 | plain semver                                     |
| cfactory  | `0.x.y`                 | plain semver                                     |

A human-readable suffix (`-ssofix`, `-authme`) on top of the version is encouraged — future
you, staring at `kubectl get pods`, will be grateful.

!!! tip "Sanity-check the image before you trust it"
    ```bash
    docker run --rm --entrypoint sh ghcr.io/olafkfreund/aifactory:<tag> -c \
      'command -v rmux && grep -rl "Resolve the token" /app 2>/dev/null | head'
    ```
    Confirm the thing you *think* you built is actually inside the layer.

## Step 2 — Push to GHCR

```bash
docker push ghcr.io/olafkfreund/aifactory:v3.4.4-rmux-ssofix
```

Images are **private**; the cluster pulls them via the `ghcr-pull` dockerconfigjson Secret
already present in the `factory` namespace (referenced by each Deployment's
`imagePullSecrets`). If you rebuild the cluster, that Secret must be recreated or every pod
sticks in `ImagePullBackOff`.

## Step 3 — Bump the tag in `factory-gitops`

Each app's image tag is managed by kustomize in
`apps/<product>/manifests/kustomization.yaml`:

```yaml
images:
  - name: ghcr.io/olafkfreund/aifactory
    newTag: v3.4.4-rmux-ssofix   # <- the only line you change to deploy
```

Bump it on a branch and open a PR:

```bash
cd factory-gitops
git checkout -b deploy/aifactory-v3.4.4
# edit apps/aifactory/manifests/kustomization.yaml  (or: kustomize edit set image ...)
git commit -am "deploy(aifactory): v3.4.4-rmux-ssofix"
git push -u origin deploy/aifactory-v3.4.4
gh pr create --fill && gh pr merge --squash
```

Why a PR and not a direct push? Because the tag bump **is** the deploy record. The merged PR
is your changelog, your audit trail, and your rollback handle.

## Step 4 — ArgoCD reconciles

ArgoCD runs an **app-of-apps**: a root Application sweeps `apps/**/application.yaml`, each of
which points at `apps/<product>/manifests` (kustomize). On merge, ArgoCD notices the new tag
and rolls the Deployment (`strategy: Recreate`). It self-heals — if you hand-edit a live
resource, ArgoCD will lovingly stomp your change back to what Git says.

To nudge a sync instead of waiting for the poll interval:

```bash
ssh p510 'KUBECONFIG=/etc/k3d/kubeconfig \
  kubectl -n argocd annotate application aifactory argocd.argoproj.io/refresh=hard --overwrite'
```

Watch it land:

```bash
ssh p510 'KUBECONFIG=/etc/k3d/kubeconfig kubectl -n factory get pods -w'
```

Done when the pod is `1/1 Running` on the new image:

```bash
ssh p510 'KUBECONFIG=/etc/k3d/kubeconfig \
  kubectl -n factory get deploy aifactory \
  -o jsonpath="{.spec.template.spec.containers[0].image}{\"\n\"}"'
```

## Rollback

Revert the tag-bump PR (or set `newTag` back to the previous value) and merge. ArgoCD rolls
back. Because tags are immutable, the old image is still in GHCR — rollback is deterministic,
not "hope the cache still has it".

## Cluster access & exposure

- **kubectl** runs on **p510** only: `ssh p510`, `KUBECONFIG=/etc/k3d/kubeconfig`.
- Services are **ClusterIP**; public URLs (`<product>.freundcloud.org.uk`) are provided by the
  **in-cluster Cloudflare tunnel** (`infra/cloudflared/`) which maps each hostname to a
  service. Adding a new public host = add an ingress rule there + a `cloudflared tunnel route
  dns` CNAME.

## CI/CD (the automated version of the above)

The manual loop is the source of truth, but each product repo also has a
`.github/workflows/deploy.yml` that, on push to its default branch, builds + pushes the image
and opens a tag-bump PR against `factory-gitops` — automating Steps 1–3. It needs a
`GITOPS_PAT` repo secret (write access to `factory-gitops`). Until that's enabled everywhere,
the manual path above is always valid and is exactly what CI does under the hood.

## When it goes wrong — quick triage

| Symptom                          | Likely cause                                   | Look at                                   |
|----------------------------------|------------------------------------------------|-------------------------------------------|
| `ImagePullBackOff`               | `ghcr-pull` secret missing / tag never pushed  | `kubectl -n factory describe pod <p>`     |
| ArgoCD `OutOfSync` / `ComparisonError` | manifest path/typo, missing referenced Secret | ArgoCD UI → the app → diff                 |
| Pod `CrashLoopBackOff` on boot   | missing env/secret key, bad DB path            | `kubectl -n factory logs <p> --previous`  |
| New tag merged but old pod runs  | ArgoCD hasn't synced yet                        | hard-refresh annotation (Step 4)          |
| New pod runs but browser shows old UI / a "fixed" bug persists | browser cached the SPA shell (`index.html`) | apps now send `Cache-Control: no-cache` on HTML; for an already-cached client, hard-refresh once (Ctrl/Cmd+Shift+R) |
| 404 on the public URL            | cloudflared ingress rule / CNAME missing       | `infra/cloudflared/` + tunnel DNS         |
