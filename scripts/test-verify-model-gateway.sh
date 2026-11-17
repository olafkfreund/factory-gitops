#!/usr/bin/env bash
# Self-test for verify-model-gateway.sh against a local stub; throwaway values only.
set -u
here=$(cd "$(dirname "$0")" && pwd)
v="$here/verify-model-gateway.sh"
work=$(mktemp -d); trap 'kill "${pid:-0}" 2>/dev/null; rm -rf "$work"' EXIT
TOKEN=throwaway-token-0123456789abcdef
printf '%s' "$TOKEN" > "$work/tok"

cat > "$work/stub.py" <<'PY'
import http.server, sys
good, mode = sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def _r(self, c):
        self.send_response(c); self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self):
        self._r(200 if self.path == "/healthz" else 404)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        ok = mode == "good" and self.headers.get("Authorization") == "Bearer " + good
        self._r(200 if ok else 401)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
PY

start() { # mode
  rm -f "$work/port"; python3 "$work/stub.py" "$work/port" "$TOKEN" "$1" & pid=$!
  for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
  port=$(cat "$work/port")
}
stop() { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
fails=0
expect() { # name want-exit
  if [ "$rc" -eq "$2" ]; then echo "pass $1"; else echo "FAIL $1 (exit $rc, want $2)"; fails=$((fails + 1)); fi
}
export GATEWAY_PROBE_MODEL=probe-model:1b

start good
out=$(bash "$v" "http://127.0.0.1:$port" "$work/tok" 2>&1); rc=$?; expect "all checks match" 0
case $out in *"$TOKEN"*) echo "FAIL token printed"; fails=$((fails + 1));; esac
mkdir "$work/home"; printf 'verbose\ntrace-ascii = "%s/trace"\n' "$work" > "$work/home/.curlrc"
out=$(HOME="$work/home" bash "$v" "http://127.0.0.1:$port" "$work/tok" 2>&1); rc=$?; expect "curlrc is ignored" 0
case $out in *"$TOKEN"*) echo "FAIL token leaked via curlrc output"; fails=$((fails + 1));; esac
if [ ! -e "$work/trace" ]; then echo "pass no curlrc trace file"; else echo "FAIL curlrc was honoured"; fails=$((fails + 1)); fi
printf 'bad"token' > "$work/q"; out=$(bash "$v" "http://127.0.0.1:$port" "$work/q" 2>&1); rc=$?; expect "quote in token refused" 2
out=$(GATEWAY_PROBE_MODEL='a b' bash "$v" "http://127.0.0.1:$port" "$work/tok" 2>&1); rc=$?; expect "bad model refused" 2
out=$(bash "$v" "http://127.0.0.1:$port" "$work/missing" 2>&1); rc=$?; expect "missing token file refused" 2
out=$(bash "$v" 2>&1); rc=$?; expect "usage" 2
stop

start reject
out=$(bash "$v" "http://127.0.0.1:$port" "$work/tok" 2>&1); rc=$?; expect "always-401 stub fails the 200 check" 1
stop

out=$(bash "$v" "http://127.0.0.1:$port" "$work/tok" 2>&1); rc=$?; expect "closed port fails" 1
case $out in *000*) echo "pass reports 000";; *) echo "FAIL no 000 reported"; fails=$((fails + 1));; esac

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
