#!/usr/bin/env python3
"""Assert the three hand-maintained copies of "which images are signature-covered" agree.

factory-gitops#181. Narrowing an `imageReferences` glob in
verify-factory-image-signatures makes the rule stop speaking about an image
SILENTLY: the result is not a `fail`, it is nothing at all. Measured twice on
one day, on two different rules, by two people who had not compared notes:

    verify-tfactory-runner-signature   tfactory-runner-*  ->  tfactory-runner-pytest:*
      pass: 0, fail: 0, warn: 0, error: 0, skip: 0
    verify-odin-signature              odin:*             ->  odin:v*
      pass: 0, fail: 0

Nothing in this repo went red for either. The signature suite is all-negative
by design, so narrowing a glob makes its cases MORE true; #148's rule
inventory catches a rule RENAMED or DELETED, not one narrowed; and the two
off-CI channels each read a DIFFERENT hand-maintained copy of the same fact:

  1. the `imageReferences` globs               verify-factory-image-signatures
  2. the `uncovered` jmesPath alternation      require-first-party-signature-coverage
  3. the probe's DEFAULT_IMAGES list           apps/kyverno-runner-probe

Three copies, no comparison. #181 records the compensating control that was
believed to hold and does not: narrow a glob and drop the probe entry in the
same commit and every channel is silent again.

WHAT THIS ASSERTS, AND WHY EACH DIRECTION MATTERS

  A. Each coverage rule's mirror equals the signature globs that run in each
     of its namespaces, after normalising `ghcr.io/olafkfreund/X*` -> `X`.
     The coverage policy's header states the correspondence: `aifactory:*`
     <-> `aifactory:` and `tfactory-runner-*` <-> `tfactory-runner-`.

  B. Every image the probe dry-runs is named by at least one glob. This is
     the half that survives "narrow the glob AND edit the mirror": the probe
     is a third copy written in a different language for a different purpose,
     and it still has to agree.

  C. The probe's COVERAGE_CANARY is named by NO glob. The canary exists to
     catch a glob WIDENED to something like `ghcr.io/olafkfreund/*`, which
     manufactures coverage without any. Asserting it here means the canary's
     contract is checked in CI and not only in the six-hourly probe run.

  D. Every required namespace and every signature rule's namespace has a
     coverage rule, so a removed mirror cannot silently escape A.

NO NETWORK. This is three text comparisons. The reason the obvious fix -- a
positive `kyverno test` case on a matched image -- was declined twice (#149,
#148) is that a matched image reference sends the CLI to ghcr.io, putting a
third-party registry inside a required status check. Nothing here resolves an
image.

THE CEILING, STATED SO NOBODY READS A GREEN TICK AS MORE THAN IT IS: this
compares lists only; `kyverno test` proves that each rule actually denies.
A glob narrowed in all three copies in one commit passes. That is a
deliberate, reviewable change and it should pass.

Run it directly -- `python3 apps/kyverno-policies/assert-signature-lists-agree.py`
from the repo root -- it needs only yq and prints the same annotations CI does.
"""

import fnmatch
import json
import os
import re
import subprocess
import sys

REPO_PREFIX = "ghcr.io/olafkfreund/"
REQUIRED_NAMESPACES = {"factory", "gateway", "fides", "fides-reporter"}
PREFIX = re.compile(r"^[a-z0-9-]+[:@]?$")
NAMESPACE = re.compile(r"^[a-z0-9-]+$")
VERIFY_KEYS = {"imageReferences", "verifyDigest", "mutateDigest", "required",
               "useCache", "attestors"}

SIGNATURES = "apps/kyverno-policies/manifests/verify-factory-image-signatures.yaml"
COVERAGE = "apps/kyverno-policies/manifests/require-first-party-signature-coverage.yaml"
PROBE = "apps/kyverno-runner-probe/manifests/manifests.yaml"


