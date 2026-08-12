#!/usr/bin/env python3
"""Lift every embedded Python block out of the manifests so a scanner can see it.

factory-gitops has no CodeQL analysis at all, and adding one that scans the
tree as-is would be worse than useless: the only ``.py`` FILES here are eight CI
helpers under ``.github/scripts``. The code that actually runs in the cluster --
the watchdogs, cred-broker/cred-sync, endpoint-guard, evidence-collector -- lives
as block scalars inside ``manifests.yaml``. CodeQL sees those as YAML strings and
reports nothing, which would produce a green badge over unscanned production
code. That is the failure mode recorded in Factory#711.

So the scan runs against extracted copies. This walks every
``apps/*/manifests/*.yaml``, finds each ``<name>.py: |`` block scalar, and writes
it to ``<outdir>/<app>__<name>.py``. The name keeps the app in it so an alert
path points back at the app it came from.

Reuses ``extract_embedded_script.extract`` rather than reimplementing the block
parser -- that function already treats a missing key as a failure rather than a
pass, and one parser is one place to fix.

    extract_all_embedded.py <outdir>

Exit 1 if it extracts nothing at all: an empty output directory would mean the
scan silently covers zero files, which is the exact outcome this exists to stop.
"""

from __future__ import annotations

import pathlib
import re
import sys

from extract_embedded_script import extract

# `  refresh.py: |` / `  refresh.py: |-` -- the key names the file it becomes.
_KEY = re.compile(r"^\s+([A-Za-z0-9_.-]+\.py):\s*\|")

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)  # noqa: T201 - usage on stderr
        return 2
    outdir = pathlib.Path(argv[1])
    outdir.mkdir(parents=True, exist_ok=True)

    written = 0
    for manifest in sorted(_REPO_ROOT.glob("apps/*/manifests/*.yaml")):
        app = manifest.parent.parent.name
        keys = [
            m.group(1) for line in manifest.read_text().splitlines() if (m := _KEY.match(line))
        ]
        for key in sorted(set(keys)):
            try:
                body = extract(manifest, key)
            except (SystemExit, ValueError) as exc:  # extractor treats absence as fatal
                print(f"  SKIP {app}/{key}: {exc}", file=sys.stderr)  # noqa: T201
                continue
            dest = outdir / f"{app}__{key}"
            dest.write_text(body)
            print(f"  extracted {app}/{key} -> {dest.name} ({len(body)} bytes)")  # noqa: T201
            written += 1

    print(f"extracted {written} embedded Python program(s)")  # noqa: T201
    if written == 0:
        print(  # noqa: T201
            "FAILED: extracted nothing. Either the manifests stopped embedding "
            "Python, or the block-scalar shape changed. Scanning an empty "
            "directory would report clean over unscanned code -- refusing.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
