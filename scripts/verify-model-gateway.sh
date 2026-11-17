#!/usr/bin/env bash
# Prove the model gateway contract (Factory#1959): healthz 200, chat without a token 401,
# chat with the client token 200. Read-only for the cluster; the 200 spends one upstream token.
#   GATEWAY_PROBE_MODEL=<model the upstream serves> verify-model-gateway.sh <base-url> <token-file>
# <base-url> is e.g. http://127.0.0.1:8080 through `kubectl -n gateway port-forward svc/model-gateway 8080`.
# The token is read from the file, handed to curl on stdin, and never printed or put in argv.
set +x
set -u

[ "$#" -eq 2 ] || { echo "usage: GATEWAY_PROBE_MODEL=<model> $0 <base-url> <token-file>" >&2; exit 2; }
base=${1%/}
tokfile=$2
model=${GATEWAY_PROBE_MODEL:-}
[[ $model =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo "GATEWAY_PROBE_MODEL is required and may only contain A-Za-z0-9._:/-" >&2; exit 2; }
token=""
IFS= read -r token < "$tokfile" 2>/dev/null || [ -n "$token" ] || { echo "cannot read a token from $tokfile" >&2; exit 2; }
[[ -n $token && $token =~ ^[[:print:]]+$ && $token != *[\"\\]* ]] \
  || { echo "token file must hold one printable line without quotes or backslashes" >&2; exit 2; }

body=$(printf '{"model":"%s","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' "$model")
# -q first: ignore any ~/.curlrc (a verbose or trace option there would print the header).
curl_() { curl -q -sS -o /dev/null --connect-timeout 5 --max-time 130 -w '%{http_code}' "$@" 2>/dev/null || true; }

fail=0
check() { # name expected got
  local note=""
  [ "$3" = "000" ] && note=" (transport failure)"
  if [ "$3" = "$2" ]; then echo "ok   $1: $3"; else echo "FAIL $1: expected $2, got $3$note"; fail=1; fi
}

check "healthz" 200 "$(curl_ "$base/healthz")"
check "chat without token" 401 "$(curl_ -X POST -H 'Content-Type: application/json' -d "$body" "$base/v1/chat/completions")"
got=$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
  | curl_ -K - -X POST -H 'Content-Type: application/json' -d "$body" "$base/v1/chat/completions")
check "chat with token" 200 "$got"
exit "$fail"
