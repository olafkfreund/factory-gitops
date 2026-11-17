"""Decision logic and exit codes of alerts.py, with the network calls replaced."""
import io
import json
import os
import sys
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.pop("GITHUB_TOKEN", None)
os.environ.pop("ALERT_WEBHOOK_URL", None)
import alerts  # noqa: E402


def http(code):
    return urllib.error.HTTPError("u", code, "x", {}, None)


def run(counts, egress="", token=False, webhook=False, open_bodies=()):
    """counts: dict stream -> int | Exception. Returns (rc, records, issues, posts)."""
    alerts.EGRESS_STREAM = egress
    seen, issues, posts = [], [], []

    def count(sql):
        v = counts[sql.split('"')[1]]
        if isinstance(v, Exception):
            raise v
        return v
    alerts.count = count
    alerts.emit = lambda recs: seen.append(recs) or True

    def gh(method, path, body=None):
        if method == "GET":
            return [{"body": b} for b in open_bodies]
        if path.endswith("/issues"):
            issues.append(body)
            return {"number": len(issues)}
        return None
    alerts.gh = gh
    alerts.urllib.request.urlopen = lambda req, timeout=0: (posts.append(req), type("R", (), {"close": lambda s: None})())[1]
    if token:
        os.environ["GITHUB_TOKEN"] = "t"
    else:
        os.environ.pop("GITHUB_TOKEN", None)
    if webhook:
        os.environ["ALERT_WEBHOOK_URL"] = "http://hook.invalid/x"
    else:
        os.environ.pop("ALERT_WEBHOOK_URL", None)
    rc = alerts.main()
    return rc, {r["rule"]: r for r in seen[0]}, issues, posts


# below and at the threshold; the SQL filters on auth.failure
rc, rec, issues, posts = run({"audit_chain": 9})
assert rc == 0 and rec["auth_failure_spike"]["status"] == "ok" and not issues and not posts
assert rec["egress_anomaly"]["status"] == "not_configured" and rec["egress_anomaly"]["count"] is None
rc, rec, *_ = run({"audit_chain": 10})
assert rc == 0 and rec["auth_failure_spike"]["status"] == "firing"
sqls = []
alerts.count = lambda sql: sqls.append(sql) or 0
alerts.evaluate("r", "audit_chain", "action = 'auth.failure'", 10)
assert "action = 'auth.failure'" in sqls[0]

# AIFactory#2079 dry run: the SQL evaluate() builds, run on rows shaped like AIFactory's audit_siem
# record and CFactory's forwarded rows; only auth.failure rows count.
import sqlite3
db = sqlite3.connect(":memory:")
db.execute('CREATE TABLE "audit_chain" (action TEXT, kind TEXT, source TEXT, reason TEXT)')
db.executemany('INSERT INTO "audit_chain" VALUES (?,?,?,?)', [
    ("auth.failure", None, "aifactory", "invalid_token"),
    ("auth.failure", None, "aifactory", "invalid_ws_token"),
    ("gate.reject", None, "cfactory", None),
    (None, "auth.failure", "cfactory", None),  # CFactory rows are keyed by kind, not action
])
alerts.count = lambda sql: db.execute(sql).fetchone()[0]
assert alerts.evaluate("r", "audit_chain", "action = 'auth.failure'", 2) == ("firing", 2)

# missing stream is no_source, not ok, and not an error
rc, rec, *_ = run({"audit_chain": 0, "egress_denied": http(404)}, egress="egress_denied")
assert rc == 0 and rec["egress_anomaly"]["status"] == "no_source"
# a missing AUTH stream fails the run (rc 1) so job-watchdog sees it; the record keeps no_source
rc, rec, *_ = run({"audit_chain": http(404)})
assert rc == 1 and rec["auth_failure_spike"]["status"] == "no_source"
# 3758: OpenObserve 400 "No field named action" (no row ever had it) is no_field: exit 0, egress still evaluated
def http400(body):
    return urllib.error.HTTPError("u", 400, "x", {}, io.BytesIO(body))

nofield = json.dumps({"code": 20004, "message": "Search field not found: Schema error: No field named action."}).encode()
rc, rec, *_ = run({"audit_chain": http400(nofield), "egress_denied": 1}, egress="egress_denied")
assert rc == 0 and rec["auth_failure_spike"]["status"] == "no_field" and rec["auth_failure_spike"]["count"] is None
assert rec["egress_anomaly"]["status"] == "firing"
# anything else 400 stays an error (exit 1, egress still evaluated, record still emitted)
for bad in (json.dumps({"code": 20004, "message": "No field named kind"}).encode(),
            json.dumps({"code": 20001, "message": "No field named action"}).encode(), b"not json", b""):
    rc, rec, *_ = run({"audit_chain": http400(bad), "egress_denied": 1}, egress="egress_denied")
    assert rc == 1 and rec["auth_failure_spike"]["status"] == "error" and rec["egress_anomaly"]["status"] == "firing"
