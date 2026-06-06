# The Tailscale sidecar pattern

This is how a Pod in the k3d cluster becomes reachable on the
freundcloud tailnet under its own hostname (e.g. `aifactory.tail833f7.ts.net`).

## Mental model

Two containers in one Pod:

```
┌─ Pod (network namespace = single tailnet identity) ──────┐
│                                                          │
│   ┌──────────────┐         ┌──────────────────────────┐  │
│   │ your app     │ ←───── │ tailscale (sidecar)       │  │
│   │ port 8080    │ proxy   │ joins tailnet via         │  │
│   │ localhost    │         │ TS_AUTHKEY                │  │
│   └──────────────┘         │ registers TS_HOSTNAME     │  │
│                            │ serves :443 → 127.0.0.1:8080│  │
│                            └──────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
                       ▲
                       │ tailnet
                  https://aifactory.tail833f7.ts.net
```

Because the two containers share a network namespace, the sidecar's
`tailscale serve` proxy at `:443` reaches your app on `localhost:8080`
trivially. From a tailnet client's perspective there's a normal
`aifactory.tail833f7.ts.net` host serving HTTPS.

## Prerequisites

1. The Pod's namespace must contain a `tailscale-auth-key` Secret with
   key `TS_AUTHKEY`. The bootstrap unit on p510 seeds this into the
   namespaces listed in
   [`modules.containers.k3d.tailscaleAuthKey.targetNamespaces`](https://github.com/olafkfreund/nixos_config/blob/main/modules/containers/k3d.nix)
   — default `argocd` and `factory`.
2. To add a namespace: edit p510's host config to extend the list, deploy,
   `systemctl restart k3d-cluster-bootstrap`.

## Pod template

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aifactory
  namespace: factory
spec:
  replicas: 1
  selector: { matchLabels: { app: aifactory } }
  template:
    metadata: { labels: { app: aifactory } }
    spec:
      containers:
        # ── your app ────────────────────────────────────────────
        - name: app
          image: ghcr.io/olafkfreund/aifactory:0.1.0
          ports:
            - containerPort: 8080
        # ── tailscale sidecar ───────────────────────────────────
        - name: tailscale
          image: docker.io/tailscale/tailscale:v1.98.4
          env:
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: tailscale-auth-key
                  key: TS_AUTHKEY
            - name: TS_HOSTNAME
              value: "aifactory"      # → aifactory.tail833f7.ts.net
            - name: TS_USERSPACE
              value: "true"           # no NET_ADMIN cap required
            - name: TS_STATE_DIR
              value: "/tmp/tsstate"
            - name: TS_EXTRA_ARGS
              value: "--accept-dns=false"
            # OPTIONAL: serve the app's port on the tailnet identity at :443
            - name: TS_SERVE_CONFIG
              value: "/etc/tsconfig/serve.json"
          volumeMounts:
            - name: ts-serve-config
              mountPath: /etc/tsconfig
              readOnly: true
          securityContext:
            runAsUser: 1000
            runAsNonRoot: true
      volumes:
        - name: ts-serve-config
          configMap:
            name: aifactory-tailscale-serve-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: aifactory-tailscale-serve-config
  namespace: factory
data:
  serve.json: |
    {
      "TCP": { "443": { "HTTPS": true } },
      "Web": {
        "${TS_CERT_DOMAIN}:443": {
          "Handlers": { "/": { "Proxy": "http://127.0.0.1:8080" } }
        }
      },
      "AllowFunnel": {}
    }
```

The plain in-cluster Service (`kind: Service`) stays for in-cluster
addressability — tailnet clients don't go through it.

## Verifying

```bash
# Did the sidecar register?
kubectl -n factory logs deploy/aifactory -c tailscale | grep -iE 'register|success'

# Is the hostname resolvable from another tailnet device?
tailscale status | grep aifactory
nslookup aifactory.tail833f7.ts.net

# Smoke test
curl -sI https://aifactory.tail833f7.ts.net
```

Common pitfall: the sidecar starts but `TS_SERVE_CONFIG` references a
ConfigMap that doesn't exist → tailscaled joins the tailnet but nothing
answers on :443. Logs are clear; `kubectl -n factory get cm` will show
it. The ArgoCD bootstrap manifest in this repo has the equivalent
ConfigMap inlined alongside the patch.
