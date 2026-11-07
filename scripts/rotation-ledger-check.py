#!/usr/bin/env python3
"""Validate the secret rotation ledger and report overdue credentials."""

import argparse
import re
import sys
from datetime import date, timedelta
from pathlib import Path

POLICY_START = date(2026, 11, 7)
NONE_ALLOWED = {"CFACTORY_AUDIT_HMAC_SECRET", "minio-kms"}
START = "<!-- rotation-ledger:start -->"
END = "<!-- rotation-ledger:end -->"
HEADER = "| Credential | Max age (days) | Last rotated | Expires |"
DATE = re.compile(r"\d{4}-\d{2}-\d{2}\Z")
SEPARATOR = re.compile(r":?-{3,}:?\Z")


def parse_date(value, line):
    if not DATE.fullmatch(value):
        raise ValueError(f"line {line}: invalid date {value!r}")
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise ValueError(f"line {line}: invalid date {value!r}") from exc


def cells(raw, line):
    if not (raw.startswith("|") and raw.endswith("|")):
        raise ValueError(f"line {line}: expected four table cells")
    parts = [part.strip() for part in raw[1:-1].split("|")]
    if len(parts) != 4:
        raise ValueError(f"line {line}: expected four table cells")
    return parts


def check(content, today, validate_only=False):
    lines = content.splitlines()
    starts = [i for i, line in enumerate(lines, 1) if line.strip() == START]
    ends = [i for i, line in enumerate(lines, 1) if line.strip() == END]
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        line = (starts + ends + [1])[0]
        raise ValueError(f"line {line}: expected exactly one ordered ledger marker pair")

    first, last = starts[0] + 1, ends[0] - 1
    if first > last or lines[first - 1].strip() != HEADER:
        raise ValueError(f"line {first}: expected exact ledger header")
    separator_line = first + 1
    if separator_line > last or not all(
        SEPARATOR.fullmatch(cell) for cell in cells(lines[separator_line - 1].strip(), separator_line)
    ):
        raise ValueError(f"line {separator_line}: missing table separator")
    if separator_line == last:
        raise ValueError(f"line {last}: ledger has no data rows")

    seen = set()
    overdue = []
    for number in range(separator_line + 1, last + 1):
        credential, age, rotated, expires = cells(lines[number - 1].strip(), number)
        credential = credential.strip("`")
        if not credential or credential in seen:
            raise ValueError(f"line {number}: empty or duplicate credential {credential!r}")
        seen.add(credential)
        if age == "none":
            if credential not in NONE_ALLOWED:
                raise ValueError(f"line {number}: none is not allowed for {credential}")
            max_age = None
        elif re.fullmatch(r"[0-9]+", age) and 1 <= int(age) <= 3650:
            max_age = int(age)
        else:
            raise ValueError(f"line {number}: invalid max age {age!r}")

        rotated_date = POLICY_START if rotated == "unknown" else parse_date(rotated, number)
        if rotated != "unknown" and rotated_date > today:
            raise ValueError(f"line {number}: Last rotated is in the future")
        expiry_date = None if expires == "-" else parse_date(expires, number)
        try:
            deadline = rotated_date + timedelta(days=max_age) if max_age is not None else None
        except OverflowError as exc:
            raise ValueError(f"line {number}: max age exceeds date range") from exc
        if expiry_date is not None and (deadline is None or expiry_date < deadline):
            deadline = expiry_date
        if deadline is not None and today > deadline and not validate_only:
            overdue.append(f"OVERDUE {credential} (due {deadline.isoformat()})")
    return len(seen), overdue


def self_test():
    def ledger(rows="| `GITHUB_TOKEN` | 365 | 2026-11-07 | - |", header=HEADER):
        return f"{START}\n{header}\n| --- | --- | --- | --- |\n{rows}\n{END}\n"

    dated = ledger()
    unknown = ledger("| GITHUB_TOKEN | 365 | unknown | - |")
    assert check(dated, date(2027, 11, 7)) == (1, [])
    assert len(check(dated, date(2027, 11, 8))[1]) == 1
    assert check(unknown, date(2027, 11, 7)) == (1, [])
    assert len(check(unknown, date(2027, 11, 8))[1]) == 1
    assert len(check(ledger("| GITHUB_TOKEN | 365 | 2026-11-07 | 2026-12-01 |"), date(2026, 12, 2))[1]) == 1
    assert check(ledger("| minio-kms | none | unknown | - |"), date(2030, 1, 1)) == (1, [])
    assert check(dated, date(2027, 11, 8), True) == (1, [])

    invalid = [
        ledger("| GITHUB_TOKEN | none | unknown | - |"),
        ledger("| GITHUB_TOKEN | 365 | 2027-01-01 | - |"),
        ledger("| GITHUB_TOKEN | 365 | 2026-02-30 | - |"),
        ledger("| GITHUB_TOKEN | 0 | unknown | - |"),
        ledger("| GITHUB_TOKEN | 365 | unknown | - |\n| `GITHUB_TOKEN` | 365 | unknown | - |"),
        "no ledger",
        ledger() + ledger(),
        f"{END}\n{HEADER}\n{START}",
        ledger(header="| Wrong | Max age (days) | Last rotated | Expires |"),
        ledger(rows=""),
    ]
    for case in invalid:
        try:
            check(case, POLICY_START)
        except ValueError:
            continue
        raise AssertionError(f"accepted invalid ledger: {case!r}")
    print("self-test: ok")


def main():
    def today_arg(value):
        try:
            return parse_date(value, "--today")
        except ValueError as exc:
            raise argparse.ArgumentTypeError(str(exc)) from exc

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--today", type=today_arg, default=date.today())
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("file", nargs="?")
    args = parser.parse_args()
    if args.self_test:
        if args.file or args.validate_only or args.today != date.today():
            parser.error("--self-test takes no other arguments")
        self_test()
        return 0
    if not args.file:
        parser.error("FILE is required")
    try:
        count, overdue = check(Path(args.file).read_text(encoding="utf-8"), args.today, args.validate_only)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"{args.file}: {exc}", file=sys.stderr)
        return 1
    if overdue:
        print("\n".join(overdue))
        return 1
    print(f"ok: {count} rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
