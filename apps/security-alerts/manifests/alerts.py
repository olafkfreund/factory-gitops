#!/usr/bin/env python3
"""Auth-failure and egress alert rules (Factory#3688, R-009).

Every run evaluates both rules against OpenObserve, writes one `job_health` record per rule,
opens one GitHub issue per firing rule while none is open (inert without GITHUB_TOKEN) and, if
ALERT_WEBHOOK_URL is set, posts to it on every run in which a rule fires. Exits 1 if a rule
errored or a delivery failed. Stdlib only. Never prints a value or str(exception).
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

WINDOW_S = int(os.environ.get("WINDOW_SECONDS", "1800"))
AUTH_THRESHOLD = int(os.environ.get("AUTH_FAIL_THRESHOLD", "10"))
EGRESS_THRESHOLD = int(os.environ.get("EGRESS_THRESHOLD", "1"))
AUTH_STREAM = os.environ.get("AUTH_STREAM", "audit_chain")
EGRESS_STREAM = os.environ.get("EGRESS_STREAM", "")  # empty = no egress source yet
ALERT_REPO = os.environ.get("ALERT_REPO", "olafkfreund/Factory")
ALERT_LABEL = "security-alert"
DOC = "https://github.com/olafkfreund/factory-gitops/blob/main/docs/security-alerts.md"


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def _basic():
    return base64.b64encode(f"{os.environ['OO_USER']}:{os.environ['OO_PASS']}".encode()).decode()


def _oo():
    return os.environ.get("OBSERVE_URL", "http://observe.factory.svc.cluster.local:5080").rstrip("/")


def count(sql):
    """Row count from an OpenObserve SQL `SELECT count(*) AS n ...` over the window."""
    now = int(time.time() * 1_000_000)
    body = {"query": {"sql": sql, "start_time": now - WINDOW_S * 1_000_000,
                      "end_time": now + 1_000_000, "size": 1}}
    req = urllib.request.Request(
        f"{_oo()}/api/{os.environ.get('OO_ORG', 'default')}/_search?type=logs",
        data=json.dumps(body).encode(),
        headers={"authorization": f"Basic {_basic()}", "content-type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        hits = json.load(r).get("hits") or []
    return int(hits[0]["n"]) if hits and hits[0].get("n") is not None else 0


def evaluate(rule, stream, where, threshold):
    """(status, n). 404 means the stream does not exist: never read as zero."""
    if not stream:
        return "not_configured", None
    sql = f'SELECT count(*) AS n FROM "{stream}"' + (f" WHERE {where}" if where else "")
    try:
        n = count(sql)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return "no_source", None
        eprint(f"{rule}: OpenObserve HTTP {e.code}")
        return "error", None
    except Exception as e:  # noqa: BLE001
        eprint(f"{rule}: {type(e).__name__}")
        return "error", None
    return ("firing" if n >= threshold else "ok"), n


def emit(records):
    req = urllib.request.Request(
        f"{_oo()}/api/{os.environ.get('OO_ORG', 'default')}/{os.environ.get('OO_STREAM', 'job_health')}/_json",
        data=json.dumps(records).encode(),
        headers={"authorization": f"Basic {_basic()}", "content-type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.load(r)
    st = body.get("status")
    return (st[0] if isinstance(st, list) and st else body).get("failed", 0) == 0


def gh(method, path, body=None):
    req = urllib.request.Request(
        f"{os.environ.get('GITHUB_API', 'https://api.github.com')}{path}",
        data=None if body is None else json.dumps(body).encode(),
        headers={"authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
                 "accept": "application/vnd.github+json", "content-type": "application/json",
                 "user-agent": "factory-security-alerts"},
        method=method)
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def open_issues(firing):
    """One issue per firing rule while none is open. Never changes the exit code."""
    if not os.environ.get("GITHUB_TOKEN"):
        eprint("issues inert: no GITHUB_TOKEN")
        return
    try:
        try:
            gh("POST", f"/repos/{ALERT_REPO}/labels", {
                "name": ALERT_LABEL, "color": "b60205",
                "description": "Raised by security-alerts: an auth-failure or egress rule fired"})
        except urllib.error.HTTPError as e:
            if e.code != 422:  # already exists
                raise
        bodies = [i.get("body") or "" for i in gh(
            "GET", f"/repos/{ALERT_REPO}/issues?state=open&labels={ALERT_LABEL}&per_page=100") or []]
        for rule, n, threshold in firing:
            marker = f"<!-- security-alerts:{rule} -->"
            if any(marker in b for b in bodies):
                eprint(f"issue: one is already open for {rule}")
                continue
            new = gh("POST", f"/repos/{ALERT_REPO}/issues", {
                "title": f"security-alert: {rule} fired ({n} in {WINDOW_S // 60} min, threshold {threshold})",
                "labels": [ALERT_LABEL],
                "body": f"{marker}\nRule `{rule}` counted {n} in the last {WINDOW_S // 60} minutes "
                        f"(threshold {threshold}).\n\nTriage by the incident-response runbook; rule "
                        f"definitions and queries: {DOC}\n\nNo second issue is raised while this one "
                        f"is open."})
            eprint(f"ALERTED: opened {ALERT_REPO}#{new['number']} for {rule}")
    except Exception as e:  # noqa: BLE001
        eprint(f"warn: could not raise the issue: {type(e).__name__}")


def page(firing):
    """POST to the owner's webhook on every firing run. True unless a delivery failed."""
    url = os.environ.get("ALERT_WEBHOOK_URL")
    if not url or not firing:
        return True
    ok = True
    for rule, n, threshold in firing:
        req = urllib.request.Request(
            url, data=json.dumps({"text": f"security-alert {rule}: {n} in {WINDOW_S // 60} min "
                                          f"(threshold {threshold})", "dedup_key": rule}).encode(),
            headers={"content-type": "application/json"}, method="POST")
        try:
            urllib.request.urlopen(req, timeout=30).close()
        except Exception as e:  # noqa: BLE001  never print the URL
            eprint(f"page {rule}: {type(e).__name__}")
            ok = False
    return ok


def main():
    ts = int(time.time() * 1_000_000)
    rules = [
        ("auth_failure_spike", AUTH_STREAM, "action = 'auth.failure'", AUTH_THRESHOLD),
        ("egress_anomaly", EGRESS_STREAM, "", EGRESS_THRESHOLD),
    ]
    records, firing, rc = [], [], 0
    for rule, stream, where, threshold in rules:
        status, n = evaluate(rule, stream, where, threshold)
        eprint(f"{rule}: {status} n={n} threshold={threshold}")
        if status == "error":
            rc = 1
        if status == "firing":
            firing.append((rule, n, threshold))
        records.append({"_timestamp": ts, "source": "security-alerts", "kind": "security_alert",
                        "cronjob": "security-alerts", "rule": rule, "status": status,
                        "count": n, "threshold": threshold, "window_seconds": WINDOW_S})
    try:
        if not emit(records):
            eprint("emit: OpenObserve rejected the records")
            rc = 1
    except Exception as e:  # noqa: BLE001
        eprint(f"emit: {type(e).__name__}")
        rc = 1
    open_issues(firing)
    if not page(firing):
        rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
