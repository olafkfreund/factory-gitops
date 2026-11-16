"""Prove the cred-broker no-ops on a healthy long-lived credential and still
fails loudly when the runway is short. Factory#437."""
import base64, importlib.util, io, json, sys, time, urllib.error

def load():
    spec = importlib.util.spec_from_file_location("refresh", "/tmp/refresh_extracted.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def run(days_left, refresh_token="rt-fake", grant_ok=False):
    m = load()
    exp_ms = int((time.time() + days_left * 86400) * 1000)
    oauth = {"expiresAt": exp_ms}
    # A `claude setup-token` credential has NO refreshToken key at all, so the
    # no-token cases must omit it rather than set it empty (Factory#679).
    if refresh_token is not None:
        oauth["refreshToken"] = refresh_token
    cred = {"claudeAiOauth": oauth}
    recorded = {}

    def fake_k8s(method, path, body=None, content_type="application/json"):
        if method == "GET":
            return {"data": {m.KEY: base64.b64encode(json.dumps(cred).encode()).decode()}}
        recorded["patched"] = True
        return {}

    def fake_urlopen(req, timeout=None):
        # grant_ok models a provider that WOULD honour the refresh. Without it
        # every case ends in a 400 and never reaches the patch, which makes the
        # "was the credential rotated?" assertion below unfireable — the exact
        # blind spot that let Factory#679 through.
        if grant_ok:
            class R:
                def __enter__(self): return self
                def __exit__(self, *a): return False
                def read(self):
                    return json.dumps({"access_token": "at-new",
                                       "refresh_token": "rt-new",
                                       "expires_in": 28800}).encode()
            return R()
        raise urllib.error.HTTPError(
            "https://x", 400, "Bad Request", {},
            io.BytesIO(b'{"error":"invalid_grant"}'))

    m.k8s = fake_k8s
    m.urllib.request.urlopen = fake_urlopen
    def cap(outcome, detail, exp=None):
        recorded["outcome"] = outcome
    m.record = cap
    rc = m.main()
    return rc, recorded.get("outcome"), recorded.get("patched", False)

# (days_left, refresh_token, grant_ok, exit, outcome, patched?, label)
#
# ``refresh_token=None`` means the key is absent entirely — a `claude
# setup-token` credential. Factory#679: that used to be fatal, so the fleet was
# seeded WITH a usable refresh token to keep this job green, and the job then
# refreshed and rotated the year-long credential away.
#
# ``want_patched`` is the load-bearing column. The #679 incident exited 0 and
# recorded "ok" — by exit code and outcome string it looked like a clean run.
# The only thing that distinguished it was that the Secret had been rewritten.
CASES = (
    (363, "rt-fake", False, 0, "not-applicable:long-lived-credential", False, "long-lived, token rejected"),
    (5, "rt-fake", False, 3, "refresh-rejected:invalid_grant", False, "runway nearly gone"),
    (363, None, False, 0, "not-applicable:long-lived-credential", False, "setup-token, no refresh token"),
    (5, None, False, 2, "no-refresh-token", False, "no refresh token AND short runway"),
    # THE #679 REGRESSION: the provider would happily honour a refresh here.
    # A setup-token credential must return before ever asking.
    (363, None, True, 0, "not-applicable:long-lived-credential", False, "setup-token, grant WOULD succeed"),
    # ...while a genuine rotating credential must still be refreshed. Without
    # this case, "never patch" would pass by breaking the job entirely.
    (0.3, "rt-fake", True, 0, "ok", True, "rotating credential, refresh works"),
)

failures = []
for days, rt, grant_ok, want_rc, want_outcome, want_patched, label in CASES:
    rc, outcome, patched = run(days, refresh_token=rt, grant_ok=grant_ok)
    ok = rc == want_rc and outcome == want_outcome and patched == want_patched
    if patched != want_patched:
        print(f"     {label}: Secret patched={patched}, wanted {want_patched}"
              + (" — the credential was ROTATED AWAY" if patched else " — the refresh never happened"))
    print(f"{'ok  ' if ok else 'FAIL'} {label:36s} days={days:<6} rt={'yes' if rt else 'none':4s} "
          f"grant={'ok' if grant_ok else '400':3s} exit={rc} (want {want_rc})  outcome={outcome}")
    if not ok:
        failures.append(label)

# --- Factory#3687: the early alert -------------------------------------------
# Each case drives main() with a fake Anthropic + GitHub behind one urlopen and
# asserts the EXACT list of GitHub calls, so an error swallowed inside alert()
# cannot pass a "nothing was sent" check.
import os


def arun(hours_left, *, mode, token="t", existing=False, gh_fail=False, no_rt=False):
    """mode: invalid_grant | http503 | network | badjson | noreply. hours_left None = no expiresAt."""
    os.environ.pop("GITHUB_TOKEN", None)
    if token:
        os.environ["GITHUB_TOKEN"] = token
    os.environ["ALERT_REPO"] = "o/r"
    m = load()
    oauth = {} if hours_left is None else {"expiresAt": int((time.time() + hours_left * 3600) * 1000)}
    if not no_rt:
        oauth["refreshToken"] = "rt-fake"
    cred = {"claudeAiOauth": oauth}
    gh_calls, posted = [], []

    class R:
        def __init__(self, d): self.d = d
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return self.d
        def __iter__(self): return iter(())

    def fake_urlopen(req, timeout=None, context=None):
        if "api.github.com" in req.full_url:
            path = req.full_url.split("api.github.com", 1)[1]
            gh_calls.append((req.get_method(), path))
            if gh_fail:
                raise urllib.error.HTTPError(req.full_url, 500, "x", {}, io.BytesIO(b"{}"))
            if req.get_method() == "GET":
                body = [{"body": m.ALERT_MARKER + " old"}] if existing else []
                return R(json.dumps(body).encode())
            if req.data:
                posted.append(json.loads(req.data))
            return R(b'{"number": 7}')
        if mode == "network":
            raise urllib.error.URLError("boom secret-payload")
        if mode == "badjson":
            return R(b"<html>")
        if mode == "noreply":
            return R(b'{"x": 1}')
        code, text = (400, b'{"error":"invalid_grant"}') if mode == "invalid_grant" else (503, b"{}")
        raise urllib.error.HTTPError(req.full_url, code, "x", {}, io.BytesIO(text))

    m.k8s = lambda method, path, body=None, content_type="application/json": (
        {"data": {m.KEY: base64.b64encode(json.dumps(cred).encode()).decode()}} if method == "GET" else {})
    outcomes = []
    m.record = lambda outcome, detail, exp=None: outcomes.append(outcome)
    m.urllib.request.urlopen = fake_urlopen
    rc = m.main()
    return rc, outcomes[-1] if outcomes else None, gh_calls, posted


SEND = [("POST", "/repos/o/r/labels"), ("GET", "/repos/o/r/issues?state=open&labels=cred-broker&per_page=100"),
        ("POST", "/repos/o/r/issues")]
DEDUP = SEND[:2]
# (hours_left, kwargs, want_rc, want_outcome, want_gh_calls, label)
ALERT_CASES = (
    (3, dict(mode="invalid_grant"), 3, "refresh-rejected:invalid_grant", SEND, "invalid_grant at 3h alerts"),
    (3, dict(mode="invalid_grant", token=""), 3, "refresh-rejected:invalid_grant", [], "no token: inert, same exit"),
    (3, dict(mode="invalid_grant", existing=True), 3, "refresh-rejected:invalid_grant", DEDUP, "open issue: no second one"),
    (3, dict(mode="invalid_grant", gh_fail=True), 3, "refresh-rejected:invalid_grant", SEND[:1], "GitHub 500: exit unchanged"),
    (3, dict(mode="http503"), 3, "refresh-rejected:http_503", SEND, "http 503 at 3h alerts"),
    (50, dict(mode="http503"), 3, "refresh-rejected:http_503", [], "http 503 at 50h stays quiet"),
    (None, dict(mode="http503"), 3, "refresh-rejected:http_503", SEND, "http 503, unknown expiry alerts"),
    (3, dict(mode="network"), 3, "refresh-failed:network", SEND, "network at 3h alerts, exit 3"),
    (50, dict(mode="network"), 3, "refresh-failed:network", [], "network at 50h stays quiet"),
    (None, dict(mode="network"), 3, "refresh-failed:network", SEND, "network, unknown expiry alerts"),
    (3, dict(mode="badjson"), 3, "refresh-failed:network", SEND, "non-JSON 200 alerts, exit 3"),
    (3, dict(mode="noreply"), 4, "bad-refresh-response", SEND, "200 without tokens alerts, exit 4"),
    (120, dict(mode="noreply"), 4, "bad-refresh-response", [], "200 without tokens at 120h quiet"),
    (120, dict(mode="invalid_grant"), 3, "refresh-rejected:invalid_grant", SEND, "invalid_grant at 5d alerts"),
    (800, dict(mode="invalid_grant"), 0, "not-applicable:long-lived-credential", [], "long-lived exemption: nothing"),
    (120, dict(mode="http503", no_rt=True), 2, "no-refresh-token", SEND, "no refresh token, short runway alerts"),
)
for hours, kw, want_rc, want_outcome, want_gh, label in ALERT_CASES:
    rc, outcome, gh_calls, posted = arun(hours, **kw)
    ok = rc == want_rc and outcome == want_outcome and gh_calls == want_gh
    if ok and want_gh == SEND:
        body = posted[-1]["body"]
        ok = (want_outcome in body and "access-expires-at" in body and "k3d-factory" in body
              and "<!-- cred-broker:alert -->" in body and "secret-payload" not in body)
    print(f"{'ok  ' if ok else 'FAIL'} alert: {label:40s} exit={rc} outcome={outcome} gh={len(gh_calls)}")
    if not ok:
        failures.append(label)
        print(f"     want rc={want_rc} outcome={want_outcome} gh={want_gh}; got gh={gh_calls}")


if failures:
    # The short-runway case going green would be the dangerous direction: it
    # means a genuine credential expiry no longer pages anyone.
    print(f"::error::cred-broker decision logic wrong for: {', '.join(failures)}")
    sys.exit(1)
print("both directions correct")
