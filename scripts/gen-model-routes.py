#!/usr/bin/env python3
"""Generate the gateway's pinned model routes ConfigMap."""

import argparse
import difflib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GATEWAY = ROOT / "apps/model-gateway"
OUTPUT = GATEWAY / "manifests/model-routes.yaml"
CLASSES = ("local", "cheap", "balanced", "frontier")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    sha = (GATEWAY / "hub-catalog.sha").read_text().strip()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
        parser.error("hub-catalog.sha must contain 40 hex characters")
    catalog = json.loads(args.catalog.read_text())
    overrides = json.loads((GATEWAY / "route-overrides.json").read_text())
    if not isinstance(overrides, dict) or any(
        key not in CLASSES or not isinstance(value, str) or not value.strip()
        for key, value in overrides.items()
    ):
        parser.error("overrides must map known classes to non-empty model strings")

    routes = {}
    for model_class in CLASSES:
        candidates = (
            (model_id, model)
            for model_id, model in catalog["models"].items()
            if model["class"] == model_class
            and model["provider"] == "claude"
            and model["price"]["mode"] == "metered"
            and "<" not in model_id
        )
        best = min(
            candidates,
            key=lambda item: (
                item[1]["price"]["in_per_mtok"] + item[1]["price"]["out_per_mtok"],
                -item[1]["caps"]["context"],
                item[0],
            ),
            default=None,
        )
        if best:
            routes[model_class] = best[0]
    routes.update(overrides)

    value = json.dumps(routes, sort_keys=True, indent=2) + "\n"
    rendered = (
        f"# generated from Factory apis/model-catalog.json @ {sha}; do not edit\n"
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n"
        "  name: model-routes\n  namespace: gateway\ndata:\n  routes.json: |\n"
        + "".join(f"    {line}\n" for line in value.splitlines())
    )
    if args.check:
        existing = OUTPUT.read_text() if OUTPUT.exists() else ""
        if existing != rendered:
            print("".join(difflib.unified_diff(
                existing.splitlines(keepends=True), rendered.splitlines(keepends=True),
                fromfile=str(OUTPUT), tofile="generated",
            )), end="")
            return 1
    else:
        OUTPUT.write_text(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
