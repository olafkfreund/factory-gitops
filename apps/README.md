# apps/

One subdirectory per product / service. The root Application
(`bootstrap/argocd-root-app.yaml`) watches this directory recursively
and reconciles every `application.yaml` it finds.

## Adding a new service

```bash
mkdir apps/myservice
cat > apps/myservice/application.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myservice
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://github.com/olafkfreund/myservice
    targetRevision: main
    path: deploy/k8s              # path inside the product repo
  destination:
    server: https://kubernetes.default.svc
    namespace: factory            # cluster namespace to deploy into
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ CreateNamespace=true ]
EOF
git add apps/myservice && git commit -m "feat(apps): add myservice" && git push
```

For tailnet exposure of the Pod, see
[../docs/sidecar-pattern.md](../docs/sidecar-pattern.md).

## Current placeholders

- `aifactory/`, `pfactory/`, `tfactory/`, `cfactory/` — each points at its
  product repo. The product repos don't have `deploy/k8s/` directories
  yet, so the Applications will report `OutOfSync`/`ComparisonError`
  until those land. That's expected; it's a clear visual TODO list.
