#!/usr/bin/env python3
"""Are the digest pins in this repo still the current bytes for their tags?

factory-gitops#139. Factory#573 pinned every third-party image in the `factory`
namespace to a digest and #161/#162 pinned the rest. That closed the
mutable-tag hole and opened a quieter one, which this answers:

    A pinned digest never moves. When postgres, python, redis, keycloak, minio,
    oauth2-proxy, cloudflared, busybox, openobserve, kyverno, keda, argocd or
    dex ships a CVE fix, the tag moves and this cluster does not.

Before pinning, the drift was silent but the patches arrived. After pinning,
the bytes are honest but the patches do not arrive at all. That is the right
trade only while something eventually says so -- so a pin with nothing watching
it converts "we pinned it" into "we froze a known-vulnerable digest and stopped
looking". Nothing was watching: the Renovate GitHub App is not installed on
this account (zero Renovate PRs across all five Factory repos, ever), its
`kubernetes` manager has an empty default file match anyway, and Dependabot's
docker ecosystem parses `FROM` lines in Dockerfiles, not `image:` fields in
Kubernetes YAML.

THE THING THIS MUST NOT BECOME is an alarm that fires every week on every
image, because that gets muted and then the pins are unwatched again with a
green tick on top. Two decisions keep it quiet, and both were measured on this
repo's real pins rather than guessed:

1. COMPARE THE PLATFORM, NOT THE INDEX. On 2026-08-08, 22 of 23 pins resolved
   to exactly their pinned index digest and one did not: `python:3.12-slim`.
   Diffing the two indexes showed what actually changed --

       image  linux/amd64    sha256:d657ab0a...   IDENTICAL in both
       image  linux/riscv64  sha256:2c7493e4...  -> sha256:43f469a4...
       attestation           one added, one removed

   -- a riscv64 rebuild. Both cluster nodes are linux/amd64, so nothing this
   cluster runs changed at all. An index-digest comparison would have alerted
   on that, in week one, on a non-event. One non-event is all it takes to teach
   everyone to ignore the signal. So the comparison is
   `crane digest --platform linux/amd64` on both sides.

2. A GRACE BUDGET, on the age of the bytes WE run. When the platform digest has
   genuinely moved, the question is not "how recently did upstream rebuild" --
   that number is always small for a fast-moving tag, so a fast-moving tag
   would stay silent forever no matter how far behind we fell. The question is
   how old the bytes we are running are. A pin adopted last week is
   PROPAGATING; a pin whose bytes are from last year is STALE.

Verdicts, and what each is allowed to mean:

    CURRENT      the tag still resolves to our bytes on this platform. Silent.
    PROPAGATING  it moved, and our bytes are younger than the budget. Silent.
    STALE        it moved, and our bytes are older than the budget. ALERTS.
    UNDATED      it moved, and the image declares no usable creation time, so
                 "how far behind" cannot be computed. ALERTS -- "I could not
                 check this" must never look like "this is fine".
    UNREADABLE   the registry could not be read. Exit 2: a watchdog that read
                 nothing must not report freshness.

Usage:
    check_image_pin_freshness.py --self-test
    check_image_pin_freshness.py [--max-age-days N] [--platform os/arch] < refs
"""

from __future__ import annotations

import argparse
import datetime as dt
import subprocess
import sys

CURRENT = "CURRENT"
PROPAGATING = "PROPAGATING"
STALE = "STALE"
UNDATED = "UNDATED"

# Verdicts that mean "somebody has to do something".
ALERTS = {STALE, UNDATED}


def split_ref(ref: str) -> tuple[str, str]:
    """`repo/name:tag@sha256:...` -> (`repo/name:tag`, `sha256:...`).

    A ref with no tag is not merely unusual, it is unwatchable: this comparator
    re-resolves the TAG to ask whether the pin has fallen behind, so
    `name@sha256:...` with the tag dropped is a pin nothing can ever tell you is
    stale. kustomize's `digest:` field produces exactly that shape, which is why
    every pin in this repo puts the digest inside `newTag:` instead. Rejected
    loudly rather than skipped.
    """
    if "@" not in ref:
        raise ValueError(f"not a digest pin: {ref}")
    tag, digest = ref.rsplit("@", 1)
    if ":" not in tag.rsplit("/", 1)[-1]:
        raise ValueError(
            f"digest with no tag, so its currency is uncheckable: {ref} "
            "-- pin as image:tag@sha256:... (kustomize: digest inside newTag:)"
        )
    if not digest.startswith("sha256:"):
        raise ValueError(f"not a sha256 digest: {ref}")
    return tag, digest


def verdict(pinned_plat: str, current_plat: str, created: dt.datetime | None,
            now: dt.datetime, max_age_days: int) -> tuple[str, float | None]:
    """The whole decision, with no I/O in it so --self-test can reach it."""
    if pinned_plat == current_plat:
        return CURRENT, None
    if created is None:
        return UNDATED, None
    age = (now - created).total_seconds() / 86400.0
    return (STALE if age > max_age_days else PROPAGATING), age


