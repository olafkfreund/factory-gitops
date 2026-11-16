---
status: draft
issue: 1959
intent: intent/2026-11-16-1959-gateway-upstream-egress.md
---

# Spec: model-gateway upstream egress

## Design

In `apps/model-gateway/manifests/manifests.yaml` add a NetworkPolicy `allow-upstream-egress` in `gateway`, selecting `app: model-gateway`, `policyTypes: [Egress]`, one rule: TCP 443 to `0.0.0.0/0` except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`. Update the DNS-only comment to point at it.

## Alternatives rejected

- Plain `0.0.0.0/0:443`: also reaches the Kubernetes API and the LAN.
- Pinned provider IP ranges: none published, breaks silently.
- Egress proxy with host allowlist: a new component for one upstream.

## Risks

Gateway compromise can exfiltrate to any public HTTPS host (documented residual). The k3d CNI must honour `except`; the existing task policy already relies on the same shape, so the datapath is exercised.

## Verification

Repo CI manifest checks (kubeconform -strict on the rendered kustomization), then Argo Synced/Healthy and `kubectl get netpol -n gateway` list the policy: that proves presence, not packet filtering. Filtering is proven by the owner step: a chat call that reaches the upstream (200) plus a denied private destination from a gateway pod. `to` and `ports` stay in one egress rule (kube-router matches them together).
