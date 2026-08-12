#!/usr/bin/env python3
"""Assert every mutate rule is idempotent, by applying it to its own output.

factory-gitops#166. Kyverno's resource mutating webhook is registered
`reinvocationPolicy: IfNeeded`, so the API server calls Kyverno AGAIN whenever
another webhook alters the object in the same admission -- and a mutate rule
then sees an object its own patch has already been applied to. A rule whose
patch is not idempotent applies twice.

`kyverno test` applies each rule ONCE. It never simulates the second pass, so
this class is structurally invisible to the gates built in #143/#145/#148.

MEASURED, ON THE RULE THAT HIT IT. `inject-netpol-gate` patches
`/spec/initContainers/0` with a JSON Patch `add`, which is not idempotent.
With its guarding precondition removed the whole offline chain stayed green --
`Test Summary: 8 tests passed and 0 tests failed`, every REASON `Ok` rather
than `Excluded`, so #148's guard does not see it either -- while the live
webhook rejected the pod outright:

    The Pod "t517-dbg" is invalid: spec.initContainers[1].name:
      Duplicate value: "netpol-gate"

Deterministic, not a race. Shipped, that is every task pod in the fleet failing
admission, green in CI the whole way.

HOW THIS CHECKS IT

The second-pass input is already committed as the expected output: each mutate
result in a suite carries a `patchedResources` file. So feed that file back in
as the resource and assert the rule has nothing left to do. No new fixtures.

    kyverno apply <policy> --resource <patchedResources> --policy-report

gives one row per rule per resource. Idempotent:

    result: skip
    rule: inject-netpol-gate
    message: preconditions not met

Non-idempotent, on the same file with the precondition removed:

    result: pass
    rule: inject-netpol-gate

TWO CONSTRAINTS, BOTH LOAD-BEARING, BOTH FROM #166

1. ABSENCE MUST BE A FAILURE. A mutate rule whose suite contributes no
   `patchedResources` makes the second pass iterate zero times and report
   success having asserted nothing -- #117 and #148 rebuilt inside their own
   fix. So the mutate rules are enumerated FIRST, from the policies, and a rule
   with no patched resources is an error. The same applies one level down: a
   rule that produced no row in the second pass never evaluated, and an empty
   row set is an error rather than a vacuous pass.

2. SECOND PASS ONLY, NO CONVERGENCE LOOP. Under `IfNeeded` the API server
   reinvokes a webhook at most one additional time, so a patch can be applied
   at most twice. Iterating to a fixed point would be strictly more code
   proving strictly nothing more.

WHAT THIS DOES NOT CATCH, so a green tick is not over-read:
  - A mutate rule that is non-idempotent only on a resource shape no suite
    contains. This tests the committed fixtures, not all inputs.
  - Interaction between two mutate rules across the reinvocation -- rule A's
    second-pass output feeding rule B. Both rules are applied together here,
    which covers the ordinary case, but not an ordering the CLI does not model.
  - Anything about the OTHER two mutating webhook configurations. #166 records
    two unverified claims about `kyverno-policy-mutating-webhook-cfg`
    (`reinvocationPolicy: IfNeeded` and `failurePolicy: Fail`); if both hold, a
    non-idempotent mutate rule against ClusterPolicy objects would fail CLOSED.
    Re-measure before writing one.

Run it directly -- `python3 apps/kyverno-policies/assert-mutate-idempotent.py`
from the repo root. Needs yq and the same pinned Kyverno CLI the workflow uses.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

FAILED = False


def err(path, msg):
    global FAILED
    print(f"::error file={path}::{msg}")
    FAILED = True


def die(msg):
    print(f"::error::{msg}")
    sys.exit(1)


def run(cmd, **kw):
    # A missing binary is a gate that CANNOT DO ITS WORK, and this file's own
    # workflow header promises those are an explicit exit 1 rather than a
    # surprise ("missing tools" is the first item in that list). Without this
    # the failure is a raw FileNotFoundError traceback out of subprocess —
    # non-zero, so never unsafe, but illegible anywhere the CLI is not
    # installed, which is every developer's machine.
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False, **kw)
    except FileNotFoundError:
        die(f"`{cmd[0]}` is not on PATH — this check needs it and cannot "
            f"report anything without it. Install it (the workflow pins the "
            f"same version) and re-run.")


def yq(expr, path):
    out = run(["yq", "-r", expr, path])
    if out.returncode != 0:
        die(f"yq failed on {path}: {out.stderr.strip()}")
    return out.stdout


def discover(api_prefix, kind_re):
    """Find files by CONTENT, not by path -- #117's lesson, as everywhere else here.

    A mutate rule added in a file this misses would be invisible to the check
    rather than merely unchecked, which is the failure mode being fixed.
    """
    files = run(["git", "ls-files", "-z", "*.yaml", "*.yml"]).stdout.split("\0")
    found = []
    for f in files:
        if not f:
            continue
        head = open(f, encoding="utf-8", errors="replace").read()
        if not re.search(rf'^apiVersion:[ \t]*"?{api_prefix}', head, re.M):
            continue
        if not re.search(kind_re, head, re.M):
            continue
        found.append(f)
    return sorted(found)


def main():
    # `.git` is a FILE in a worktree and a directory in a normal clone.
    if not os.path.exists(".git"):
        die("run this from the repository root")

    policies = discover(r"kyverno\.io/", r'^kind:[ \t]*"?(Cluster)?Policy"?[ \t]*$')
    if not policies:
        die("no Kyverno policy discovered -- this check validated nothing (#166)")

    # (policy name, rule name) -> policy file. Enumerated from the POLICIES, so
    # a mutate rule with no test coverage is a failure below rather than an
    # absence nobody notices. This is constraint 1.
    mutate = {}
    for f in policies:
        name = yq(".metadata.name", f).strip()
        rules = json.loads(
            yq('[.spec.rules[] | select(has("mutate")) | .name] | tojson', f)
        )
        for r in rules:
            mutate[(name, r)] = f

    if not mutate:
        die(
            "no mutate rule discovered -- this repo HAS mutate rules "
            "(gate-task-pods-on-network-policy, "
            "strip-last-applied-configuration-from-secrets), so finding none "
            "means discovery broke, not that there is nothing to check (#166)"
        )
    print(f"discovered {len(mutate)} mutate rule(s) across {len(policies)} policy file(s)")

    suites = discover(r"cli\.kyverno\.io/", r'^kind:[ \t]*"?Test"?[ \t]*$')
    if not suites:
        die("no Kyverno test suite discovered -- there is no second-pass input (#166)")

    # (policy, rule) -> set of patchedResources paths, resolved against the suite dir.
    patched = {}
    for s in suites:
        entries = json.loads(
            yq(
                '[.results[] | select(has("patchedResources")) '
                '| {"policy": .policy, "rule": .rule, "patched": .patchedResources}] | tojson',
                s,
            )
        )
        for e in entries:
            p = os.path.normpath(os.path.join(os.path.dirname(s), e["patched"]))
            patched.setdefault((e["policy"], e["rule"]), set()).add(p)

    # Constraint 1: absence is a failure, not zero iterations reported as success.
    pairs = set()
    for (policy, rule), pfile in sorted(mutate.items()):
        files = patched.get((policy, rule))
        if not files:
            err(
                pfile,
                f"mutate rule `{rule}` contributes no `patchedResources` to any test "
                "suite, so the idempotency second pass would iterate zero times and "
                "report success having asserted nothing. Add a case that asserts what "
                "this rule produces (#166)",
            )
            continue
        for pf in sorted(files):
            if not os.path.exists(pf):
                err(pfile, f"`{rule}` names patchedResources `{pf}`, which does not exist (#166)")
                continue
            docs = [d for d in yq("[.kind] | .[]", pf).split() if d]
            if not docs:
                err(
                    pf,
                    f"the patchedResources for `{rule}` holds no resource -- the second "
                    "pass would run against nothing (#166)",
                )
                continue
            pairs.add((pfile, pf))

    for pfile, pf in sorted(pairs):
        second_pass(pfile, pf)

    if FAILED:
        return 1
    print(f"ok  every mutate rule is a no-op on its own patchedResources ({len(pairs)} pair(s))")
    return 0


def second_pass(policy_file, patched_file):
    """Apply the policy to its own output and assert every mutate rule skips."""
    with tempfile.TemporaryDirectory() as td:
        # #175: the pinned CLI segfaults on spec.webhookConfiguration.matchConditions,
        # so strip it from a COPY. Done here rather than relying on the workflow's
        # strip step so this script is runnable on its own -- a check that only
        # works in one step ordering is a check nobody re-runs. Costs no coverage:
        # the CLI does not generate webhook configurations.
        copy = os.path.join(td, os.path.basename(policy_file))
        shutil.copy(policy_file, copy)
        subprocess.run(
            ["yq", "-i", "del(.spec.webhookConfiguration.matchConditions)", copy],
            check=True,
        )
        out = run(
            [
                "kyverno", "apply", copy,
                "--resource", patched_file,
                "--policy-report",
                "--output-format", "json",
            ]
        )
        rows = extract_rows(out.stdout)
        if rows is None:
            err(
                policy_file,
                f"the idempotency second pass against {patched_file} produced no policy "
                "report at all -- v1.18.2 emits none when no rule matched anything, so "
                f"every mutate rule in this policy went unevaluated and this check "
                f"asserted nothing (rc={out.returncode}). {out.stderr.strip()[:400]} (#166)",
            )
            return

        policy_name = yq(".metadata.name", policy_file).strip()
        rule_names = json.loads(
            yq('[.spec.rules[] | select(has("mutate")) | .name] | tojson', policy_file)
        )
        for rule in rule_names:
            mine = [r for r in rows if r[0] == policy_name and r[1] == rule]
            # Constraint 1, one level down. No row means the rule never evaluated
            # the patched resources, and a check that asserted nothing must not
            # report success.
            if not mine:
                err(
                    policy_file,
                    f"mutate rule `{rule}` produced NO result on the second pass against "
                    f"{patched_file} -- it never evaluated those resources, so this check "
                    "asserted nothing about it (#166)",
                )
                continue
            for _, _, resource, result in mine:
                if result != "skip":
                    err(
                        policy_file,
                        f"mutate rule `{rule}` returned `{result}` when re-applied to its own "
                        f"output ({resource} in {patched_file}) -- it is NOT idempotent. The "
                        "resource mutating webhook is registered reinvocationPolicy: IfNeeded, "
                        "so the API server calls Kyverno again in the same admission and this "
                        "patch is applied twice. Shipped, that is every matched pod failing "
                        "admission (#166)",
                    )


def extract_rows(text):
    """(policy, rule, resource, result) out of `kyverno apply --policy-report`.

    The CLI prints every mutated resource as YAML and then the report as one
    line of JSON with no separator, so the JSON is located rather than split
    out. Returns None -- never an empty list -- when there is no report to read,
    because "found nothing" and "asserted nothing" must not look alike here.
    """
    # Every candidate is tried in order rather than taking the last `{"kind":`,
    # which is a nested `{"kind":"Pod"...}` inside `resources` and decodes to a
    # fragment. Guessing the report's own kind by name would break the day the
    # CLI renames it -- v1.18.2 already emits `ClusterReport`, not the
    # `ClusterPolicyReport` the flag help implies.
    decoder = json.JSONDecoder()
    for m in re.finditer(r'\{"kind":', text):
        try:
            report, _ = decoder.raw_decode(text, m.start())
        except json.JSONDecodeError:
            continue
        if not isinstance(report, dict) or "results" not in report:
            continue
        rows = []
        for r in report.get("results") or []:
            for res in r.get("resources") or [{}]:
                rows.append((r.get("policy"), r.get("rule"), res.get("name"), r.get("result")))
        # An EMPTY list is returned deliberately, not None: a report that ran
        # and produced no row for a rule is the per-rule guard's business
        # below, and it has the message that says which rule went unevaluated.
        return rows
    return None


if __name__ == "__main__":
    sys.exit(main())
