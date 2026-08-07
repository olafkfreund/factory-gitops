#!/usr/bin/env bash
#
# PANIC.sh -- back out the image-signature admission gate, fast.
#
# WHAT THIS IS FOR
# `verify-factory-image-signatures` rides on the Kyverno webhook
# `mutate.kyverno.svc-ignore` in `kyverno-resource-mutating-webhook-cfg`, which
# intercepts pods, deployments, replicasets, statefulsets, daemonsets, jobs and
# cronjobs in EVERY namespace except kube-system and kyverno. At
# `validationFailureAction: Enforce`, a rule that denies wrongly -- or an image
# whose signature genuinely cannot be read -- stops workload creation across the
# cluster. This script is the way back.
#
#   ./PANIC.sh status     what mode is the gate in, and is anything denying
#   ./PANIC.sh 1          gate -> Audit, and stop ArgoCD putting Enforce back
#   ./PANIC.sh 2          defang the webhook itself (see the caveat below)
#   ./PANIC.sh 3          delete the ClusterPolicy outright
#   ./PANIC.sh restore    undo level 2 and re-enable ArgoCD auto-sync
#
# LEVEL 1 IS THE ONE YOU WANT almost every time. Kyverno stays healthy, every
# other policy keeps working, and the gate degrades to exactly the reporting
# behaviour it had before the flip.
#
# ORDER MATTERS AND IS NOT OBVIOUS. `kyverno-policies` syncs with
# `automated: {prune: true, selfHeal: true}`, so patching the live ClusterPolicy
# to Audit while auto-sync is on is undone by ArgoCD within its reconcile
# window. Level 1 therefore disables automated sync FIRST and patches SECOND.
# Doing it the other way round looks like it worked and then silently reverts.
#
# CAVEAT ON LEVEL 2, MEASURED NOT ASSUMED (Factory#522).
# A HEALTHY Kyverno reconciles its own webhook configurations and will restore
# the namespaceSelector this level overwrites. Level 2 is therefore NOT a
# durable off-switch while Kyverno is running -- use level 1 or 3 for that. It
# is here for the case levels 1 and 3 cannot reach: the API server rejecting
# writes because the webhook itself is wedged. Being able to edit a
# MutatingWebhookConfiguration does not depend on Kyverno answering.
#
# Note the difference from Factory#620's netpol gate, and do not carry that
# issue's reasoning over here. This webhook is `failurePolicy: Ignore`, so
# "Kyverno is down" does NOT block anything -- requests are admitted. The
# hazard this script exists for is the opposite one: Kyverno UP and answering,
# denying things it should not.
#
# NOT AN INSTRUMENT: `kubectl scale deploy/kyverno-admission-controller
# --replicas=0`. Kyverno DEREGISTERS its webhooks on a graceful shutdown, so
# scaling to zero removes the very thing you are trying to observe and every
# request is then admitted for a reason unrelated to your change. Factory#620
# found this the hard way; two of its three outage instruments were false
# negatives.
set -uo pipefail

CTX=factory
POLICY=verify-factory-image-signatures
WEBHOOK_CFG=kyverno-resource-mutating-webhook-cfg
WEBHOOK=mutate.kyverno.svc-ignore
APP=kyverno-policies
BACKUP="${TMPDIR:-/tmp}/panic-${WEBHOOK_CFG}.json"

k() { kubectl --context "$CTX" "$@"; }

# The index is looked up by name rather than hardcoded to 0. The netpol gate
# (Factory#620) adds a SECOND webhook to this same configuration with
# `failurePolicy: Fail`, and its position is not guaranteed. Patching the wrong
# index would disable the netpol gate and leave the signature gate armed --
# precisely backwards.
webhook_index() {
  k get mutatingwebhookconfiguration "$WEBHOOK_CFG" \
    -o json | jq -r --arg n "$WEBHOOK" '.webhooks | to_entries[] | select(.value.name==$n) | .key'
}

