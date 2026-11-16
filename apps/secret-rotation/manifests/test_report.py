"""Decision logic and exit codes of report.py, with the network calls replaced."""
import io
import os
import sys
import urllib.error
from datetime import date, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import report  # noqa: E402

T = date(2027, 3, 1)
A = report.ANN


def stamp(days_ago):
    return {A: (T - timedelta(days=days_ago)).isoformat()}


# boundaries: factory-secrets is 90d, due_soon within 30d, overdue strictly past the max
assert report.classify("factory-secrets", stamp(0), T)[0] == "ok"
assert report.classify("factory-secrets", stamp(59), T)[0] == "ok"
assert report.classify("factory-secrets", stamp(60), T)[0] == "due_soon"
assert report.classify("factory-secrets", stamp(90), T)[0] == "due_soon"
assert report.classify("factory-secrets", stamp(91), T)[0] == "overdue"
assert report.classify("minio-creds", stamp(365), T)[0] == "due_soon"
assert report.classify("minio-creds", stamp(366), T)[0] == "overdue"
# unstamped is measured from the policy start (2026-11-07): 114 days before T
assert report.classify("minio-creds", {}, T) == ("unstamped", 114, 365)
assert report.classify("factory-secrets", {}, T)[0] == "overdue"
assert report.classify("minio-creds", {}, date(2027, 11, 8))[0] == "overdue"
for bad in ("x", "2027-13-01", "2099-01-01", ""):
    assert report.classify("minio-creds", {A: bad}, T)[0] == "unstamped", bad
assert "PartialObjectMetadata" in report.META

emitted, issues = [], []
report.emit = lambda recs: emitted.append(recs) or True
os.environ.pop("GITHUB_TOKEN", None)


def http(code):
    return urllib.error.HTTPError("u", code, "m", {}, io.BytesIO(b""))


# 1. all stamped, nothing overdue: exit 0, one record per Secret, no values anywhere
report.k8s_meta = lambda n: stamp(1)
assert report.main(T) == 0 and len(emitted[-1]) == len(report.POLICY)
assert {r["status"] for r in emitted[-1]} == {"ok"}

# 2. 404 is `missing` (exit 0); 403 emits what it has, then exits 1
def meta(n):
    if n == "minio-creds":
        raise http(404)
    if n == "odin-ssh-key":
        raise http(403)
    return stamp(1)
report.k8s_meta = meta
n = len(emitted)
assert report.main(T) == 1 and len(emitted) == n + 1
st = {r["secret"]: r["status"] for r in emitted[-1]}
assert st["minio-creds"] == "missing" and st["odin-ssh-key"] == "error" and st["factory-secrets"] == "ok"

# 3. delivery failure exits 1
report.k8s_meta = lambda n: stamp(1)
report.emit = lambda recs: False
assert report.main(T) == 1
report.emit = lambda recs: emitted.append(recs) or True

# 4. overdue: one issue per Secret, deduped against an open issue, inert without a token
def fake_gh(method, path, body=None):
    if method == "POST" and path.endswith("/issues"):
        issues.append(body)
        return {"number": len(issues)}
    if method == "GET":
        return [{"body": "<!-- secret-rotation:minio-creds -->"}]
    return None
report.gh = fake_gh
report.k8s_meta = lambda n: stamp(400)
assert report.main(T) == 0 and issues == []  # no token: inert
os.environ["GITHUB_TOKEN"] = "x"
assert report.main(T) == 0
titles = [i["title"] for i in issues]
assert len(issues) == len(report.POLICY) - 1, titles  # minio-creds already has an open issue
assert not any("minio-creds" in t for t in titles)
assert all("secret-rotation:" in i["body"] and i["labels"] == ["secret-rotation"] for i in issues)
print("OK")
