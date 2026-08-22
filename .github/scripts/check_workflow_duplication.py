#!/usr/bin/env python3
"""Detect a wholesale-copied GitHub Actions workflow within one repository.

Factory#842. `.jscpd.json` had to stop counting `.github/workflows/**` (#836 /
PR #840): bounding every job with `timeout-minutes` pushed three pairs of
Actions *preamble* over jscpd's 50-token floor, and that preamble is
byte-identical BY POLICY -- `pin-freshness.yml` requires every workflow to name
the same action digest, so any two jobs that both check out and both set up
Python must match line for line. There is no extraction that removes it.

The cost recorded in #842 is that jscpd would have caught somebody duplicating
`codeql.yml` into `codeql-2.yml` and editing one line, and nothing else looks
for that. `security-fork-drift.yml` and the `factory-*-drift.yml` gates compare
named files ACROSS repos; none compares two workflows WITHIN one repo.

This closes that hole without re-opening the false positives, by comparing what
the author actually wrote rather than the whole file:

* **Boilerplate is discounted, not ignored.** Any normalised line appearing in
  three or more workflows is preamble by definition here (`runs-on:`,
  `steps:`, a pinned `uses:`, `timeout-minutes:`). Two workflows sharing only
  those are not a copy. Lines are counted, not merely membership-tested, so a
  file cannot dodge the check by repeating one distinctive line.
* **The threshold is deliberately high.** This looks for a WHOLESALE copy --
  the #842 scenario is "duplicate and edit one line", which measures 97% on
  this repo's own `codeql.yml`. Anything much lower would re-file the preamble
  pairs the exclusion was made to silence.

Measured, so the guarantee is not overstated: the threshold is what actually
keeps the #842 pairs quiet. Setting BOILERPLATE_MIN_FILES to 9999 -- discounting
nothing at all -- still leaves every pair in this repo under the threshold. The
discounting is defence in depth for repos with larger families of near-identical
jobs, not the load-bearing part here.

Fails loudly rather than reporting clean when it cannot measure: an empty
workflow directory, or a run where every file was discounted to nothing, is a
finding. A duplication gate that examined zero comparable lines looks exactly
like a duplication gate that found nothing.
"""

from __future__ import annotations

import argparse
import itertools
import re
import sys
from collections import Counter
from pathlib import Path

#: A line has to appear in at least this many workflows to count as boilerplate.
BOILERPLATE_MIN_FILES = 3

#: Share of distinctive lines two workflows must have in common to be a finding.
SIMILARITY_THRESHOLD = 0.90

#: Below this many distinctive lines a file is too small to judge.
MIN_DISTINCTIVE_LINES = 8

_COMMENT = re.compile(r"^\s*#")


def _normalise(text: str) -> list[str]:
    """Comment-free, indentation-free, blank-free lines."""
    out = []
    for raw in text.splitlines():
        if _COMMENT.match(raw):
            continue
        line = raw.strip()
        if line:
            out.append(line)
    return out


def _boilerplate(files: dict[Path, list[str]]) -> set[str]:
    """Lines shared by BOILERPLATE_MIN_FILES or more workflows."""
    seen: Counter[str] = Counter()
    for lines in files.values():
        seen.update(set(lines))
    return {line for line, n in seen.items() if n >= BOILERPLATE_MIN_FILES}


def _similarity(a: Counter[str], b: Counter[str]) -> float:
    """Fraction of the SMALLER file's distinctive lines also in the larger.

    Asymmetric on purpose: a copy that had lines appended is still a copy, and
    dividing by the union would let padding hide it.
    """
    smaller, larger = (a, b) if sum(a.values()) <= sum(b.values()) else (b, a)
    total = sum(smaller.values())
    if not total:
        return 0.0
    shared = sum(min(n, larger[line]) for line, n in smaller.items())
    return shared / total


