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

  A. The glob set and the mirror alternation are the SAME set, after
     normalising `ghcr.io/olafkfreund/X*` -> `X`. That normalisation is not a
     convenience: the coverage policy's own header states the correspondence
     ("the covered patterns end in a literal `:` where the rule they mirror
     ends in `:*`"), so `aifactory:*` <-> `aifactory:` and
     `tfactory-runner-*` <-> `tfactory-runner-`. All three narrowings quoted
     above break this equality and go red here.

  B. Every image the probe dry-runs is named by at least one glob. This is
     the half that survives "narrow the glob AND edit the mirror": the probe
     is a third copy written in a different language for a different purpose,
     and it still has to agree.

  C. The probe's COVERAGE_CANARY is named by NO glob. The canary exists to
     catch a glob WIDENED to something like `ghcr.io/olafkfreund/*`, which
     manufactures coverage without any. Asserting it here means the canary's
     contract is checked in CI and not only in the six-hourly probe run.

NO NETWORK. This is three text comparisons. The reason the obvious fix -- a
positive `kyverno test` case on a matched image -- was declined twice (#149,
#148) is that a matched image reference sends the CLI to ghcr.io, putting a
third-party registry inside a required status check. Nothing here resolves an
image.

THE CEILING, STATED SO NOBODY READS A GREEN TICK AS MORE THAN IT IS: a glob
narrowed in all three copies in one commit passes. That is a deliberate,
reviewable change and it should pass. What cannot happen any more is one copy
moving on its own.

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


def globs():
    """The `imageReferences` globs, normalised to the literal prefix each names."""
    raw = json.loads(
        yq("[.spec.rules[].verifyImages[]?.imageReferences[]?] | tojson", SIGNATURES)
    )
    if not raw:
        die(
            f"no imageReferences glob found in {SIGNATURES} -- "
            "this check compared nothing (#181)"
        )
    prefixes = {}
    for g in raw:
        if not g.startswith(REPO_PREFIX):
            err(
                SIGNATURES,
                f"glob `{g}` is not under {REPO_PREFIX} -- this check only models "
                "first-party globs and cannot speak about it (#181)",
            )
            continue
        tail = g[len(REPO_PREFIX):]
        # Only a single trailing `*` is normalisable to a literal prefix. A `*`
        # anywhere else would make the mirror comparison meaningless, and a
        # comparison that silently means nothing is exactly #181.
        if not tail.endswith("*") or "*" in tail[:-1]:
            err(
                SIGNATURES,
                f"glob `{g}` does not have exactly one trailing `*` -- it cannot be "
                "compared with the coverage mirror, so adding it would make this "
                "check silent about it (#181)",
            )
            continue
        prefixes[tail[:-1]] = g
    return prefixes


def mirror():
    """The alternation inside require-first-party-signature-coverage's jmesPath."""
    expr = yq(
        '[.spec.rules[].context[]? | select(.name == "uncovered") | .variable.jmesPath] | .[]',
        COVERAGE,
    ).strip()
    if not expr:
        die(
            f"no `uncovered` context variable found in {COVERAGE} -- "
            "this check compared nothing (#181)"
        )
    # The negative half: `[?!regex_match('^ghcr\.io/olafkfreund/(a|b|c)', @)]`
    m = re.search(
        r"!regex_match\('\^ghcr\\\.io/olafkfreund/\(([^)]*)\)'", expr
    )
    if not m:
        die(
            f"could not read the covered-image alternation out of {COVERAGE} -- "
            "the jmesPath changed shape and this check can no longer compare it (#181)"
        )
    entries = [e for e in m.group(1).split("|") if e]
    if not entries:
        die(f"the covered-image alternation in {COVERAGE} is empty (#181)")
    return set(entries)


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

    prefixes = globs()
    covered = mirror()
    images, canary = probe()

    # A. glob set == mirror set.
    for missing in sorted(covered - set(prefixes)):
        err(
            COVERAGE,
            f"`{missing}` is in the coverage mirror but NO imageReferences glob in "
            f"{SIGNATURES} names it -- this rule reports that image as covered when "
            "admission never checks its signature (#181)",
        )
    for extra in sorted(set(prefixes) - covered):
        err(
            SIGNATURES,
            f"glob `{prefixes[extra]}` has no `{extra}` entry in the coverage mirror "
            f"in {COVERAGE} -- the two lists have drifted and one of them is lying (#181)",
        )

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
        f"ok  {len(prefixes)} signature glob(s) agree with the coverage mirror; "
        f"all {len(images)} probed image(s) are named by one; the canary is named by none"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
