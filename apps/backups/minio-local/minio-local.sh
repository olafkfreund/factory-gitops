#!/bin/sh
# Nightly in-cluster snapshot of the MinIO buckets onto a separate PVC (Factory#3691).
# Each run is a NEW generation gen-<UTC stamp>: a full mirror, checked against the
# live source, with MANIFEST.sha256 (hash of every snapshot file) and a COMPLETE
# marker (epoch seconds). It is built under .tmp- and renamed last, so a failed run
# never looks like a snapshot. Keeps the newest KEEP generations.
# shortcut: full copy per generation, fine at MB-GB scale; use restic or hardlinks when the buckets grow.
set -euo pipefail

fail() {
  printf 'minio-local: FAIL: %s\n' "$1" >&2
  exit 1
}

for value in "${S3_ACCESS_KEY:-}" "${S3_SECRET_KEY:-}"; do
  [ -n "$value" ] || fail 'missing credential'
done
BACKUP=${BACKUP:-/backup}
KEEP=${KEEP:-3}
SCRATCH=${SCRATCH:-/scratch}
export MC_CONFIG_DIR="$SCRATCH/.mc"
umask 077   # the snapshot is plaintext: owner only
mc alias set fac "${SOURCE_ENDPOINT:-http://minio.factory.svc.cluster.local:9000}" \
  "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null 2>&1 || fail 'source alias failed'

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
tmp="$BACKUP/.tmp-$stamp"
rm -rf "$BACKUP"/.tmp-*   # leftovers of a run that died
mkdir -p "$tmp"; trap 'rm -rf "$tmp"' EXIT   # a failed run leaves nothing behind

# factory-backups is not here: the postgres dumps have their own copy and drill.
for bucket in factory-artifacts factory-evidence; do
  mkdir -p "$tmp/$bucket"
  mc mirror "fac/$bucket" "$tmp/$bucket" >/dev/null || fail "mirror of $bucket failed"
  mc find "fac/$bucket" > "$SCRATCH/objects" || fail "listing of $bucket failed"
  n=0
  while IFS= read -r obj; do
    rel="${obj#*"/$bucket/"}"
    a="$(mc cat "$obj" | sha256sum)" || fail "read of $obj failed"
    b="$(sha256sum < "$tmp/$bucket/$rel")" || fail "snapshot file missing: $bucket/$rel"
    [ "${a%% *}" = "${b%% *}" ] || fail "content differs: $bucket/$rel"
    printf '%s  %s/%s\n' "${a%% *}" "$bucket" "$rel" >> "$tmp/MANIFEST.sha256"
    n=$((n + 1))
  done < "$SCRATCH/objects"
  have="$(find "$tmp/$bucket" -type f | wc -l)"
  [ "$have" -eq "$n" ] || fail "$bucket: $n source object(s), $have snapshot file(s)"
  printf 'minio-local: OK bucket=%s objects=%s\n' "$bucket" "$n"
done
touch "$tmp/MANIFEST.sha256"
date -u +%s > "$tmp/COMPLETE"
mv "$tmp" "$BACKUP/gen-$stamp"

# Oldest complete generations beyond KEEP, and any gen- dir without COMPLETE.
for d in "$BACKUP"/gen-*; do [ -f "$d/COMPLETE" ] || rm -rf "$d"; done
ls -d "$BACKUP"/gen-* | sort -r | tail -n +"$((KEEP + 1))" | while IFS= read -r d; do rm -rf "$d"; done
printf 'minio-local: OK generation=gen-%s\n' "$stamp"