def yq(expr, path):
    """Read structure out of YAML with the same pinned yq the workflow installs.

    A grep is not a parser, and #148 already had to learn that these files use
    anchors and aliases. Missing yq is a hard failure, not a skip: a check that
    quietly does nothing is the defect this file exists to close.
    """
    if not os.path.exists(path):
        die(f"{path} does not exist -- this check cannot compare what it cannot read")
    out = subprocess.run(
        ["yq", "-r", expr, path], capture_output=True, text=True, check=False
    )
    if out.returncode != 0:
        die(f"yq failed on {path}: {out.stderr.strip()}")
    return out.stdout


FAILED = False


def err(path, msg):
    global FAILED
    print(f"::error file={path}::{msg}")
    FAILED = True


def die(msg):
    print(f"::error::{msg}")
    sys.exit(1)


def scope(path, rule, allowed_keys):
    """Return literal Pod namespaces only for the match shape this checker models."""
    name = rule.get("name", "<unnamed>")
    match = rule.get("match")
    if (not set(rule) <= allowed_keys or not isinstance(match, dict)
            or set(match) != {"any"}):
        err(path, f"rule {name} has unsupported keys or match shape")
        return None
    clauses = match["any"]
    if not isinstance(clauses, list) or not clauses:
        err(path, f"rule {name} must have a non-empty match.any list")
        return None
    namespaces = set()
    for clause in clauses:
        if not isinstance(clause, dict) or set(clause) != {"resources"}:
            err(path, f"rule {name} has an unsupported match.any entry")
            return None
        resources = clause["resources"]
        if not isinstance(resources, dict) or set(resources) != {"kinds", "namespaces"}:
            err(path, f"rule {name} has unsupported match.resources keys")
            return None
        values = resources["namespaces"]
        if (resources["kinds"] != ["Pod"] or not isinstance(values, list)
                or not values or any(
                    not isinstance(n, str) or not NAMESPACE.fullmatch(n)
                    for n in values
                )):
            err(path, f"rule {name} must match Pod and literal, non-empty namespaces")
            return None
        namespaces.update(values)
    return namespaces


def globs():
    """Signature rules with their namespaces and normalised glob prefixes."""
    rules = json.loads(yq(".spec.rules | tojson", SIGNATURES))
    found = []
    for rule in rules:
        if "verifyImages" not in rule:
            continue
        namespaces = scope(SIGNATURES, rule, {"name", "match", "verifyImages"})
        if namespaces is None:
            continue
        prefixes = {}
        for verify in rule["verifyImages"]:
            # A skip list or `required: false` would leave a mirrored image unchecked.
            if not set(verify) <= VERIFY_KEYS or verify.get("required") is not True:
                err(SIGNATURES, f"rule {rule.get('name')} has a verifyImages entry with "
                    "unsupported keys or without `required: true` (#3665)")
                continue
            for g in verify.get("imageReferences", []):
                if not isinstance(g, str) or not g.startswith(REPO_PREFIX):
                    err(SIGNATURES, f"glob {g} is not under {REPO_PREFIX} (#181)")
                    continue
                tail = g[len(REPO_PREFIX):]
                if (not tail.endswith("*") or "*" in tail[:-1]
                        or not PREFIX.fullmatch(tail[:-1])):
                    err(SIGNATURES, f"glob {g} is not a literal prefix with one trailing * (#181)")
                    continue
                prefixes[tail[:-1]] = g
        found.append((rule.get("name", "<unnamed>"), namespaces, prefixes))
    if not any(prefixes for _, _, prefixes in found):
        die(f"no imageReferences glob found in {SIGNATURES} -- this check compared nothing (#181)")
    return found


def mirror():
    """Coverage rules with their namespaces and mirror alternations."""
    rules = json.loads(yq(".spec.rules | tojson", COVERAGE))
    found = []
    for rule in rules:
        contexts = rule.get("context") or []
        uncovered = [c for c in contexts if c.get("name") == "uncovered"]
        if not uncovered:
            continue
        namespaces = scope(
            COVERAGE, rule, {"name", "match", "context", "preconditions", "validate"}
        )
        if namespaces is None:
            continue
        for context in uncovered:
            expr = (context.get("variable") or {}).get("jmesPath", "")
            m = re.search(r"!regex_match\('\^ghcr\\\.io/olafkfreund/\(([^)]*)\)'", expr)
            if not m:
                die(
                    f"could not read the covered-image alternation in rule "
                    f"{rule['name']} of {COVERAGE} (#181)"
                )
            entries = m.group(1).split("|")
            if any(not PREFIX.fullmatch(e) for e in entries):
                err(COVERAGE, f"rule {rule['name']} has an invalid covered-image prefix")
            found.append((rule["name"], namespaces, set(entries)))
    if not found:
        die(f"no uncovered context variable found in {COVERAGE} -- this check compared nothing (#181)")
    return found


