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


def run(existing, deployment_status=None, stamped=None, get_status=None):
    """Drive main() against a fake API server.

    existing          : 'correct' | 'stale' | 'absent'
    deployment_status : {name: http code} -- the PATCH (roll) fails with this
    stamped           : {name: resourceVersion} already on the pod template.
                        Absent from the dict means the consumer carries no
                        annotation, which is the state the live cluster was in
                        for ten days (Factory#606 convergence).
    get_status        : {name: http code} -- the READ of that Deployment fails
    """
    m = load()
    deployment_status = deployment_status or {}
    stamped = stamped or {}
    get_status = get_status or {}
    rolled, patched_secret, read = {}, [], []

    def fake_k8s(method, path, body=None, content_type="application/json"):
        if path.endswith(f"/secrets/{m.SRC}"):
            return ROOT
        if "/deployments/" in path:
            name = path.rsplit("/", 1)[-1]
            if method == "GET":
                read.append(name)
                code = get_status.get(name)
                if code:
                    raise urllib.error.HTTPError(path, code, "nope", {}, None)
                ann = {m.ANNOTATION: stamped[name]} if name in stamped else {}
                return {"spec": {"template": {"metadata": {"annotations": ann}}}}
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
    m._read = read
    return rc, rolled, patched_secret, m


CONSUMERS = ("aifactory", "pfactory", "tfactory", "cfactory")
failures = []


def check(label, cond, detail=""):
    print(f"{'ok  ' if cond else 'FAIL'} {label}{'  ' + detail if detail else ''}")
    if not cond:
        failures.append(label)


# 1. Nothing changed AND every consumer already carries the current stamp ->
#    nothing rolled. A rotation that did not happen must not restart the fleet
#    every hour. This is the property that makes the convergence below safe:
#    lose it and the reconciler rolls all four on every run, forever.
STAMPED = dict.fromkeys(CONSUMERS, "1")  # "1" = the Secret's resourceVersion in the fake
rc, rolled, patched, m = run("correct", stamped=STAMPED)
check("already derived and all stamped: exit 0, no Secret write, no roll",
      rc == 0 and not patched and not rolled,
      f"exit={rc} rolled={sorted(rolled)}")

# 1b. Factory#606 convergence. The live cluster spent ten days here: the Secret
#     was correct, the job printed ok hourly, and NOT ONE consumer carried the
#     annotation -- because the old code returned early whenever the Secret
#     matched, so `roll` was reachable only on the run that changed it. A roll
#     that failed once was never retried. Reverting to that early return makes
#     this case report ok while rolling nothing, which is the failure.
rc, rolled, patched, m = run("correct", stamped={})
check("derived but nothing stamped: converge and roll all four",
      rc == 0 and not patched and sorted(rolled) == sorted(CONSUMERS),
      f"exit={rc} rolled={sorted(rolled)}")

# 1c. Only the drifted consumer is touched. Rolling the compliant ones would be
#     an unnecessary restart of a healthy pod.
rc, rolled, patched, m = run("correct", stamped={**STAMPED, "pfactory": "old"})
check("one consumer behind: only that one is rolled",
      rc == 0 and sorted(rolled) == ["pfactory"],
      f"exit={rc} rolled={sorted(rolled)}")

# 1d. A consumer whose state cannot be READ has not been shown to be current,
#     so it is treated as drift (rule 4.7). NOTE the coupling this creates: the
#     Role must grant `get` on deployments, or every run reads 403, calls every
#     consumer drifted, and rolls the fleet hourly. Asserted below.
rc, rolled, patched, m = run("correct", stamped=STAMPED, get_status={"tfactory": 403})
check("unreadable consumer: treated as drift, not as current",
      rc == 0 and sorted(rolled) == ["tfactory"],
      f"exit={rc} rolled={sorted(rolled)}")

# 1e. A consumer that is not deployed has no pod on the old header.
import contextlib as _c, io as _io  # noqa: E402
_buf = _io.StringIO()
with _c.redirect_stdout(_buf):
    rc, rolled, patched, m = run("correct", stamped=STAMPED, get_status={"cfactory": 404})
_msg = _buf.getvalue()
check("consumer not deployed: not drift, nothing rolled",
      rc == 0 and not rolled, f"exit={rc} rolled={sorted(rolled)}")

# 1f. ...and the success line must report what was VERIFIED, not len(CONSUMERS).
#     Saying "all 4 stamped" after a 404 skipped one is a count asserted rather
#     than measured -- the defect this script exists to stop, one level down.
check("success line counts only the consumers actually examined",
      "3/4" in _msg and "1 not deployed" in _msg and "all 4" not in _msg,
      _msg.strip().splitlines()[-1] if _msg.strip() else "<no output>")

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

# 7. The RBAC coupling behind case 1d, asserted against the manifest rather
#    than trusted. `drifted` READS each Deployment; if the Role grants only
#    `patch`, every read 403s, the fail-closed rule calls all four drifted, and
#    the reconciler rolls the entire fleet EVERY HOUR. The script change and the
#    Role change are one change, and this is what keeps them together.
import pathlib, re  # noqa: E402

_MANIFEST = pathlib.Path(__file__).resolve().parents[2] / "apps/observe/manifests/manifests.yaml"
_rule = re.search(
    r'resources:\s*\["deployments"\].*?verbs:\s*\[([^\]]*)\]', _MANIFEST.read_text(), re.S
)
_verbs = _rule.group(1) if _rule else "<no deployments rule found>"
check("Role grants get AND patch on deployments (else hourly fleet restart)",
      '"get"' in _verbs and '"patch"' in _verbs, f"verbs=[{_verbs}]")

if failures:
    print(f"::error::observe-otlp-auth-sync wrong for: {', '.join(failures)}")
    sys.exit(1)
print("rotation reaches the consumers, and a missed roll converges")
