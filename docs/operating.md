# Operating Guide

Day-2 operations for the factory-gitops + k3d cluster pair.

## Adding a new service

1. In the service's product repo, add `deploy/k8s/` with at least a Deployment + Service. Include a Tailscale sidecar if it needs tailnet exposure — see [sidecar-pattern.md](sidecar-pattern.md).
2. In this repo:

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
       path: deploy/k8s
     destination:
       server: https://kubernetes.default.svc
       namespace: factory
     syncPolicy:
       automated: { prune: true, selfHeal: true }
       syncOptions: [ CreateNamespace=true ]
   EOF
   git add apps/myservice && git commit -m "feat(apps): add myservice" && git push
   ```

3. Wait ~3 minutes. ArgoCD's root Application picks up the new file and creates the child Application; the child Application then reconciles your manifests.

## Triggering a sync manually

```bash
# Via the argocd CLI (auth via the tailnet hostname)
argocd login argocd.tail833f7.ts.net
argocd app sync root        # cascades into every child Application

# Via kubectl (when argocd CLI isn't available)
kubectl -n argocd patch application root --type merge \
  -p '{"operation":{"sync":{}}}'
```

## Auth-key rotation

Tailscale auth keys expire (90 day cap, less if you picked a shorter
TTL). When yours is close to expiry:

1. Generate a new key in the admin console (same flavour: reusable, non-ephemeral, 90 days, description like `k3d-factory sidecar pool YYYY-MM`).
2. On the machine that holds your agenix recipients:

   ```bash
   cd ~/.config/nixos
   ./scripts/manage-secrets.sh edit tailscale-k8s-operator-oauth
   # paste the new tskey-auth-… token, single line, no quotes
   ```

3. Deploy p510:

   ```bash
   just quick-deploy p510
   ```

4. Refresh the in-cluster Secrets and bounce every sidecar-running Pod:

   ```bash
   ssh p510 'sudo systemctl restart k3d-cluster-bootstrap'
   ssh p510 'KUBECONFIG=/etc/k3d/kubeconfig kubectl -n argocd rollout restart deploy/argocd-server'
   ssh p510 'KUBECONFIG=/etc/k3d/kubeconfig kubectl -n factory rollout restart deploy --all'
   ```

5. Once new sidecars register and hostnames resolve again, revoke the old auth key in the Tailscale admin console.

## Full cluster reset (destructive)

Wipes the cluster and all in-cluster PVC data. ArgoCD will re-sync
manifests from Git, but PVC-backed state is gone.

```bash
ssh p510
sudo systemctl stop k3d-cluster-bootstrap
sudo $(which k3d) cluster delete factory
sudo rm -rf /mnt/img_pool/k3d/storage/* /etc/k3d/kubeconfig
sudo systemctl start k3d-cluster-bootstrap
sudo journalctl -u k3d-cluster-bootstrap -f
```

## Bump ArgoCD upstream

In `bootstrap/argocd-install.yaml`, update the URL ref:

```yaml
resources:
  - https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.1/manifests/install.yaml
                                                  # ^^^^^^^ change here
```

Commit + push. The change won't take effect until you manually re-apply
the bootstrap kustomization on p510 (`systemctl restart k3d-cluster-bootstrap`)
— ArgoCD doesn't self-manage its own install manifests by design.

## Bump the Tailscale sidecar image

Two places to bump in lockstep:

1. `bootstrap/argocd-sidecar-patch.yaml` (the argocd-server sidecar)
2. Each product repo's Deployment that runs a sidecar

Image: `ghcr.io/tailscale/tailscale:<version>` — see
[Tailscale releases](https://github.com/tailscale/tailscale/releases).

## Cluster won't come back after p510 reboot

```bash
ssh p510
sudo systemctl status docker                # Docker up?
sudo docker ps --filter "name=k3d-factory"  # k3d containers running?
sudo systemctl status k3d-cluster-bootstrap # bootstrap unit OK?
sudo journalctl -u k3d-cluster-bootstrap -b # full log
```

If `k3d-cluster-bootstrap` is failing, restart it:

```bash
sudo systemctl restart k3d-cluster-bootstrap
```

If Docker itself didn't start, that's a separate problem — fix Docker
first, the cluster will come back.
