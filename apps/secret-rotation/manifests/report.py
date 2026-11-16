#!/usr/bin/env python3
"""Report the age of each listed Secret's last rotation (Factory#314). Rotates nothing.

Reads ONLY metadata: every GET asks for PartialObjectMetadata, so the API never sends
a Secret value to this process. The owner stamps `rotation.factory.dev/rotated-at`
(YYYY-MM-DD, the oldest evidenced last-rotated date among the credentials in that Secret)
after a rotation; see docs/secrets-management.md "Rotation age report".

Emits one `job_health` record per Secret, opens one GitHub issue per overdue Secret
(cred-broker pattern, inert without GITHUB_TOKEN), exits 1 on an API or delivery failure.
Stdlib only. Never prints a value.
"""

import base64
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import date

NS = "factory"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
ANN = "rotation.factory.dev/rotated-at"
# Same start date as scripts/rotation-ledger-check.py: an unstamped Secret is measured from here.
POLICY_START = date(2026, 11, 7)
DUE_SOON_DAYS = 30
# factory-secrets holds the API tokens (90d, Factory encryption-key-mgmt.md runbook R-016).
# Keep in sync with the Role in manifests.yaml and Factory docs/compliance/policies/key-rotation.md.
POLICY = {
    "factory-secrets": 90,
    **{n: 365 for n in (
        "minio-creds", "factory-db-aifactory", "factory-db-pfactory", "factory-db-tfactory",
        "cfactory-api-keys", "oauth2-proxy-cfactory", "oauth2-proxy-observe", "oauth2-proxy-odin",
        "observe-root", "odin-ssh-key", "otel-otlp-auth", "factory-cli-creds")},
}
ALERT_REPO = os.environ.get("ALERT_REPO", "olafkfreund/Factory")
ALERT_LABEL = "secret-rotation"
RUNBOOK = "https://github.com/olafkfreund/factory-gitops/blob/main/docs/secrets-management.md#rotation-age-report"
META = "application/json;as=PartialObjectMetadata;g=meta.k8s.io;v=v1"


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def classify(name, annotations, today):
    """(status, age_days, max_age) from metadata only."""
    max_age = POLICY[name]
    raw = (annotations or {}).get(ANN, "")
    try:
        rotated = date.fromisoformat(raw) if len(raw) == 10 else None
    except ValueError:
        rotated = None
    if rotated is None or rotated > today:  # missing, malformed or future-dated
        status0, since = "unstamped", POLICY_START
    else:
        status0, since = "ok", rotated
    age = (today - since).days
    if age > max_age:
        return "overdue", age, max_age
    if status0 == "unstamped":
        return "unstamped", age, max_age
    return ("due_soon" if max_age - age <= DUE_SOON_DAYS else "ok"), age, max_age


def k8s_meta(name):
    with open(f"{SA}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(
        f"https://kubernetes.default.svc/api/v1/namespaces/{NS}/secrets/{name}",
        headers={"authorization": f"Bearer {token}", "accept": META},
    )
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        obj = json.load(r)
    if "data" in obj or "stringData" in obj:  # the server ignored the header: refuse to touch it
        raise RuntimeError("secret value returned; metadata-only negotiation failed")
    return obj.get("metadata", {}).get("annotations") or {}


def emit(records):
    oo = os.environ.get("OBSERVE_URL", "http://observe.factory.svc.cluster.local:5080").rstrip("/")
    org, stream = os.environ.get("OO_ORG", "default"), os.environ.get("OO_STREAM", "job_health")
    cred = base64.b64encode(f"{os.environ['OO_USER']}:{os.environ['OO_PASS']}".encode()).decode()
    req = urllib.request.Request(
        f"{oo}/api/{org}/{stream}/_json",
        data=json.dumps(records).encode(),
        headers={"authorization": f"Basic {cred}", "content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.load(r)
    st = body.get("status")
    return (st[0] if isinstance(st, list) and st else body).get("failed", 0) == 0


def gh(method, path, body=None):
    req = urllib.request.Request(
        f"{os.environ.get('GITHUB_API', 'https://api.github.com')}{path}",
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
            "accept": "application/vnd.github+json",
            "content-type": "application/json",
            "user-agent": "factory-secret-rotation",
        },
        method=method,
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def alert(overdue):
    """One issue per overdue Secret, once while it stays open. Never changes the exit code."""
    if not os.environ.get("GITHUB_TOKEN"):
        eprint("alerting inert: no GITHUB_TOKEN")
        return
    if not overdue:
        return
    try:
        try:
            gh("POST", f"/repos/{ALERT_REPO}/labels", {
                "name": ALERT_LABEL, "color": "b60205",
                "description": "Raised by secret-rotation-report: a Secret is past its rotation interval"})
        except urllib.error.HTTPError as e:
            if e.code != 422:  # already exists
                raise
        open_bodies = [i.get("body") or "" for i in gh(
            "GET", f"/repos/{ALERT_REPO}/issues?state=open&labels={ALERT_LABEL}&per_page=100") or []]
        for name, age, max_age in overdue:
            marker = f"<!-- secret-rotation:{name} -->"
            if any(marker in b for b in open_bodies):
                eprint(f"alert: an open issue already exists for {name}")
                continue
            new = gh("POST", f"/repos/{ALERT_REPO}/issues", {
                "title": f"secret-rotation: {name} is past its {max_age}-day rotation interval",
                "labels": [ALERT_LABEL],
                "body": f"""{marker}
`factory/{name}` is {age} days past its last evidenced rotation (maximum {max_age}).

Rotate it by the runbook ({RUNBOOK}), then stamp the Secret in the same window:
`kubectl -n factory annotate secret {name} --overwrite {ANN}=<oldest-date>` (the oldest
evidenced last-rotated date among its credentials) and update the ledger row. Stamping without a
rotation does not make the credential newer; it only resets this report.

This issue is not updated and no second one is raised while it is open.""",
            })
            eprint(f"ALERTED: opened {ALERT_REPO}#{new['number']} for {name}")
    except Exception as e:  # noqa: BLE001
        eprint(f"warn: could not raise the alert issue: {type(e).__name__}")


def main(today=None):
    today = today or date.today()
    ts = int(time.time() * 1_000_000)
    records, rc = [], 0
    for name in POLICY:
        try:
            ann = k8s_meta(name)
        except urllib.error.HTTPError as e:
            ann = None
            status, age, max_age = ("missing", None, POLICY[name]) if e.code == 404 else ("error", None, POLICY[name])
            if e.code != 404:
                rc = 1
                eprint(f"{name}: API HTTP {e.code}")
        except Exception as e:  # noqa: BLE001  never str(e): it can carry payload
            ann, status, age, max_age, rc = None, "error", None, POLICY[name], 1
            eprint(f"{name}: {type(e).__name__}")
        if ann is not None:
            status, age, max_age = classify(name, ann, today)
        eprint(f"{name}: {status} age={age} max={max_age}")
        records.append({
            "_timestamp": ts, "source": "secret-rotation", "kind": "secret_rotation",
            "namespace": NS, "cronjob": "secret-rotation-report", "secret": name,
            "status": status, "age_days": age, "max_age_days": max_age,
        })
    try:
        if not emit(records):
            eprint("emit: OpenObserve rejected the records")
            rc = 1
    except Exception as e:  # noqa: BLE001
        eprint(f"emit: {type(e).__name__}")
        rc = 1
    alert([(r["secret"], r["age_days"], r["max_age_days"]) for r in records if r["status"] == "overdue"])
    return rc


if __name__ == "__main__":
    sys.exit(main())
