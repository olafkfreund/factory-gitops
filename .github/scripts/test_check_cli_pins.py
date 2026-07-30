#!/usr/bin/env python3
"""Proof, both directions, for check_cli_pins.py. Run: python3 <this file>

The important case is ABSENT -> fail. factory-gitops#90 was a gate that compared
three greps for equality and would have passed when all three matched nothing;
test_absent_pins_fail and test_all_absent_is_not_agreement are the regression
tests for exactly that. Plain asserts, no framework -- CI runs this file.
"""

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from check_cli_pins import check, main  # noqa: E402

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check_cli_pins.py")


def dockerfile(claude="2.1.215", codex="0.144.6", gemini="0.51.0"):
    """A Dockerfile fragment shaped like the real bake step; None omits a pin."""
    lines = ["FROM chainguard/python:latest-dev", "RUN npm install -g \\"]
    for pkg, version in (
        ("@anthropic-ai/claude-code", claude),
        ("@openai/codex", codex),
        ("@google/gemini-cli", gemini),
    ):
        if version is not None:
            lines.append("        %s@%s \\" % (pkg, version))
    lines.append(" && npm cache clean --force")
    return "\n".join(lines) + "\n"


def test_agreeing_pins_pass():
    agreed, errors = check([(name, dockerfile()) for name in ("AIFactory", "PFactory", "TFactory")])
    assert errors == [], errors
    assert agreed == {
        "@anthropic-ai/claude-code": "2.1.215",
        "@openai/codex": "0.144.6",
        "@google/gemini-cli": "0.51.0",
    }, agreed


def test_diverged_pins_fail():
    agreed, errors = check(
        [
            ("AIFactory", dockerfile()),
            ("PFactory", dockerfile(claude="2.1.216")),
            ("TFactory", dockerfile()),
        ]
    )
    assert agreed == {}, agreed
    assert len(errors) == 1, errors
    assert "@anthropic-ai/claude-code differs across the fleet" in errors[0], errors
    assert "PFactory=2.1.216" in errors[0] and "AIFactory=2.1.215" in errors[0], errors


def test_absent_pins_fail():
    """One repo drops a pin -- the exact drift the old gate could not see."""
    agreed, errors = check(
        [
            ("AIFactory", dockerfile()),
            ("PFactory", dockerfile(codex=None)),
            ("TFactory", dockerfile()),
        ]
    )
    assert agreed == {}, agreed
    assert errors == ["PFactory: no pinned version of @openai/codex"], errors


def test_all_absent_is_not_agreement():
    """THE #90 bug: three empty results must not compare equal-and-pass."""
    empty = "FROM chainguard/python:latest-dev\nRUN echo 'CLIs baked elsewhere'\n"
    agreed, errors = check([(name, empty) for name in ("AIFactory", "PFactory", "TFactory")])
    assert agreed == {}, agreed
    assert len(errors) == 9, errors  # 3 repos x 3 packages, every one named
    assert all("no pinned version of" in error for error in errors), errors


def test_two_versions_of_one_package_in_one_file_fail():
    text = dockerfile() + "RUN npm install -g @openai/codex@0.99.0\n"
    agreed, errors = check([("AIFactory", text), ("PFactory", dockerfile())])
    assert agreed == {}, agreed
    assert errors == ["AIFactory: @openai/codex pinned to more than one version: 0.144.6, 0.99.0"], errors


def test_single_source_cannot_be_compared():
    """A gate that cannot run must fail, not pass (rule 4.7)."""
    agreed, errors = check([("AIFactory", dockerfile())])
    assert agreed == {}, agreed
    assert errors == ["need at least two sources to compare, got 1"], errors

    agreed, errors = check([])
    assert agreed == {}, agreed
    assert errors == ["need at least two sources to compare, got 0"], errors


def test_empty_file_fails():
    """A truncated or failed download must not read as 'no drift'."""
    with tempfile.TemporaryDirectory() as tmp:
        good = os.path.join(tmp, "good")
        blank = os.path.join(tmp, "blank")
        with open(good, "w", encoding="utf-8") as handle:
            handle.write(dockerfile())
        with open(blank, "w", encoding="utf-8") as handle:
            handle.write("\n\n")
        assert main(["A=%s" % good, "B=%s" % blank]) == 2


def test_missing_file_fails():
    assert main(["A=/nonexistent/Dockerfile", "B=/nonexistent/Dockerfile"]) == 2


def test_malformed_argument_fails():
    assert main(["just-a-path"]) == 2


def test_cli_contract():
    """End to end through the real process: stdout is npm-installable, exit codes hold."""
    with tempfile.TemporaryDirectory() as tmp:
        paths = {}
        for name in ("AIFactory", "PFactory", "TFactory"):
            paths[name] = os.path.join(tmp, name)
            with open(paths[name], "w", encoding="utf-8") as handle:
                handle.write(dockerfile())
        args = ["%s=%s" % (name, path) for name, path in paths.items()]

        ok = subprocess.run(
            [sys.executable, SCRIPT] + args, capture_output=True, text=True, check=False
        )
        assert ok.returncode == 0, ok.stderr
        assert ok.stdout.split() == [
            "@anthropic-ai/claude-code@2.1.215",
            "@openai/codex@0.144.6",
            "@google/gemini-cli@0.51.0",
        ], ok.stdout

        # Same inputs, one pin removed -> non-zero, and nothing installable on stdout.
        with open(paths["TFactory"], "w", encoding="utf-8") as handle:
            handle.write(dockerfile(gemini=None))
        bad = subprocess.run(
            [sys.executable, SCRIPT] + args, capture_output=True, text=True, check=False
        )
        assert bad.returncode == 1, bad
        assert bad.stdout.strip() == "", bad.stdout
        assert "no pinned version of @google/gemini-cli" in bad.stderr, bad.stderr


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print("ok   %s" % test.__name__)
    print("\n%d passed" % len(tests))
