"""Prove the cred-broker no-ops on a healthy long-lived credential and still
fails loudly when the runway is short. Factory#437."""
import base64, importlib.util, io, json, sys, time, urllib.error

def load():
    spec = importlib.util.spec_from_file_location("refresh", "/tmp/refresh_extracted.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def run(days_left):
    m = load()
    exp_ms = int((time.time() + days_left * 86400) * 1000)
    cred = {"claudeAiOauth": {"expiresAt": exp_ms, "refreshToken": "rt-fake"}}
    recorded = {}

    def fake_k8s(method, path, body=None, content_type="application/json"):
        if method == "GET":
            return {"data": {m.KEY: base64.b64encode(json.dumps(cred).encode()).decode()}}
        recorded["patched"] = True
        return {}

    def fake_urlopen(req, timeout=None):
        raise urllib.error.HTTPError(
            "https://x", 400, "Bad Request", {},
            io.BytesIO(b'{"error":"invalid_grant"}'))

    m.k8s = fake_k8s
    m.urllib.request.urlopen = fake_urlopen
    real_record = m.record
    def cap(outcome, detail, exp=None):
        recorded["outcome"] = outcome
    m.record = cap
    rc = m.main()
    return rc, recorded.get("outcome")

# (days_left, expected exit, expected outcome)
CASES = (
    (363, 0, "not-applicable:long-lived-credential", "healthy long-lived credential"),
    (5, 3, "refresh-rejected:invalid_grant", "runway nearly gone"),
)

failures = []
for days, want_rc, want_outcome, label in CASES:
    rc, outcome = run(days)
    ok = rc == want_rc and outcome == want_outcome
    print(f"{'ok  ' if ok else 'FAIL'} {label:32s} days={days:<5} "
          f"exit={rc} (want {want_rc})  outcome={outcome}")
    if not ok:
        failures.append(label)

if failures:
    # The short-runway case going green would be the dangerous direction: it
    # means a genuine credential expiry no longer pages anyone.
    print(f"::error::cred-broker decision logic wrong for: {', '.join(failures)}")
    sys.exit(1)
print("both directions correct")
