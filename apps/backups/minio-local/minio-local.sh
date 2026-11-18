#!/bin/sh
# Nightly in-cluster snapshot of the MinIO buckets onto a separate PVC (Factory#3691).
# Each run is a NEW generation gen-<UTC stamp>: a full mirror with
# MANIFEST.sha256 (hash of every snapshot file) and a COMPLETE
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
MC_MAX_WORKERS=${MC_MAX_WORKERS:-4}   # Factory#3806: autodetect OOMKilled the 512Mi pod
case "$MC_MAX_WORKERS" in
  ""|*[!0-9]*|0*) fail 'invalid MC_MAX_WORKERS' ;;
esac
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
  mc mirror --max-workers "$MC_MAX_WORKERS" "fac/$bucket" "$tmp/$bucket" >/dev/null || fail "mirror of $bucket failed"
  # shortcut: the MANIFEST hashes the snapshot copy, not the live bucket (a write during the run
  # must not fail it); a copy corrupted in transit that mc mirror misses is recorded, not caught.
  find "$tmp/$bucket" -type f > "$SCRATCH/objects" || fail "listing of $bucket snapshot failed"
  n=0
  while IFS= read -r f; do
    rel="${f#"$tmp/$bucket/"}"
    a="$(sha256sum < "$f")" || fail "hash of $bucket/$rel failed"
    printf '%s  %s/%s\n' "${a%% *}" "$bucket" "$rel" >> "$tmp/MANIFEST.sha256"
    n=$((n + 1))
  done < "$SCRATCH/objects"
  printf 'minio-local: OK bucket=%s objects=%s\n' "$bucket" "$n"
done
touch "$tmp/MANIFEST.sha256"
date -u +%s > "$tmp/COMPLETE"
mv "$tmp" "$BACKUP/gen-$stamp"

# Oldest complete generations beyond KEEP, and any gen- dir without COMPLETE.
for d in "$BACKUP"/gen-*; do [ -f "$d/COMPLETE" ] || rm -rf "$d"; done
ls -d "$BACKUP"/gen-* | sort -r | tail -n +"$((KEEP + 1))" | while IFS= read -r d; do rm -rf "$d"; done
printf 'minio-local: OK generation=gen-%s\n' "$stamp"
