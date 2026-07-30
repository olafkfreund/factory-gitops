#!/usr/bin/env python3
"""Extract refresh.py out of the cred-broker ConfigMap so it can be tested.

The script lives as a block scalar inside manifests.yaml, which means nothing
imports it and, until Factory#437, nothing had ever executed its decision
logic. This lifts it to a file so test_cred_broker.py can drive it.
"""

import ast
import pathlib
import sys

MANIFEST = pathlib.Path("apps/cred-broker/manifests/manifests.yaml")
OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/refresh_extracted.py")


def main() -> int:
    lines = MANIFEST.read_text().splitlines()
    starts = [i for i, l in enumerate(lines) if l.strip().startswith("refresh.py: |")]
    # Absence is a failure, not a pass: if the key is renamed or the manifest
    # restructured, the test must go red rather than silently testing nothing.
    if len(starts) != 1:
        print(f"::error::expected exactly one 'refresh.py: |' key, found {len(starts)}")
        return 1
    body = []
    for line in lines[starts[0] + 1 :]:
        if line.strip() and not line.startswith("    "):
            break
        body.append(line[4:] if line.startswith("    ") else line)
    text = "\n".join(body)
    if not text.strip():
        print("::error::extracted an empty script")
        return 1
    ast.parse(text)  # a script that does not parse cannot be tested
    OUT.write_text(text)
    print(f"extracted {len(body)} lines to {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
