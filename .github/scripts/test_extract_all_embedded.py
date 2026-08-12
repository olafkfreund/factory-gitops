"""The extractor must actually extract, and what it extracts must be Python.

The whole value of the CodeQL job depends on this step producing files. If it
silently produced none, CodeQL would scan an empty directory, report zero
alerts, and factory-gitops would carry a green security badge over 400 KB of
unscanned in-cluster code -- a worse state than having no badge at all
(Factory#711).
"""

from __future__ import annotations

import ast
import pathlib
import subprocess
import sys

_SCRIPTS = pathlib.Path(__file__).resolve().parent


def _run(outdir: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603
        [sys.executable, str(_SCRIPTS / "extract_all_embedded.py"), str(outdir)],
        capture_output=True,
        text=True,
        check=False,
        cwd=str(_SCRIPTS),
    )


def test_it_extracts_every_embedded_program(tmp_path: pathlib.Path) -> None:
    out = _run(tmp_path)
    assert out.returncode == 0, out.stderr
    produced = sorted(tmp_path.glob("*.py"))
    # One per `<name>.py: |` block in apps/*/manifests/*.yaml. A drop here means
    # an app stopped being scanned -- which is the regression worth catching.
    assert len(produced) >= 13, f"only extracted {len(produced)}: {[p.name for p in produced]}"


def test_everything_extracted_is_parseable_python(tmp_path: pathlib.Path) -> None:
    _run(tmp_path)
    for path in sorted(tmp_path.glob("*.py")):
        ast.parse(path.read_text())  # raises SyntaxError if the block was mangled


def test_the_known_critical_watchdogs_are_covered(tmp_path: pathlib.Path) -> None:
    """Named explicitly: these run with cluster credentials."""
    _run(tmp_path)
    names = {p.name for p in tmp_path.glob("*.py")}
    for expected in (
        "job-watchdog__watchdog.py",
        "restart-watchdog__watchdog.py",
        "cred-broker__refresh.py",
        "endpoint-guard__guard.py",
    ):
        assert expected in names, f"{expected} missing — that app would go unscanned"


def test_extracting_nothing_is_a_failure_not_a_pass(tmp_path: pathlib.Path) -> None:
    """Point the extractor at a tree with no manifests; it must exit non-zero."""
    empty = tmp_path / "empty-repo" / ".github" / "scripts"
    empty.mkdir(parents=True)
    for helper in ("extract_all_embedded.py", "extract_embedded_script.py"):
        (empty / helper).write_text((_SCRIPTS / helper).read_text())
    out = subprocess.run(  # noqa: S603
        [sys.executable, str(empty / "extract_all_embedded.py"), str(tmp_path / "out")],
        capture_output=True,
        text=True,
        check=False,
        cwd=str(empty),
    )
    assert out.returncode == 1, f"expected exit 1, got {out.returncode}: {out.stdout}"
    assert "refusing" in out.stderr