def check(workflow_dir: Path, counts: dict[str, int] | None = None) -> list[str]:
    paths = sorted(p for p in workflow_dir.glob("*.yml")) + sorted(workflow_dir.glob("*.yaml"))
    if not paths:
        return [f"{workflow_dir}: no workflow files found -- this gate examined nothing"]

    files = {p: _normalise(p.read_text(encoding="utf-8", errors="replace")) for p in paths}
    boiler = _boilerplate(files)
    distinctive = {
        p: Counter(line for line in lines if line not in boiler) for p, lines in files.items()
    }

    judgeable = {p: c for p, c in distinctive.items() if sum(c.values()) >= MIN_DISTINCTIVE_LINES}
    if counts is not None:
        counts["workflows"] = len(paths)
        counts["judgeable"] = len(judgeable)
        counts["pairs"] = len(judgeable) * (len(judgeable) - 1) // 2
        counts["boilerplate_lines"] = len(boiler)
    if not judgeable:
        return [
            f"{workflow_dir}: all {len(paths)} workflow(s) discounted to fewer than "
            f"{MIN_DISTINCTIVE_LINES} distinctive lines -- nothing was compared"
        ]

    findings = []
    for (pa, ca), (pb, cb) in itertools.combinations(sorted(judgeable.items()), 2):
        score = _similarity(ca, cb)
        if score >= SIMILARITY_THRESHOLD:
            findings.append(
                f"{pa.name} and {pb.name} share {score:.0%} of their distinctive "
                f"lines -- one looks like a wholesale copy of the other (Factory#842)"
            )
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=".", help="repository root")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return _self_test()

    counts: dict[str, int] = {}
    findings = check(Path(args.root) / ".github" / "workflows", counts)
    for f in findings:
        print(f"FAIL {f}")  # noqa: T201

    # The count goes to BOTH verdicts, pass and fail. A gate that says only
    # "OK" cannot be told apart from a gate that compared nothing, and the
    # empty case is the one worth catching: three of this repo's workflows are
    # under the distinctive-line floor, so "0 pairs compared" is a state this
    # gate can genuinely reach while still printing OK (Factory#832).
    summary = (
        f"Compared {counts.get('pairs', 0)} workflow pair(s) from "
        f"{counts.get('judgeable', 0)} judgeable of {counts.get('workflows', 0)} "
        f"workflow file(s), after discarding {counts.get('boilerplate_lines', 0)} "
        f"boilerplate line(s) shared by {BOILERPLATE_MIN_FILES}+ files"
    )
    if findings:
        print(summary)  # noqa: T201
        return 1
    print(f"OK: no workflow is a wholesale copy of another. {summary}.")  # noqa: T201
    return 0


def _self_test() -> int:
    """The rules, on synthetic input -- so they hold when the repo is clean."""
    # Local to the self-test so the gate itself imports nothing it does not
    # need at check time.
    import tempfile  # noqa: PLC0415

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        wf = Path(td) / ".github" / "workflows"
        wf.mkdir(parents=True)
        preamble = "name: x\non: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n"
        # three files sharing ONLY preamble must not be a finding
        for i in range(3):
            body = "\n".join(f"      - run: unique-{i}-{k}" for k in range(12))
            (wf / f"distinct{i}.yml").write_text(preamble + body)
        if check(wf):
            failures.append("workflows sharing only preamble were reported as copies")

        # a wholesale copy with one line changed must be a finding
        src = (wf / "distinct0.yml").read_text()
        (wf / "copy.yml").write_text(src.replace("unique-0-11", "unique-0-CHANGED"))
        if not check(wf):
            failures.append("a wholesale copy with one edited line was NOT reported")

    with tempfile.TemporaryDirectory() as td:
        empty = Path(td) / ".github" / "workflows"
        empty.mkdir(parents=True)
        if not check(empty):
            failures.append("an empty workflow directory must be a finding, not a pass")

    for f in failures:
        print(f"self-test FAIL: {f}")  # noqa: T201
    if failures:
        return 1
    print("self-test OK")  # noqa: T201
    return 0


if __name__ == "__main__":
    sys.exit(main())