case "${1:-status}" in
  status)
    echo "== gate"
    k get clusterpolicy "$POLICY" \
      -o jsonpath='{.metadata.name}{"  action="}{.spec.validationFailureAction}{"  failurePolicy="}{.spec.failurePolicy}{"  rules="}{range .spec.rules[*]}{.name}{" "}{end}{"\n"}' 2>&1
    echo "== argocd"
    k -n argocd get application "$APP" -o jsonpath='{"automated="}{.spec.syncPolicy.automated}{"  sync="}{.status.sync.status}{"  health="}{.status.health.status}{"\n"}'
    echo "== webhook (index is looked up, not assumed)"
    echo "  $WEBHOOK is at index $(webhook_index)"
    k get mutatingwebhookconfiguration "$WEBHOOK_CFG" \
      -o jsonpath="{range .webhooks[*]}{'  '}{.name}{'  fail='}{.failurePolicy}{'  nsSelector='}{.namespaceSelector}{'\n'}{end}"
    echo "== failing results right now"
    k get policyreport -A -o json \
      | jq -r --arg p "$POLICY" '[.items[] | . as $r | .results[] | select(.policy==$p and .result=="fail")
          | "  \($r.scope.kind)/\($r.scope.name): \(.message)"] | if length==0 then "  none" else .[] end'
    ;;

  1)
    echo "level 1: auto-sync OFF first, then gate -> Audit"
    k -n argocd patch application "$APP" --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
    k patch clusterpolicy "$POLICY" --type=merge -p '{"spec":{"validationFailureAction":"Audit"}}'
    k get clusterpolicy "$POLICY" -o jsonpath='{"now action="}{.spec.validationFailureAction}{"\n"}'
    echo "REMEMBER: ./PANIC.sh restore re-enables auto-sync once the fix is in git."
    ;;

  2)
    idx=$(webhook_index)
    if [ -z "$idx" ]; then echo "FATAL: webhook $WEBHOOK not found in $WEBHOOK_CFG"; exit 1; fi
    k get mutatingwebhookconfiguration "$WEBHOOK_CFG" -o json > "$BACKUP"
    echo "level 2: backup -> $BACKUP; defanging webhook index $idx"
    # A namespaceSelector that cannot match ANY namespace. `DoesNotExist` on
    # kubernetes.io/metadata.name is used rather than `In: [<sentinel>]`
    # because kube-apiserver label-value validation rejects a sentinel with a
    # leading underscore, and every namespace carries that key automatically --
    # so "does not have it" is empty by construction and needs no value at all.
    # Chosen over deleting the webhook because it is one reversible field and
    # leaves the rest of the object, including the sibling netpol-gate webhook,
    # untouched.
    k patch mutatingwebhookconfiguration "$WEBHOOK_CFG" --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/webhooks/${idx}/namespaceSelector\",\"value\":{\"matchExpressions\":[{\"key\":\"kubernetes.io/metadata.name\",\"operator\":\"DoesNotExist\"}]}}]" || true

    # ASSERT THE PATCH TOOK EFFECT. An earlier version of this script printed
    # "defanged" after a patch the API server had rejected outright -- an
    # escape hatch that lies about having fired is worse than none, because it
    # is read as "level 2 did not help, escalate" when level 2 never ran.
    # Factory#620 lost two of its three outage instruments to exactly this.
    got=$(k get mutatingwebhookconfiguration "$WEBHOOK_CFG" \
            -o jsonpath="{.webhooks[${idx}].namespaceSelector.matchExpressions[0].operator}")
    if [ "$got" = "DoesNotExist" ]; then
      echo "DEFANGED (asserted: selector operator is now DoesNotExist)"
      echo "A healthy Kyverno WILL undo this -- see the caveat at the top."
    else
      echo "LEVEL 2 DID NOT TAKE EFFECT (selector operator is '${got:-<empty>}'). Go to level 3."
      exit 1
    fi
    ;;

  3)
    echo "level 3: auto-sync OFF, then delete the ClusterPolicy"
    k -n argocd patch application "$APP" --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
    k delete clusterpolicy "$POLICY"
    ;;

  restore)
    if [ -f "$BACKUP" ]; then
      echo "restoring $WEBHOOK_CFG from $BACKUP"
      # resourceVersion is stripped: the stored copy is stale the moment
      # anything else writes the object -- including Kyverno's own reconcile --
      # and `replace` with a stale resourceVersion fails the conflict check.
      jq 'del(.metadata.resourceVersion)' "$BACKUP" | k replace -f - && rm -f "$BACKUP"
    else
      echo "no webhook backup at $BACKUP (nothing to restore, or level 2 never ran)"
    fi
    k -n argocd patch application "$APP" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
    k -n argocd get application "$APP" -o jsonpath='{"automated="}{.spec.syncPolicy.automated}{"\n"}'
    ;;

  *) sed -n '2,40p' "$0"; exit 2 ;;
esac
