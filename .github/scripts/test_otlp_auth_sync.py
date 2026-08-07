"""Prove observe-otlp-auth-sync rolls the consumers when the header changes.

Factory#606: `OTEL_EXPORTER_OTLP_HEADERS` comes from a `secretKeyRef`, which
kubelet resolves once at container start and never refreshes. So #465 made the
value correct and left every running pod on the old one -- aifactory exported
nothing for 23 hours and the window closed only when something unrelated
restarted it. Rewriting the Secret is not the job; the consumers running on the
new value is the job.

Run after extract_embedded_script.py has lifted sync.py out of the ConfigMap.
"""
import base64
import importlib.util
import json
import sys
import urllib.error


def load():
    spec = importlib.util.spec_from_file_location("sync", "/tmp/otlp_sync_extracted.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


ROOT = {"data": {"email": base64.b64encode(b"root@example.invalid").decode(),
                 "password": base64.b64encode(b"pw").decode()}}


def wanted_header(m):
    basic = base64.b64encode(b"root@example.invalid:pw").decode()
    return base64.b64encode(f"Authorization=Basic {basic}".encode()).decode()


def run(existing, deployment_status=None):
    """existing: 'correct' | 'stale' | 'absent'. deployment_status: {name: http code}."""
    m = load()
    deployment_status = deployment_status or {}
    rolled, patched_secret = {}, []

    def fake_k8s(method, path, body=None, content_type="application/json"):
        if path.endswith(f"/secrets/{m.SRC}"):
            return ROOT
        if "/deployments/" in path:
            name = path.rsplit("/", 1)[-1]
            code = deployment_status.get(name)
            if code:
                raise urllib.error.HTTPError(path, code, "nope", {}, None)
            rolled[name] = (body["spec"]["template"]["metadata"]["annotations"])
            return {}
        if path.endswith(f"/secrets/{m.DST}") or path.endswith("/secrets"):
            if method == "GET":
                if existing == "absent":
                    raise urllib.error.HTTPError(path, 404, "not found", {}, None)
                headers = wanted_header(m) if existing == "correct" else "c3RhbGU="
                return {"data": {"headers": headers}, "metadata": {"resourceVersion": "1"}}
            patched_secret.append(body)
            return {"metadata": {"resourceVersion": "4242"}}
        raise AssertionError(f"unexpected call {method} {path}")

    m.k8s = fake_k8s
    rc = m.main()
    return rc, rolled, patched_secret, m


CONSUMERS = ("aifactory", "pfactory", "tfactory", "cfactory")
failures = []


def check(label, cond, detail=""):
    print(f"{'ok  ' if cond else 'FAIL'} {label}{'  ' + detail if detail else ''}")
    if not cond:
        failures.append(label)


# 1. Nothing changed -> nothing rolled. A rotation that did not happen must not
#    restart the fleet every hour.
rc, rolled, patched, m = run("correct")
check("already derived: exit 0, no Secret write, no roll", rc == 0 and not patched and not rolled,
      f"exit={rc} rolled={sorted(rolled)}")

# 2. The regression itself: value corrected, consumers must be rolled with the
#    Secret's NEW resourceVersion.
rc, rolled, patched, m = run("stale")
check("stale header: exit 0 and all four rolled",
      rc == 0 and sorted(rolled) == sorted(CONSUMERS),
      f"exit={rc} rolled={sorted(rolled)}")
check("annotation carries the new resourceVersion",
      all(v == {m.ANNOTATION: "4242"} for v in rolled.values()),
      str(sorted(rolled.values(), key=str)[:1]))

# 3. Secret absent -> created, and the consumers still get rolled.
rc, rolled, patched, m = run("absent")
check("Secret created: exit 0 and all four rolled",
      rc == 0 and sorted(rolled) == sorted(CONSUMERS), f"exit={rc}")

# 4. A consumer that cannot be rolled is the dangerous state: the value is right
#    and something is still exporting with the old one. It must not exit 0.
rc, rolled, patched, m = run("stale", {"tfactory": 403})
check("roll refused: exit 4, not 0", rc == 4, f"exit={rc}")

# 5. A Deployment that is not deployed has no pod on the old header.
rc, rolled, patched, m = run("stale", {"cfactory": 404})
check("consumer not deployed: exit 0, the other three rolled",
      rc == 0 and sorted(rolled) == ["aifactory", "pfactory", "tfactory"], f"exit={rc}")

# 6. The header must never be printed, and neither must a digest of it.
import contextlib, io  # noqa: E402
buf = io.StringIO()
with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
    run("stale")
out = buf.getvalue()
check("no credential material in the output",
      wanted_header(m) not in out and "pw" not in out.replace("password", ""))

if failures:
    print(f"::error::observe-otlp-auth-sync wrong for: {', '.join(failures)}")
    sys.exit(1)
print("rotation reaches the consumers")
