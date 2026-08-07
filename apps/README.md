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

## Where the four control-plane services actually come from

`aifactory/`, `pfactory/`, `tfactory/` and `cfactory/` are served from
`apps/<svc>/manifests/` **in this repo**, not from the product repos —
`kubectl -n argocd get applications -o custom-columns=PATH:.spec.source.path`
is the check. The `charts/<svc>/` Helm chart in each product repo is the
*self-hoster* install path; it does not deploy this cluster. Two engines, two
jobs, and `Factory/scripts/check_chart_vs_gitops.py` compares the controls they
both declare so they cannot drift silently (Factory#504).

(This section previously claimed the four Applications pointed at
`deploy/k8s/` in the product repos and were expected to be `OutOfSync`. That
has not been true for a long time; all four are `Synced` off this repo.)

## Two cluster-wide control decisions

**No PodDisruptionBudget, anywhere — deliberate (Factory#550).** The charts
enable one with `minAvailable: 1`. Every Deployment here runs a single replica
at rest (KEDA `minReplicaCount: 1` for aifactory/pfactory/tfactory, literal
`replicas: 1` for the rest), and this cluster has two nodes. `minAvailable: 1`
over one replica means zero allowed disruptions, so a node drain never
completes. Measured, not assumed:

```
$ kubectl -n factory get pdb pdb-550-experiment
NAME                 MIN AVAILABLE   ALLOWED DISRUPTIONS
pdb-550-experiment   1               0

$ kubectl drain k3d-factory-server-0 --dry-run=server --ignore-daemonsets ...
error when evicting pods/"tfactory-777c54d78b-mdrv2": Cannot evict pod as it
would violate the pod's disruption budget.
```

With no PDB the same command returns `node/k3d-factory-server-0 drained`. There
is no PDB shape that both protects and drains at one replica: `minAvailable:
50%` rounds up to 1, and `maxUnavailable: 1` permits every eviction and so
protects nothing. Revisit when a service holds `replicas >= 2` at rest.

**`automountServiceAccountToken` is stated on every control-plane pod, both
ways (Factory#550, Factory#42, Factory#570).** `false` for pfactory, cfactory
and cfactory-frontend, which have no in-cluster API caller; `true` for
aifactory and tfactory, which create Jobs via `load_incluster_config()`. The
field is written out even where it matches the default, because an unset field
records no decision — it cannot distinguish "checked, needs no token" from
"nobody looked". Each manifest carries the evidence for its own value.