def probe():
    """DEFAULT_IMAGES and COVERAGE_CANARY out of the probe's embedded python."""
    src = yq('select(.kind == "ConfigMap") | .data["probe.py"]', PROBE)
    if not src.strip():
        die(f"could not read probe.py out of {PROBE} -- this check compared nothing (#181)")
    block = re.search(r'DEFAULT_IMAGES\s*=\s*"""(.*?)"""', src, re.S)
    if not block:
        die(f"could not read DEFAULT_IMAGES out of {PROBE} (#181)")
    images = [i for i in block.group(1).split() if i]
    if not images:
        die(f"DEFAULT_IMAGES in {PROBE} is empty -- the probe dry-runs nothing (#181)")
    canary = re.search(r'COVERAGE_CANARY\s*=\s*"([^"]+)"', src)
    if not canary:
        die(f"could not read COVERAGE_CANARY out of {PROBE} (#181)")
    return images, canary.group(1)


def main():
    # `.git` is a FILE in a worktree and a directory in a normal clone.
    if not os.path.exists(".git"):
        die("run this from the repository root")

    signatures = globs()
    coverage = mirror()
    images, canary = probe()
    prefixes = {prefix: glob for _, _, rule_globs in signatures
                for prefix, glob in rule_globs.items()}

    # A. each mirror matches the signature rules running in its namespaces.
    for name, namespaces, covered in coverage:
        for namespace in sorted(namespaces):
            expected = {prefix for _, scoped, rule_globs in signatures
                        if namespace in scoped for prefix in rule_globs}
            for missing in sorted(covered - expected):
                err(COVERAGE, f"rule {name} in namespace {namespace} mirrors {missing} "
                    "but admission has no signature glob for it (#181)")
            for extra in sorted(expected - covered):
                err(COVERAGE, f"rule {name} in namespace {namespace} is missing "
                    f"{extra} from the signature globs (#181)")

    # D. a missing coverage rule must not make A vacuously true.
    signature_namespaces = set().union(*(scoped for _, scoped, _ in signatures))
    coverage_namespaces = set().union(*(scoped for _, scoped, _ in coverage))
    for namespace in sorted(
        (REQUIRED_NAMESPACES | signature_namespaces) - coverage_namespaces
    ):
        err(COVERAGE, f"namespace {namespace} has no coverage rule (#3665)")

    # B. every probed image is named by some glob.
    # ponytail: fnmatch, not Kyverno's globbing. These patterns are a literal
    # prefix plus one trailing `*`, where the two agree exactly. Swap it if a
    # glob ever needs a `?` or a character class -- globs() refuses those today.
    for image in images:
        if not any(fnmatch.fnmatchcase(image, g) for g in prefixes.values()):
            err(
                PROBE,
                f"the probe dry-runs `{image}` but no imageReferences glob in "
                f"{SIGNATURES} names it -- a glob was narrowed and this image is now "
                "admitted unverified (#181)",
            )

    # C. the canary is named by nothing.
    hit = [g for g in prefixes.values() if fnmatch.fnmatchcase(canary, g)]
    if hit:
        err(
            SIGNATURES,
            f"glob {hit[0]} matches the probe's COVERAGE_CANARY `{canary}` -- a glob "
            "has been widened until it manufactures coverage without verifying "
            "anything (Factory#564, #181)",
        )

    if FAILED:
        return 1
    print(
        f"ok  {len(prefixes)} signature glob(s), {len(signatures)} signature rule(s), "
        f"{len(coverage)} coverage rule(s), {len(coverage_namespaces)} namespace(s) agree; "
        f"all {len(images)} probed image(s) are named by one; the canary is named by none"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
