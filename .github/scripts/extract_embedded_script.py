#!/usr/bin/env python3
"""Extract a Python block scalar out of a ConfigMap so it can be tested.

Several apps in this repo keep their whole implementation as a block scalar
inside manifests.yaml. That means nothing imports it and nothing runs it: until
Factory#437 the cred-broker's decision logic had never once been executed by
CI, and factory-gitops#152 records the same for job-watchdog and argocd-drift.
`manifest-validate.yml` proves the ConfigMap is well-formed YAML and says
nothing whatever about the Python inside it.

This lifts the script to a real file so a test — or its own embedded
`_selftest()` — can be run against it.

    extract_embedded_script.py <manifest.yaml> <key> <out.py>

Generalised from extract_cred_broker.py, which hardcoded the cred-broker
manifest and the `refresh.py` key.
"""

import ast
import pathlib
import sys


def extract(manifest: pathlib.Path, key: str) -> str:
    lines = manifest.read_text().splitlines()
    starts = [i for i, line in enumerate(lines)
              if line.strip().startswith(f"{key}: |")]
    # Absence is a failure, not a pass: if the key is renamed or the manifest
    # restructured, the test must go red rather than silently testing nothing.
    if len(starts) != 1:
        raise SystemExit(
            f"::error::expected exactly one '{key}: |' key in {manifest}, "
            f"found {len(starts)}"
        )
    body = []
    for line in lines[starts[0] + 1:]:
        if line.strip() and not line.startswith("    "):
            break
        body.append(line[4:] if line.startswith("    ") else line)
    text = "\n".join(body)
    if not text.strip():
        raise SystemExit("::error::extracted an empty script")
    ast.parse(text)  # a script that does not parse cannot be tested
    return text


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit(f"usage: {sys.argv[0]} <manifest.yaml> <key> <out.py>")
    manifest, key, out = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
    text = extract(manifest, key)
    out.write_text(text)
    print(f"extracted {len(text.splitlines())} lines from {manifest}:{key} to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
