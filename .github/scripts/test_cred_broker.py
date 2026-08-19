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

if failures:
    # The short-runway case going green would be the dangerous direction: it
    # means a genuine credential expiry no longer pages anyone.
    print(f"::error::cred-broker decision logic wrong for: {', '.join(failures)}")
    sys.exit(1)
print("both directions correct")
