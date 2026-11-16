"""Decision logic and exit codes of alerts.py, with the network calls replaced."""
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

# missing stream is no_source, not ok, and not an error
rc, rec, *_ = run({"audit_chain": 0, "egress_denied": http(404)}, egress="egress_denied")
assert rc == 0 and rec["egress_anomaly"]["status"] == "no_source"
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
print("ok")
