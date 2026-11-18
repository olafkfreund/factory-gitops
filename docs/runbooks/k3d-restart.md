# Restarting the k3d-factory nodes

Use this when a node container (`k3d-factory-server-0`, `k3d-factory-agent-0`)
has to be restarted, or when `netpol-node-probe` reports a node as unenforced.
Background: Factory#3770 and #3782. Run it on the host that runs the cluster
(p620 at the time of writing). Add `sudo` to `docker` if your user needs it.

## Why this needs care

Docker hands out bridge addresses in start order, so after a restart the two
nodes can swap IPs (.2/.3). kube-router reads its own node IP once at start and
matches local pods by `status.hostIP`. If it started with the old address it
writes pod firewall rules for the other node's pods, and task pods on the
affected node run with no NetworkPolicy. The `netpol-gate` init container fails
closed, so tasks do not run unconfined, but they also do not run. Also,
`docker restart` regenerates `/etc/hosts` without the k3d entries, so the agent
cannot resolve `k3d-factory-server-0` and goes NotReady.

## Before

- No release workflow or dev to main PR merge in flight, and no task Jobs
  running: `kubectl get jobs -n factory`.
- Post on the agent bus before disrupting a shared host.

## Restart, server first

```bash
# 1. Server first, wait until it is Ready.
docker restart k3d-factory-server-0
kubectl wait --for=condition=Ready node/k3d-factory-server-0 --timeout=300s

# 2. Then the agent.
docker restart k3d-factory-agent-0
```

If you stop and start the whole cluster instead, use
`K3D_FIX_DNS=0 k3d cluster start factory` (k3d 5.9 otherwise fails on the
resolv.conf mount).

## Re-add the hosts entries `docker restart` drops

Build the entries from the live IPs (they may have swapped), then append them
to `/etc/hosts` in both node containers (bash; `-i` is required to pass stdin). Skip a name that is already present.

```bash
ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
GW=$(docker network inspect k3d-factory -f '{{(index .IPAM.Config 0).Gateway}}')
ENTRIES="$GW host.k3d.internal
$(ip k3d-factory-server-0) k3d-factory-server-0
$(ip k3d-factory-agent-0) k3d-factory-agent-0
$(ip k3d-factory-serverlb) k3d-factory-serverlb"
for n in k3d-factory-server-0 k3d-factory-agent-0; do
  docker exec -i "$n" sh -c 'while read -r ip name; do grep -q " $name\$" /etc/hosts || echo "$ip $name" >> /etc/hosts; done' <<<"$ENTRIES"
done
kubectl get nodes   # both Ready
```

## Prove enforcement

Each node must hold firewall rules for ITS OWN pods and none for the other
node's. This prints, per node, how many rules reference its own pod subnet and
how many reference the other node's (own should be above zero, other zero):

```bash
for n in server-0 agent-0; do
  mine=$(kubectl get node k3d-factory-$n -o jsonpath='{.spec.podCIDR}' | cut -d. -f1-3)
  for o in server-0 agent-0; do
    c=$(docker exec k3d-factory-$n iptables -S KUBE-ROUTER-INPUT \
        | grep -c -- "-s $(kubectl get node k3d-factory-$o -o jsonpath='{.spec.podCIDR}' | cut -d. -f1-3)\.")
    echo "iptables on $n: $c rules for $o pods"
  done
done
```

Assumes each node has a /24 pod CIDR (k3s default). If a node shows rules only
for the other node's pods, kube-router holds a stale IP: restart that node
again (`docker restart`, then re-add the hosts entries, then re-check).

Then confirm the probe: the server CronJob should pass on its next run (or trigger
one: `kubectl create job -n factory --from=cronjob/netpol-node-probe-server probe-now`).
agent-0 has no probe (see below): rely on the rule-count check above for it.

```bash
kubectl get cronjob,job -n factory | grep netpol-node-probe
kubectl get applications -n argocd   # all Synced/Healthy
```

## The probe (`apps/netpol-node-probe`)

One CronJob (`netpol-node-probe-server`), every 10 minutes, pinned to its node by
`kubernetes.io/hostname`. The `-agent` CronJob was retired (Factory#3832):
k3d-factory-agent-0 carries the taint `rfactory.io/desktops=true:NoSchedule`
(RFactory#3), Kyverno `rfactory-desktops-toleration` allows that toleration only
on desktop launcher pods, so the probe pod could never schedule (Pending, then
`DeadlineExceeded`) and agent-0 hosts no task pods. That was a probe that could
not run, not a loss of enforcement. If the taint is removed, restore the CronJob
with `git log -p -- apps/netpol-node-probe/manifests/manifests.yaml`
(the commit that retired it, Factory#3832) and re-add it with `nodeSelector`
`k3d-factory-agent-0`. A failing Job is turned into a
GitHub issue by `apps/job-watchdog` after two consecutive failures (about 50
minutes). Triage a failure:

| Symptom | Meaning |
|---|---|
| Job log says "NO NetworkPolicy is in force" | stale kube-router IP: run the restart section for that node |
| `netpol-gate` init container failed | same check, same cause |
| Pod Pending until the deadline | node NotReady, or a node was renamed: update the names in `apps/netpol-node-probe` |
| No pod at all, Job failed | Kyverno admission is down (webhook fails closed): check Kyverno first |
| "UNKNOWN, neither reachable" | egress rule 4 of `factory-sandbox-jobs-egress` no longer matches the API server address: `kubectl get endpoints kubernetes -n default` |

The probe checks egress for fresh task pods only; it does not prove ingress
default-deny. The rule-count check above is the broader proof.
