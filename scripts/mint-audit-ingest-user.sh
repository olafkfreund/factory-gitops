#!/usr/bin/env bash
# Owner-run (AIFactory#2079): create the OpenObserve user AIFactory pushes auth.failure rows with
# and the Secret observe-audit-ingest the aifactory Deployment reads, then restart it.
# Order: user (delete + create), then Secret, then restart. If a step fails, rerun: it converges.
# Secrets travel via a private temp dir and stdin, never argv or output. DRY_RUN=1 prints steps only.
set -euo pipefail
NS=${NS:-factory} ORG=${ORG:-default} USER_EMAIL=${USER_EMAIL:-aifactory-audit-ingest@factory.local}
if [ "${DRY_RUN:-}" = 1 ]; then
  echo "+ port-forward svc/observe; DELETE then POST /api/$ORG/users for $USER_EMAIL (root login from observe-root)"
  echo "+ kubectl -n $NS apply Secret observe-audit-ingest (user=$USER_EMAIL, password=<generated>)"
  echo "+ kubectl -n $NS rollout restart deploy/aifactory && rollout status"; exit 0
fi
umask 077; D=$(mktemp -d); PF=
trap 'rm -rf "$D"; [ -n "$PF" ] && kill "$PF" 2>/dev/null || true' EXIT
openssl rand -hex 24 | tr -d '\n' > "$D/password"
printf '%s' "$USER_EMAIL" > "$D/user"
esc() { sed 's/[\\"]/\\&/g'; }  # curl config quoting
{ printf 'user = "'
  { kubectl -n "$NS" get secret observe-root -o jsonpath='{.data.email}' | base64 -d; printf ':'
    kubectl -n "$NS" get secret observe-root -o jsonpath='{.data.password}' | base64 -d; } | esc | tr -d '\n'
  printf '"\n'; } > "$D/root.cfg"
# A free local port, and proof the forward is ours before any login is sent.
LP=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
kubectl -n "$NS" port-forward svc/observe "$LP:5080" >"$D/pf.log" 2>&1 & PF=$!
for _ in $(seq 20); do grep -q "Forwarding from 127.0.0.1:$LP" "$D/pf.log" && break; sleep 0.5; done
if ! { grep -q "Forwarding from 127.0.0.1:$LP" "$D/pf.log" && kill -0 "$PF"; }; then echo "port-forward failed" >&2; exit 1; fi
OO=http://127.0.0.1:$LP/api/$ORG/users
oo() { curl -sS -K "$D/root.cfg" -o /dev/null -w '%{http_code}' "$@"; }
code=$(oo -X DELETE "$OO/$USER_EMAIL" || true)
case "$code" in 2*|404) ;; *) echo "delete user failed: HTTP $code" >&2; exit 1;; esac
printf '{"email":"%s","password":"%s","first_name":"aifactory","last_name":"audit-ingest","role":"user"}' \
  "$USER_EMAIL" "$(cat "$D/password")" > "$D/body.json"
code=$(oo -X POST -H 'Content-Type: application/json' -d @"$D/body.json" "$OO")
case "$code" in 2*) ;; *) echo "create user failed: HTTP $code" >&2; exit 1;; esac
kubectl -n "$NS" create secret generic observe-audit-ingest --from-file=user="$D/user" \
  --from-file=password="$D/password" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" rollout restart deploy/aifactory
kubectl -n "$NS" rollout status deploy/aifactory --timeout=300s
echo "done: user $USER_EMAIL, Secret observe-audit-ingest, aifactory restarted"