# the unconfigured optional egress source never fails the run
rc, rec, *_ = run({"audit_chain": 0})
assert rc == 0 and rec["egress_anomaly"]["status"] == "not_configured"
# configured egress fires at its default threshold of 1
rc, rec, *_ = run({"audit_chain": 0, "egress_denied": 1}, egress="egress_denied")
assert rec["egress_anomaly"]["status"] == "firing"

# an auth query error still evaluates egress and exits 1
rc, rec, *_ = run({"audit_chain": http(500), "egress_denied": 3}, egress="egress_denied")
assert rc == 1 and rec["auth_failure_spike"]["status"] == "error" and rec["egress_anomaly"]["status"] == "firing"
rc, rec, *_ = run({"audit_chain": OSError()})
assert rc == 1

# issues: one per firing rule, none without a token, deduped on an open marker
rc, rec, issues, _ = run({"audit_chain": 50}, token=True)
assert len(issues) == 1 and "auth_failure_spike" in issues[0]["title"]
rc, rec, issues, _ = run({"audit_chain": 50}, token=True,
                         open_bodies=["<!-- security-alerts:auth_failure_spike -->"])
assert not issues
rc, rec, issues, _ = run({"audit_chain": 50})
assert not issues and rc == 0

# webhook: nothing when off or when nothing fires, one POST per firing rule each run
rc, _, _, posts = run({"audit_chain": 50})
assert not posts
rc, _, _, posts = run({"audit_chain": 1}, webhook=True)
assert not posts
rc, _, _, posts = run({"audit_chain": 50}, webhook=True)
assert len(posts) == 1 and b'"dedup_key": "auth_failure_spike"' in posts[0].data and rc == 0
alerts.urllib.request.urlopen = lambda req, timeout=0: (_ for _ in ()).throw(OSError())
os.environ["ALERT_WEBHOOK_URL"] = "http://hook.invalid/x"
assert alerts.page([("r", 1, 1)]) is False
# a malformed URL fails the delivery without raising or printing the URL
os.environ["ALERT_WEBHOOK_URL"] = "not a url SECRETVALUE"
alerts.urllib.request.urlopen = lambda req, timeout=0: None
import io, contextlib
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    assert alerts.page([("r", 1, 1)]) is False
assert "SECRETVALUE" not in buf.getvalue()
# a failing GitHub call exits 1
os.environ.pop("ALERT_WEBHOOK_URL")
def boom(*a, **k):
    raise OSError()
alerts.gh = boom
os.environ["GITHUB_TOKEN"] = "t"
alerts.count = lambda sql: 50
alerts.emit = lambda recs: True
assert alerts.main() == 1

# main() end to end with the REAL count() and emit(): only urlopen is stubbed, so the SQL
# main() builds, the window arithmetic, hits parsing and the OpenObserve failed-count check run.
import importlib
importlib.reload(alerts)
os.environ.update(OO_USER="u", OO_PASS="p")
os.environ.pop("GITHUB_TOKEN", None)
os.environ.pop("ALERT_WEBHOOK_URL", None)


def wire(n, failed=0):
    reqs = []

    def urlopen(req, timeout=0):
        reqs.append((req.full_url, json.loads(req.data)))
        out = {"hits": [{"n": n}]} if "_search" in req.full_url else {"status": [{"successful": 1, "failed": failed}]}
        return io.BytesIO(json.dumps(out).encode())
    alerts.urllib.request.urlopen = urlopen
    return reqs


reqs = wire(10)
assert alerts.main() == 0
(url, body), (_, rec_body) = [r for r in reqs if "_search" in r[0]][0], [r for r in reqs if "_json" in r[0]][0]
assert url.endswith("/api/default/_search?type=logs")
assert body["query"]["sql"] == 'SELECT count(*) AS n FROM "audit_chain" WHERE action = \'auth.failure\''
q = body["query"]
assert q["end_time"] - q["start_time"] == alerts.WINDOW_S * 1_000_000 + 1_000_000
assert {r["rule"]: r["status"] for r in rec_body}["auth_failure_spike"] == "firing"  # n parsed from hits
assert {r["rule"]: r["count"] for r in rec_body}["auth_failure_spike"] == 10
wire(9)
assert alerts.main() == 0
# a rejected record (failed > 0) fails the run
wire(0, failed=1)
assert alerts.main() == 1
print("ok")
