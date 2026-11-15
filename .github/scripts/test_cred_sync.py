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

factory-gitops#332: also exercise the container's preStop hook in a PID namespace.
An early SIGTERM is lost by PID 1 until Python installs its handler; the hook
must wait for that handler before allowing the stop signal through.
"""
import ast
import concurrent.futures
import importlib.util
import json
import os
import pathlib
import re
import shlex
import subprocess
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


def prestop(app):
    lines = (REPO / "apps" / app / "manifests" / "manifests.yaml").read_text().splitlines()
    starts = [i for i, line in enumerate(lines) if line.strip() == "- name: cred-sync"]
    if len(starts) != 1:
        raise SystemExit(f"::error::expected one cred-sync container in {app}, found {len(starts)}")
    indent = len(lines[starts[0]]) - len(lines[starts[0]].lstrip())
    item = []
    for line in lines[starts[0] + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        item.append(line)
    hooks = [line for line in item if line.strip().startswith("lifecycle:")]
    if len(hooks) != 1:
        raise SystemExit(f"::error::expected one cred-sync lifecycle in {app}, found {len(hooks)}")
    match = re.search(r"preStop:\s*\{\s*exec:\s*\{\s*command:\s*(\[.*\])", hooks[0])
    if not match:
        raise SystemExit(f"::error::no inline cred-sync preStop command in {app}")
    try:
        return json.loads(match.group(1))
    except json.JSONDecodeError as error:
        raise SystemExit(f"::error::invalid cred-sync preStop command in {app}: {error}") from error


hooks = {app: prestop(app) for app in APPS}
if len({tuple(command) for command in hooks.values()}) != 1:
    raise SystemExit("::error::the three cred-sync preStop commands have drifted")
hook = hooks[APPS[0]]
sudo = []
unshare = ["unshare", "-Urpf", "--kill-child", "--mount-proc"]
probe = [*sudo, "timeout", "-s", "KILL", "5", *unshare, "true"]
if subprocess.run(probe, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
    sudo = ["sudo", "-n"]
    unshare = ["unshare", "-pf", "--kill-child", "--mount-proc"]
    probe = [*sudo, "timeout", "-s", "KILL", "5", *unshare, "true"]
    if subprocess.run(probe, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise SystemExit("::error::cannot run a PID namespace with unshare or sudo")

driver = """\
while [ ! -e "$1/started" ]; do sleep 0.05; done
d=$1; wait=$2; shift 2
sleep "$wait"
if grep -Eq '^SigCgt:.*[4-7c-f][0-9a-f]{3}$' /proc/1/status; then
    echo caught > "$d/window"
else
    echo open > "$d/window"
fi
date +%s.%N > "$d/stop"
if [ "$#" -gt 0 ]; then
    rc=0; "$@" || rc=$?
    echo "$rc" > "$d/hookrc"
fi
kill -TERM 1
"""
payload = ("import os, sys, time; assert os.getpid() == 1; "
           "open(sys.argv[2] + '/started', 'w').close(); "
           "time.sleep(float(sys.argv[3])); exec(open(sys.argv[1]).read())")


def stop_case(label, delay, wait, use_hook, limit):
    with tempfile.TemporaryDirectory() as directory:
        d = pathlib.Path(directory)
        driver_path = d / "driver.sh"
        driver_path.write_text(driver)
        driver_args = ["sh", str(driver_path), str(d), str(wait), *(hook if use_hook else [])]
        python_args = [sys.executable, "-u", "-c", payload, str(path), str(d), str(delay)]
        command = " ".join(map(shlex.quote, driver_args)) + " & exec " + " ".join(map(shlex.quote, python_args))
        result = subprocess.run([*sudo, "timeout", "-s", "KILL", str(limit),
                                 *unshare, "sh", "-c", command],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        exited = time.time()
        def marker(name):
            file = d / name
            return file.read_text().strip() if file.exists() else None
        window, hookrc, stop = marker("window"), marker("hookrc"), marker("stop")
        elapsed = exited - float(stop) if stop is not None else None
        if label == "early SIGTERM control":
            ok = window == "open" and result.returncode in (-9, 137) and elapsed is not None and elapsed >= 6
        elif label == "early SIGTERM with hook":
            ok = window == "open" and hookrc == "0" and result.returncode == 0 and elapsed is not None and elapsed < 8
        else:
            ok = hookrc == "0" and result.returncode == 0 and elapsed is not None and elapsed < 5
        return ok, f"{label:31s} rc={result.returncode} window={window} hookrc={hookrc} stop-to-exit={elapsed}"


stop_cases = (("early SIGTERM control", 3, 0, False, 10),
              ("early SIGTERM with hook", 3, 0, True, 15),
              ("ready handler with hook", 0, 0, True, 15),
              ("delayed stop with hook", 0, 30, True, 45))
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    futures = [pool.submit(stop_case, *case) for case in stop_cases]
    for case, future in zip(stop_cases, futures):
        try:
            ok, message = future.result()
        except Exception as error:
            ok, message = False, f"{case[0]}: {type(error).__name__}: {error}"
        print(f"{'ok  ' if ok else 'FAIL'} {message}")
        if not ok:
            failures.append(case[0])

if failures:
    # The dangerous direction is an adoption going green: that is a live
    # credential being overwritten by a dead one, reported as success.
    print(f"::error::cred-sync wrong for: {', '.join(failures)}")
    sys.exit(1)
print("all guards hold")
