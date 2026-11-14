#!/usr/bin/env python3
"""Print the data commands for a MinIO KEK emergency rehearsal."""

import argparse
import ast
import pathlib
import re
import sys

BUCKETS = ("factory-artifacts", "factory-backups", "factory-evidence")
ALIAS = re.compile(r"[A-Za-z][A-Za-z0-9_]*\Z")
STAGING = re.compile(r"/[A-Za-z0-9._/-]+\Z")


def alias_arg(value):
    if not ALIAS.fullmatch(value):
        raise argparse.ArgumentTypeError("alias must match [A-Za-z][A-Za-z0-9_]*")
    return value


def staging_arg(value):
    if not STAGING.fullmatch(value) or ".." in value.split("/"):
        raise argparse.ArgumentTypeError("staging must be an absolute safe path without '..' components")
    return value.rstrip("/") or "/"


def render(alias="drill", staging="/mnt/kek-staging"):
    sections = []
    for step, name in (("3", "export"), ("4", "verify export"),
                       ("6a", "restore"), ("6b", "verify restore")):
        blocks = []
        for bucket in BUCKETS:
            root = f"{staging}/current/{bucket}"
            inventory = f"{staging}/inventory/{bucket}"
            versions = f"{staging}/noncurrent/{bucket}"
            source = f"{alias}/{bucket}"
            if step == "3":
                block = f'''# UNPROVEN: settle in rehearsal: version inventory fields and flags.
mc ls --versions --recursive --json "{source}" > "{inventory}.versions.json"
jq -es '
  all(.[]; .key | (contains("\\n") or startswith("/") or endswith("/") or
    (split("/") | index("..") != null)) | not)
' "{inventory}.versions.json" > /dev/null || {{ echo "unsafe object key: handle by hand" >&2; exit 1; }}
mc ls --recursive --json "{source}" | jq -rs '
  map(select(.type == "file") | .key) |
  if all(.[]; (contains("\\n") or startswith("/") or endswith("/") or
    (split("/") | index("..") != null)) | not)
  then .[] else error("unsafe object key: handle by hand") end
' > "{inventory}.keys"
mkdir -p "{root}" "{versions}"
mc mirror "{source}" "{root}"
# UNPROVEN: settle in rehearsal: version selection and mc cat flag.
jq -c 'select(.type == "file" and .isLatest == false and .isDeleteMarker != true)' "{inventory}.versions.json" |
while IFS= read -r record; do
  key=$(jq -r '.key' <<< "$record")
  version=$(jq -r '.versionId' <<< "$record")
  case "$version" in ''|.|..|*/*|*$'\\n'* ) echo "unsafe version id" >&2; exit 1;; esac
  case "$key" in /*|*/|*$'\\n'*) echo "unsafe object key" >&2; exit 1;; esac
  mkdir -p "{versions}/$version/$(dirname "$key")"
  mc cat --version-id "$version" "{source}/$key" > "{versions}/$version/$key"
done
: > "{inventory}.tags.jsonl"
while IFS= read -r key; do
  # UNPROVEN: settle in rehearsal: tag list output format.
  mc tag list --json "{source}/$key" | jq -c --arg key "$key" '{{key:$key,tags:(.tagset // {{}})}}' >> "{inventory}.tags.jsonl"
done < "{inventory}.keys"
jq -s . "{inventory}.tags.jsonl" > "{inventory}.tags.json"'''
            elif step == "4":
                block = f'''find "{root}" -type f -print0 | sort -z |
while IFS= read -r -d '' file; do
  hash=$(sha256sum "$file" | cut -d ' ' -f 1)
  printf '%s  %s\\n' "$hash" "${{file#"{root}/"}}"
done | LC_ALL=C sort > "{inventory}.current.staged.sha256"
while IFS= read -r key; do
  hash=$(mc cat "{source}/$key" | sha256sum | cut -d ' ' -f 1)
  printf '%s  %s\\n' "$hash" "$key"
done < "{inventory}.keys" | LC_ALL=C sort > "{inventory}.current.source.sha256"
cmp "{inventory}.current.staged.sha256" "{inventory}.current.source.sha256"
find "{versions}" -type f -print0 | sort -z |
while IFS= read -r -d '' file; do
  relative="${{file#"{versions}/"}}"
  version="${{relative%%/*}}"
  key="${{relative#*/}}"
  hash=$(sha256sum "$file" | cut -d ' ' -f 1)
  printf '%s  %s  %s\\n' "$hash" "$version" "$key"
done | LC_ALL=C sort > "{inventory}.noncurrent.staged.sha256"
# UNPROVEN: settle in rehearsal: version inventory fields and mc cat flag.
jq -c 'select(.type == "file" and .isLatest == false and .isDeleteMarker != true)' "{inventory}.versions.json" |
while IFS= read -r record; do
  key=$(jq -r '.key' <<< "$record")
  version=$(jq -r '.versionId' <<< "$record")
  hash=$(mc cat --version-id "$version" "{source}/$key" | sha256sum | cut -d ' ' -f 1)
  printf '%s  %s  %s\\n' "$hash" "$version" "$key"
done | LC_ALL=C sort > "{inventory}.noncurrent.source.sha256"
cmp "{inventory}.noncurrent.staged.sha256" "{inventory}.noncurrent.source.sha256"'''
            elif step == "6a":
                block = f'''mc mirror "{root}" "{source}"
jq -c '.[] | select(.tags != {{}})' "{inventory}.tags.json" |
while IFS= read -r record; do
  key=$(jq -r '.key' <<< "$record")
  tags=$(jq -r '.tags | to_entries | map("\\(.key)=\\(.value)") | join("&")' <<< "$record")
  # UNPROVEN: settle in rehearsal: tag set argument format.
  mc tag set "{source}/$key" "$tags"
done'''
            else:
                block = f'''find "{root}" -type f -print0 | sort -z |
while IFS= read -r -d '' file; do
  hash=$(sha256sum "$file" | cut -d ' ' -f 1)
  printf '%s  %s\\n' "$hash" "${{file#"{root}/"}}"
done | LC_ALL=C sort > "{inventory}.current.staged.sha256"
while IFS= read -r key; do
  hash=$(mc cat "{source}/$key" | sha256sum | cut -d ' ' -f 1)
  printf '%s  %s\\n' "$hash" "$key"
done < "{inventory}.keys" | LC_ALL=C sort > "{inventory}.current.restored.sha256"
cmp "{inventory}.current.staged.sha256" "{inventory}.current.restored.sha256"'''
            blocks.append(f"# {bucket}\n{block}")
        setup = f'mkdir -p "{staging}/inventory"\n' if step == "3" else ""
        sections.append(f"# step {step}: {name}\nset -euo pipefail\n{setup}" + "\n\n".join(blocks))
    return "\n\n".join(sections) + "\n"