def _crane(args: list[str]) -> str:
    out = subprocess.run(["crane", *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"crane {' '.join(args)}: {out.stderr.strip().splitlines()[-1:] or ['failed']}")
    return out.stdout.strip()


def platform_digest(ref: str, platform: str) -> str:
    return _crane(["digest", "--platform", platform, ref])


def created_at(ref: str, platform: str) -> dt.datetime | None:
    """`.created` off the image config, or None when it is absent or a zero.

    Reproducible builds often stamp 1970-01-01, and some images omit the field.
    Both mean the same thing here -- no usable age -- and both must produce
    UNDATED rather than a confident number.
    """
    import json

    raw = json.loads(_crane(["config", "--platform", platform, ref]))
    value = raw.get("created")
    if not value:
        return None
    try:
        # Registries emit RFC3339 with variable sub-second precision.
        head, _, rest = value.partition(".")
        stamp = dt.datetime.strptime(head.rstrip("Z"), "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    stamp = stamp.replace(tzinfo=dt.timezone.utc)
    if stamp.year <= 1980:
        return None
    return stamp


def check(refs: list[str], platform: str, max_age_days: int) -> int:
    now = dt.datetime.now(dt.timezone.utc)
    rows, alerting, unreadable = [], 0, 0

    for ref in sorted(set(refs)):
        try:
            tag, digest = split_ref(ref)
        except ValueError as exc:
            print(f"UNREADABLE   {ref}\n             {exc}")
            unreadable += 1
            continue
        try:
            pinned_plat = platform_digest(f"{tag}@{digest}", platform)
            current_plat = platform_digest(tag, platform)
            created = created_at(f"{tag}@{digest}", platform) \
                if pinned_plat != current_plat else None
        except RuntimeError as exc:
            print(f"UNREADABLE   {tag}\n             {exc}")
            unreadable += 1
            continue

        state, age = verdict(pinned_plat, current_plat, created, now, max_age_days)
        rows.append((state, tag, age))
        if state in ALERTS:
            alerting += 1

    # Rule 4.7. A comparator handed nothing must fail as a comparator handed
    # nothing, never report "everything is fresh".
    if not rows and not unreadable:
        print("::error::not one pinned reference was checked -- this watchdog reported freshness having read nothing")
        return 2

    print(f"\n{len(rows)} pin(s) checked on {platform}, budget {max_age_days}d\n")
    for state, tag, age in sorted(rows):
        old = f"  bytes {age:.0f}d old" if age is not None else ""
        line = f"{state:<12} {tag}{old}"
        print(f"::error::{line}" if state in ALERTS else line)

    counts = {}
    for state, _, _ in rows:
        counts[state] = counts.get(state, 0) + 1
    print("\n" + "  ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    if unreadable:
        print(f"::error::{unreadable} reference(s) could not be read -- this watchdog is blind on them, which is not a pass")
        return 2
    return 1 if alerting else 0


# --------------------------------------------------------------------------
# Self-test. Runs FIRST in CI, not last: a broken comparator cannot be trusted
# to say "everything is fresh", so it has to fail as a broken comparator rather
# than quietly pass everything. Offline -- the verdict function has no I/O.

def _self_test() -> int:
    now = dt.datetime(2026, 8, 8, tzinfo=dt.timezone.utc)
    d = lambda days: now - dt.timedelta(days=days)  # noqa: E731
    A, B = "sha256:aaa", "sha256:bbb"
    cases = [
        # The riscv64 non-event, which is the case with teeth: the INDEX digest
        # moved and linux/amd64 did not. Real, measured on python:3.12-slim on
        # 2026-08-08. Must be silent, and must stay silent -- if this case ever
        # goes red the comparison has drifted back to the index and the whole
        # thing is a weekly alarm again.
        ("index moved, platform identical", (A, A, d(500), 30), CURRENT),
        ("platform moved, our bytes 3d old", (A, B, d(3), 30), PROPAGATING),
        ("platform moved, our bytes 486d old", (A, B, d(486), 30), STALE),
        # Exactly at the budget is not over it.
        ("platform moved, bytes exactly 30d", (A, B, d(30), 30), PROPAGATING),
        ("platform moved, no creation time", (A, B, None, 30), UNDATED),
        # A pin can be ancient and still current: nobody has published anything
        # newer. busybox:1.36's bytes are from 2023 and are the current bytes.
        ("ancient but still the current bytes", (A, A, d(1200), 30), CURRENT),
    ]
    bad = 0
    for name, (pin, cur, created, budget), want in cases:
        got, _ = verdict(pin, cur, created, now, budget)
        flag = "ok " if got == want else "FAIL"
        if got != want:
            bad = 1
        print(f"{flag} {name}: want {want}, got {got}")

    # split_ref must REJECT a tagless digest rather than silently skip it.
    for ref, ok in [
        ("python:3.12-slim@sha256:abc", True),
        ("python@sha256:abc", False),            # kustomize `digest:` output
        ("reg.io:5000/x/y:1.2@sha256:abc", True),  # registry port, not a tag
        ("python:3.12-slim", False),
    ]:
        try:
            split_ref(ref)
            got = True
        except ValueError:
            got = False
        flag = "ok " if got == ok else "FAIL"
        if got != ok:
            bad = 1
        print(f"{flag} split_ref({ref!r}) accepted={got}, want {ok}")

    print("SELF-TEST FAILED" if bad else "self-test passed")
    return bad


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--max-age-days", type=int, default=30)
    p.add_argument("--platform", default="linux/amd64")
    args = p.parse_args()
    if args.self_test:
        return _self_test()
    refs = [line.strip() for line in sys.stdin if line.strip()]
    return check(refs, args.platform, args.max_age_days)


if __name__ == "__main__":
    sys.exit(main())
