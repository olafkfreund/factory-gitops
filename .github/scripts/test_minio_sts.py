#!/usr/bin/env python3
"""Run the aifactory-sts block of the MinIO PostSync hook against a stub `mc` (#337).

The block is inline shell in apps/minio/manifests/manifests.yaml, so nothing else
executes it. Checks: a re-sync where `policy attach` fails with "already attached"
still succeeds; a genuine attach failure still fails; rotation disables the previous
user holding the policy and never the current one.
"""
import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile

M = pathlib.Path("apps/minio/manifests/manifests.yaml").read_text().splitlines()
start = next(i for i, l in enumerate(M) if l.strip().startswith('if [ -n "${STS_ACCESS_KEY'))
end = next(i for i in range(start, len(M)) if M[i] == " " * 14 + "fi")
block = "\n".join(l[14:] for l in M[start : end + 1])

STUB = r"""#!/bin/sh
echo "$*" >> "$MC_LOG"
case "$*" in
  "admin policy attach"*) [ "$ATTACH" = ok ] || { echo "already attached" >&2; exit 1; } ;;
  "admin user info"*) echo "AccessKey: aifactory-sts"; case "$INFO" in attached) echo "PolicyName: aifactory-sts" ;; readonly) echo "PolicyName: readonly" ;; extra) echo "PolicyName: aifactory-sts-extra" ;; prefixed) echo "PolicyName: other-aifactory-sts" ;; esac ;;
  "admin user list"*) [ -z "$LISTFAIL" ] || exit 1; printf '%s\n' \
    '{"status":"success","accessKey":"OLDKEY","policyName":"aifactory-sts","userStatus":"enabled"}' \
    '{"status":"success","accessKey":"NEWKEY","policyName":"aifactory-sts","userStatus":"enabled"}' \
    '{"status":"success","accessKey":"OTHER","policyName":"readonly","userStatus":"enabled"}' ;;
esac
exit 0
"""


def run(attach, info, **extra):
    with tempfile.TemporaryDirectory() as d:
        mc = pathlib.Path(d, "mc")
        mc.write_text(STUB)
        mc.chmod(0o755)
        # Only the stub and cat on PATH: the real image has no grep, sed or awk.
        os.symlink(shutil.which("cat"), f"{d}/cat")
        env = dict(os.environ, PATH=d, MC_LOG=f"{d}/log",
                   ATTACH=attach, INFO=info, **extra, STS_ACCESS_KEY="NEWKEY", STS_SECRET_KEY="s")
        r = subprocess.run([*shlex.split(os.environ.get("TEST_SH", "/bin/sh")), "-e", "-c", block], env=env, cwd=d, capture_output=True, text=True)
        log = pathlib.Path(d, "log").read_text() if pathlib.Path(d, "log").exists() else ""
        return r.returncode, log


rc, log = run("ok", "attached")
assert rc == 0 and "disable fac OLDKEY" in log, (rc, log)
assert "disable fac NEWKEY" not in log and "disable fac OTHER" not in log, log
rc, log = run("already", "attached")  # re-sync: attach errors, user already has the policy
assert rc == 0, (rc, log)
rc, log = run("already", "extra")  # a different policy that merely starts with the name
assert rc != 0, (rc, log)
rc, log = run("already", "prefixed")  # other-aifactory-sts must not satisfy the check
assert rc != 0, (rc, log)
rc, log = run("already", "readonly")  # the name appears in AccessKey, not PolicyName
assert rc != 0, (rc, log)
rc, log = run("ok", "attached", LISTFAIL="1")  # rotation clean-up failing must not fail the hook
assert rc == 0, (rc, log)
rc, log = run("already", "none")  # attach errors and policy absent: a real failure
assert rc != 0, (rc, log)
print("ok")
