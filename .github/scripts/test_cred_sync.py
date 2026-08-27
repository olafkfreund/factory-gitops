"""Prove cred-sync refuses every bad adoption, and still does the good one.

Factory#628: `exp()` returned 0 on any read failure, and 0 is not a sentinel
here -- it is the oldest possible timestamp. An unreadable destination lost the
comparison unconditionally, so a seed that had expired two months earlier was
copied over a working credential and logged as
`cred-sync: adopted fresher credential (+494672.6h)`. 494672.6h is 56 years:
seed_expiry_ms/3600000 with the other side at zero. A full TFactory
verification run died on `401 OAuth access token has been revoked`.

The script lives as an inline `args:` block scalar in three manifests, so
nothing imported it and nothing ran it. This extracts it from all three, proves
they are byte-identical (one engine, no drift), and exercises the real file I/O
path of the one it loaded.
"""
import ast
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
APPS = ("aifactory", "pfactory", "tfactory")


def extract(app):
    """Pull the cred-sync container's inline script out of a manifest."""
    lines = (REPO / "apps" / app / "manifests" / "manifests.yaml").read_text().splitlines()
    starts = [i for i, l in enumerate(lines) if l.strip() == "- name: cred-sync"]
    # Absence is a failure, not a pass: a renamed container must go red rather
    # than silently test nothing.
    if len(starts) != 1:
        raise SystemExit(f"::error::expected one cred-sync container in {app}, found {len(starts)}")
    a = next(j for j in range(starts[0], len(lines)) if lines[j].strip() == "- |")
    indent = len(lines[a + 1]) - len(lines[a + 1].lstrip())
    body = []
    for l in lines[a + 1:]:
        if l.strip() and len(l) - len(l.lstrip()) < indent:
            break
        body.append(l[indent:] if l.strip() else "")
    text = "\n".join(body)
    ast.parse(text)  # a script that does not parse cannot be tested
    return text


scripts = {app: extract(app) for app in APPS}
if len(set(scripts.values())) != 1:
    raise SystemExit("::error::the three vendored cred-sync copies have drifted; "
                     "they must stay byte-identical")
print(f"ok   three vendored copies identical ({len(scripts[APPS[0]].splitlines())} lines)")

path = pathlib.Path(tempfile.mkdtemp()) / "cred_sync.py"
path.write_text(scripts[APPS[0]])
spec = importlib.util.spec_from_file_location("cred_sync", path)
cs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cs)

NOW = int(time.time() * 1000)
VALID = NOW + 6 * 3600_000        # good credential, 6h of life left
OLDER = NOW + 1 * 3600_000        # also valid, less life left
EXPIRED = NOW - 61 * 86400_000    # the ~2-month-expired seed from the incident
BROKEN = "{not json"


def creds(expires):
    return json.dumps({"claudeAiOauth": {"accessToken": "REDACTED", "expiresAt": expires}})


def run(seed_text, dest_text):
    d = tempfile.mkdtemp()
    cs.SEED = os.path.join(d, "seed.json")
    cs.DEST = os.path.join(d, "dest.json")
    pathlib.Path(cs.SEED).write_text(seed_text)
    if dest_text is not None:
        pathlib.Path(cs.DEST).write_text(dest_text)
    adopt, why = cs.sync(now=NOW)
    after = pathlib.Path(cs.DEST).read_text() if os.path.exists(cs.DEST) else None
    overwritten = dest_text is not None and after != dest_text
    return adopt, overwritten, why


# (label, seed, dest, adopt?, must appear in the log)
CASES = (
    ("unreadable dest, valid seed", creds(VALID), BROKEN, False, "unreadable"),
    ("unreadable dest, expired seed", creds(EXPIRED), BROKEN, False, "already past"),
    # Deliberately flipped from refuse to adopt. When #168 wrote this, 0 was
    # ambiguous: exp() manufactured it on read failure, so refusing was the only
    # safe call. exp() now returns None for unreadable/unparseable/absent-key, so
    # a literal 0 can only come from a real `expiresAt: 0` -- a CLEARED token.
    # Refusing there wedges the pod forever: cred-sync will not repair a dead
    # credential from a valid seed, and every run dies at the planner with
    # "No OAuth token found" (observed 2026-08-27, TFactory spec 191).
    ("dest expiresAt:0, valid seed", creds(VALID), creds(0), True, "adopting seed"),
    # The bound itself still holds for a dest carrying a REAL timestamp, which is
    # the case Factory#628 was about.
    ("implausible seed, live dest", creds(NOW + 200 * 86400000), creds(VALID), False,
     "sanity bound"),
    ("expired seed, valid dest", creds(EXPIRED), creds(VALID), False, "refusing to adopt"),
    ("unreadable seed, valid dest", BROKEN, creds(VALID), False, "seed unreadable"),
    ("older seed, fresher dest", creds(OLDER), creds(VALID), False, ""),
    ("fresher seed, older dest", creds(VALID), creds(OLDER), True, "adopting seed"),
    ("dest absent, valid seed", creds(VALID), None, True, "adopting seed"),
)

failures = []
for label, seed, dest, want_adopt, want_log in CASES:
    adopt, overwritten, why = run(seed, dest)
    ok = adopt == want_adopt and want_log in why and overwritten == (want_adopt and dest is not None)
    print(f"{'ok  ' if ok else 'FAIL'} {label:31s} adopt={adopt!s:<5} log: {why or '(silent)'}")
    if not ok:
        failures.append(label)

# An adoption must say what it compared, not assert a conclusion. The old line
# ("adopted fresher credential") could not be checked against reality; this one
# carries both sides of the comparison.
_, _, why = run(creds(VALID), creds(OLDER))
if cs.ts(VALID) not in why or cs.ts(OLDER) not in why:
    print("::error::the adoption log line no longer states both expiries")
    failures.append("adoption log line")

if failures:
    # The dangerous direction is an adoption going green: that is a live
    # credential being overwritten by a dead one, reported as success.
    print(f"::error::cred-sync wrong for: {', '.join(failures)}")
    sys.exit(1)
print("all guards hold")
