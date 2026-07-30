#!/usr/bin/env python3
"""Assert the service images pin the same agent CLI versions, and that they pin any.

Reads each Dockerfile passed as ``label=path``, extracts the pinned version of
each agent CLI, and prints the agreed ``package@version`` lines on stdout so the
caller can install exactly those. Exits non-zero, naming the reason, otherwise.

Standards rule 4.7: a gate that cannot run must fail, not pass. The corollary
this script exists to enforce is that absent values must never read as
agreement. Its predecessor (factory-gitops#90) grepped three manifests and
compared the results for equality -- so once the pins moved out of those files,
all three greps returned nothing, the three nothings compared equal, and the
gate would have reported success on zero pins. Here, existence is asserted per
file and per package BEFORE any comparison runs, so a missing pin can never
masquerade as fleet agreement.
"""

import re
import sys

PACKAGES = ("@anthropic-ai/claude-code", "@openai/codex", "@google/gemini-cli")

PIN = re.compile(
    r"(?P<pkg>" + "|".join(re.escape(p) for p in PACKAGES) + r")@(?P<version>\d+\.\d+\.\d+)\b"
)


def pins(text):
    """Return ``{package: {versions pinned for it in this file}}``."""
    found = {pkg: set() for pkg in PACKAGES}
    for match in PIN.finditer(text):
        found[match.group("pkg")].add(match.group("version"))
    return found


def check(sources):
    """``sources``: list of ``(label, text)``. Returns ``(agreed, errors)``.

    ``agreed`` maps package -> version and is only populated when every source
    pins every package to exactly one version and all sources concur.
    """
    if len(sources) < 2:
        return {}, ["need at least two sources to compare, got %d" % len(sources)]

    errors = []
    per_source = []
    for label, text in sources:
        found = pins(text)
        for pkg in PACKAGES:
            if not found[pkg]:
                errors.append("%s: no pinned version of %s" % (label, pkg))
            elif len(found[pkg]) > 1:
                errors.append(
                    "%s: %s pinned to more than one version: %s"
                    % (label, pkg, ", ".join(sorted(found[pkg])))
                )
        per_source.append((label, found))

    # Absence and ambiguity are settled above. Comparing is only meaningful once
    # every value is known to exist -- bail before the equality check rather than
    # let three missing pins agree with each other.
    if errors:
        return {}, errors

    agreed = {}
    for pkg in PACKAGES:
        seen = {label: next(iter(found[pkg])) for label, found in per_source}
        if len(set(seen.values())) > 1:
            errors.append(
                "%s differs across the fleet: %s"
                % (pkg, ", ".join("%s=%s" % pair for pair in sorted(seen.items())))
            )
        else:
            agreed[pkg] = next(iter(seen.values()))

    return ({} if errors else agreed), errors


def main(argv):
    sources = []
    for arg in argv:
        label, sep, path = arg.partition("=")
        if not sep or not label or not path:
            print("error: expected label=path, got %r" % arg, file=sys.stderr)
            return 2
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        except OSError as exc:
            print("error: %s: cannot read %s: %s" % (label, path, exc), file=sys.stderr)
            return 2
        # A silently-truncated download is a gate that cannot run, so it fails.
        if not text.strip():
            print("error: %s: %s is empty" % (label, path), file=sys.stderr)
            return 2
        sources.append((label, text))

    agreed, errors = check(sources)
    if errors:
        for error in errors:
            print("::error::%s" % error, file=sys.stderr)
        return 1

    for pkg in PACKAGES:
        print("%s@%s" % (pkg, agreed[pkg]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
