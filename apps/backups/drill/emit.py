"""Step 4 of the restore drill: send the result to OpenObserve `job_health`.

Same stream, credential and /_json path as apps/audit-anchor-alert. Exit 1 when
the drill was not ok or the record was not delivered, so the Job goes red and
job-watchdog sees it.
"""
import base64
import json
import os
import sys
import urllib.request

S = os.environ.get("SCRATCH", "/scratch")
res = json.load(open(f"{S}/result.json"))
if os.path.exists(f"{S}/evidence.failed"):  # evidence upload failed: still report, still go red
    res["ok"] = False
    res["problems"] = res["problems"] + ["evidence_upload_failed"]
ok = bool(res["ok"])
rec = {
    "_timestamp": int(__import__("time").time() * 1_000_000),
    "source": "restore-drill",
    "kind": "restore_drill",
    "namespace": os.environ.get("NAMESPACE", "factory"),
    "cronjob": "postgres-restore-drill",
    "status": "ok" if ok else "restore_failed",
    **res,
}
oo = os.environ.get("OBSERVE_URL", "http://observe.factory.svc.cluster.local:5080").rstrip("/")
org, stream = os.environ.get("OO_ORG", "default"), os.environ.get("OO_STREAM", "job_health")
cred = base64.b64encode(f"{os.environ['OO_USER']}:{os.environ['OO_PASS']}".encode()).decode()
req = urllib.request.Request(
    f"{oo}/api/{org}/{stream}/_json",
    data=json.dumps([rec]).encode(),
    headers={"authorization": f"Basic {cred}", "content-type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=30) as r:
    body = json.load(r)
st = body.get("status")
failed = (st[0] if isinstance(st, list) and st else body).get("failed", 0)
if failed:
    print(f"emit: OpenObserve rejected the record: {body}", file=sys.stderr)
    sys.exit(1)
print(f"emit: delivered status={rec['status']} rto_seconds={res.get('rto_seconds')}")
sys.exit(0 if ok else 1)
