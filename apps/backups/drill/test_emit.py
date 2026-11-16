"""emit.py against a local HTTP stub: payload, auth and the exit code."""
import base64, json, os, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

got = {}

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        got["path"] = self.path
        got["auth"] = self.headers["authorization"]
        got["body"] = json.loads(self.rfile.read(int(self.headers["content-length"])))
        out = json.dumps({"status": [{"successful": 1, "failed": 0}]}).encode()
        self.send_response(200); self.send_header("content-length", str(len(out))); self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a): pass

srv = HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
here = os.path.dirname(os.path.abspath(__file__))

def run(result, evidence_failed=False):
    d = tempfile.mkdtemp()
    with open(f"{d}/result.json", "w") as f:
        json.dump(result, f)
    if evidence_failed:
        open(f"{d}/evidence.failed", "w").close()
    env = dict(os.environ, SCRATCH=d, OO_USER="u", OO_PASS="p",
               OBSERVE_URL=f"http://127.0.0.1:{srv.server_port}")
    return subprocess.run([sys.executable, f"{here}/emit.py"], env=env).returncode

base = {"ok": True, "problems": [], "rto_seconds": 42}
assert run(base) == 0
assert got["path"] == "/api/default/job_health/_json"
assert got["auth"] == "Basic " + base64.b64encode(b"u:p").decode()
rec = got["body"][0]
assert rec["status"] == "ok" and rec["cronjob"] == "postgres-restore-drill" and rec["rto_seconds"] == 42
assert run({**base, "ok": False, "problems": ["x"]}) == 1 and got["body"][0]["status"] == "restore_failed"
assert run(base, evidence_failed=True) == 1
assert "evidence_upload_failed" in got["body"][0]["problems"]
os.environ["CRONJOB"] = "minio-restore-drill"; os.environ["DRILL_KIND"] = "minio_restore_drill"
assert run(base) == 0 and got["body"][0]["cronjob"] == "minio-restore-drill" and got["body"][0]["kind"] == "minio_restore_drill"
print("ALL PASS")