def self_test():
    root = pathlib.Path(__file__).resolve().parent.parent
    source = pathlib.Path(__file__).read_text(encoding="utf-8")
    manifest = (root / "apps/minio/manifests/manifests.yaml").read_text(encoding="utf-8")
    doc = (root / "docs/encryption-at-rest.md").read_text(encoding="utf-8")

    def manifest_buckets(content, command):
        return set(re.findall(rf"^\s*mc {command} fac/([a-z0-9-]+)\s*$", content, re.M))

    def check_manifest(content):
        created = manifest_buckets(content, r"mb --ignore-existing")
        encrypted = manifest_buckets(content, r"encrypt set sse-s3")
        return bool(created and encrypted) and created == encrypted == set(BUCKETS)

    assert check_manifest(manifest)
    assert not check_manifest(manifest + "\n  mc mb --ignore-existing fac/fourth-bucket\n")
    assert not check_manifest("no matching bucket commands")

    def runbook_section(content):
        lines = content.splitlines()
        for start, line in enumerate(lines):
            heading = re.match(r"^(#{1,6})\s+.*KEK compromise", line, re.I)
            if heading:
                level = len(heading.group(1))
                end = next((i for i in range(start + 1, len(lines))
                            if re.match(rf"^#{{1,{level}}}\s", lines[i])), len(lines))
                return "\n".join(lines[start:end])
        raise AssertionError("docs/encryption-at-rest.md: KEK compromise section is missing")

    try:
        section = runbook_section(doc)
        assert all(bucket in section for bucket in BUCKETS), "KEK compromise section lacks a bucket"
        altered_doc = doc.replace(section, section.replace(BUCKETS[0], "removed-bucket"), 1)
        assert BUCKETS[0] in altered_doc and BUCKETS[0] not in runbook_section(altered_doc)
    except AssertionError as exc:
        print(f"self-test (b): {exc}", file=sys.stderr)
        return 1

    printed = render()
    def check_fragments(output):
        headings = re.findall(r"^# step (\S+):", output, re.M)
        fragments = re.split(r"(?=^# step \S+:)", output, flags=re.M)[1:]
        return (headings == ["3", "4", "6a", "6b"] and
                all(fragment.splitlines()[1] == "set -euo pipefail" for fragment in fragments) and
                all(all(bucket in fragment for bucket in BUCKETS) for fragment in fragments))

    assert check_fragments(printed)
    assert not check_fragments(printed.replace("# step 6a:", "# step 5:", 1))
    forbidden = ("kubectl", "mc rm", "mc rb", "MINIO_KMS", "<OLD", "<NEW")
    def safe_output(output):
        return all(word not in output for word in forbidden)

    assert all(safe_output(output) for output in (printed, render("lab2", "/srv/stage_1")))
    assert not safe_output(printed + "\nmc rm unsafe\n")

    def imports(content):
        tree = ast.parse(content)
        return {item.name.split(".")[0] for node in ast.walk(tree)
                if isinstance(node, (ast.Import, ast.ImportFrom))
                for item in (node.names if isinstance(node, ast.Import) else [ast.alias(name=node.module)])}

    allowed = {"argparse", "ast", "pathlib", "re", "sys"}
    assert imports(source) <= allowed
    assert not imports(source + "\nimport subprocess\n") <= allowed
    for value in ("-rf", "a;b", ""):
        try:
            alias_arg(value)
        except argparse.ArgumentTypeError:
            continue
        raise AssertionError(f"accepted invalid alias: {value!r}")
    for value in ("relative", "/a/../b", "/a;b"):
        try:
            staging_arg(value)
        except argparse.ArgumentTypeError:
            continue
        raise AssertionError(f"accepted invalid staging: {value!r}")
    print("self-test: ok")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--alias", type=alias_arg, default="drill")
    parser.add_argument("--staging", type=staging_arg, default="/mnt/kek-staging")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    print(render(args.alias, args.staging), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
