#!/usr/bin/env python3
"""Audit `mc stat --versions --recursive --json` output: is every object SSE-S3?

Read-only: it parses stdin and prints counts. Run once per bucket under
`set -o pipefail`; the mc JSON shape is UNPROVEN until run once (docs/encryption-at-rest.md).
Exit 0 all encrypted, 1 some are not, 2 unusable input (empty, bad line, mc error).
"""

import argparse
import json
import re
import sys

BUCKET = re.compile(r"[a-z0-9][a-z0-9.-]{1,62}\Z")
HEADER = "x-amz-server-side-encryption"


def audit(lines):
    """Return (encrypted, unencrypted names). Raise ValueError on unusable input."""
    ok, bad = 0, []
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError as exc:
            raise ValueError(f"line {number}: not JSON") from exc
        if not isinstance(entry, dict):
            raise ValueError(f"line {number}: not an object")
        if entry.get("status") == "error":
            raise ValueError(f"line {number}: mc reported an error; enumeration is incomplete")
        if entry.get("isDeleteMarker") or entry.get("type") == "folder":
            continue
        fields = {str(k).lower(): v for k, v in entry.items()}
        meta = entry.get("metadata")
        if isinstance(meta, dict):
            fields.update({str(k).lower(): v for k, v in meta.items()})
        if fields.get(HEADER) == "AES256":
            ok += 1
        else:
            bad.append(f"{entry.get('name', '?')}@{entry.get('versionID', '-')}")
    if ok + len(bad) == 0:
        raise ValueError("no objects seen; an empty capture proves nothing")
    return ok, bad


def self_test():
    enc = '{"status":"success","name":"a","versionID":"1","metadata":{"X-Amz-Server-Side-Encryption":"AES256"}}'
    plain = '{"status":"success","name":"b","versionID":"2","metadata":{"Content-Type":"text/plain"}}'
    assert audit([enc, enc]) == (2, [])
    assert audit([enc, plain, '{"isDeleteMarker":true,"name":"c"}']) == (1, ["b@2"])
    assert audit(['{"name":"d","x-amz-server-side-encryption":"AES256"}']) == (1, [])
    assert audit(['{"name":"e","metadata":{"X-Amz-Server-Side-Encryption":"aws:kms"}}'])[0] == 0
    for bad_input in ([], [""], ["not json"], ["[1]"], [enc, '{"status":"error","error":{}}'], ['{"type":"folder"}']):
        try:
            audit(bad_input)
        except ValueError:
            continue
        raise AssertionError(f"accepted {bad_input!r}")
    print("self-test ok")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", help="bucket name, printed in the report")
    parser.add_argument("--limit", type=int, default=20, help="offending names to print")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.bucket or not BUCKET.match(args.bucket):
        parser.error("--bucket is required (a bucket name)")
    try:
        ok, bad = audit(sys.stdin)
    except ValueError as exc:
        print(f"{args.bucket}: UNUSABLE INPUT: {exc}", file=sys.stderr)
        return 2
    print(f"{args.bucket}: {ok} SSE-S3, {len(bad)} not SSE-S3")
    for name in bad[: max(args.limit, 0)]:
        print(f"  not encrypted: {name}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
