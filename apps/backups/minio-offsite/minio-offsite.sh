#!/bin/sh
# Off-cluster copy of the MinIO artifact and evidence buckets (Factory#3691).
# Mirrors without --remove and without --overwrite (a backup must not mirror
# deletions or rewrites), then checks every source object is present and equal
# at the destination. Objects only at the destination (kept after a source
# delete) are fine.
set -euo pipefail

fail() {
  printf 'minio-offsite: FAIL: %s\n' "$1" >&2
  exit 1
}

case "${OFFSITE_S3_ENDPOINT:-}" in
  https://*) ;;
  *) fail 'destination endpoint must use https://' ;;
esac
for value in "${S3_ACCESS_KEY:-}" "${S3_SECRET_KEY:-}" "${OFFSITE_S3_BUCKET:-}" \
  "${OFFSITE_S3_ACCESS_KEY:-}" "${OFFSITE_S3_SECRET_KEY:-}"; do
  [ -n "$value" ] || fail 'missing required credential or bucket'
done

SCRATCH=${SCRATCH:-/scratch}
# Cap mc parallelism: autodetect scales with the host CPUs and OOMKilled the 512Mi pod (Factory#3806).
MC_MAX_WORKERS=${MC_MAX_WORKERS:-4}
case "$MC_MAX_WORKERS" in
  ""|*[!0-9]*|0*) fail 'invalid MC_MAX_WORKERS' ;;
esac
export MC_CONFIG_DIR="$SCRATCH/.mc"
mc alias set fac "${SOURCE_ENDPOINT:-http://minio.factory.svc.cluster.local:9000}" \
  "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null 2>&1 || fail 'source alias failed'
mc alias set off "$OFFSITE_S3_ENDPOINT" "$OFFSITE_S3_ACCESS_KEY" \
  "$OFFSITE_S3_SECRET_KEY" >/dev/null 2>&1 || fail 'destination alias failed'

if [ -n "${OFFSITE_AGE_RECIPIENT:-}" ]; then
  # Encrypted copy (Factory#3691): one age-encrypted tar.gz snapshot per bucket
  # per UTC day (current object versions only). age output differs on every run,
  # so a snapshot already there is checked, never re-encrypted or overwritten.
  case "$OFFSITE_AGE_RECIPIENT" in
    age1*[!a-z0-9]*|age1) fail 'OFFSITE_AGE_RECIPIENT is not an age public key' ;;
    age1*) ;;
    *) fail 'OFFSITE_AGE_RECIPIENT is not an age public key' ;;
  esac
  AGE_BIN=${AGE_BIN:-$SCRATCH/bin/age}
  [ -x "$AGE_BIN" ] || fail 'age binary missing (init container did not run)'
  day="$(date -u +%Y%m%d)"
  for bucket in factory-artifacts factory-evidence; do
    dest="off/$OFFSITE_S3_BUCKET/minio/$bucket/snapshots"
    file="$bucket-$day.tar.gz.age"
    # Fail closed: a listing that errors must never read as "nothing there", or the
    # upload below could replace an existing snapshot. S3 lists an unused prefix as empty.
    listing="$(mc ls "$dest/")" || fail 'destination listing failed'
    has() { printf '%s\n' "$listing" | awk -v n="$1" '$NF == n { f = 1 } END { exit !f }'; }
    if has "$file"; then
      mc cat "$dest/$file" > "$SCRATCH/readback.age" || fail "read-back of $file failed"
      [ -s "$SCRATCH/readback.age" ] || fail "$file at the destination is empty"
      [ "$(head -n 1 "$SCRATCH/readback.age")" = age-encryption.org/v1 ] || fail "$file at the destination is not an age file"
      hash="$(sha256sum "$SCRATCH/readback.age" | cut -d ' ' -f 1)" || fail 'destination hash failed'
      if has "$file.sha256"; then
        want="$(mc cat "$dest/$file.sha256" | cut -d ' ' -f 1)" || fail 'checksum read failed'
        [ "$want" = "$hash" ] || fail "$file differs from its checksum file"
      else
        printf 'minio-offsite: WARN no checksum file for %s\n' "$file" >&2
      fi
      rm -f "$SCRATCH/readback.age"
    else
      rm -rf "$SCRATCH/snap"; mkdir -p "$SCRATCH/snap/$bucket"
      mc mirror --max-workers "$MC_MAX_WORKERS" "fac/$bucket" "$SCRATCH/snap/$bucket" >/dev/null || fail "mirror of $bucket failed"
      tar -C "$SCRATCH/snap" -cf - "$bucket" | gzip | "$AGE_BIN" -r "$OFFSITE_AGE_RECIPIENT" -o "$SCRATCH/$file" || fail "encrypting $bucket failed"
      rm -rf "$SCRATCH/snap"
      [ -s "$SCRATCH/$file" ] || fail "encrypted $bucket snapshot is empty"
      hash="$(sha256sum "$SCRATCH/$file" | cut -d ' ' -f 1)" || fail 'local hash failed'
      mc cp "$SCRATCH/$file" "$dest/$file" >/dev/null || fail "upload of $file failed"
      back="$(mc cat "$dest/$file" | sha256sum | cut -d ' ' -f 1)" || fail "read-back of $file failed"
      [ "$back" = "$hash" ] || fail "$file at the destination differs from the local copy"
      printf '%s\n' "$hash" | mc pipe "$dest/$file.sha256" >/dev/null || fail 'checksum upload failed'
      rm -f "$SCRATCH/$file"
    fi
    printf 'minio-offsite: OK bucket=%s encrypted=age sha256=%s\n' "$bucket" "$hash"
  done
  exit 0
fi

# factory-backups is not here: the postgres dumps have their own copy (#3681).
for bucket in factory-artifacts factory-evidence; do
  dest="off/$OFFSITE_S3_BUCKET/minio/$bucket"
  mc mirror --max-workers "$MC_MAX_WORKERS" "fac/$bucket" "$dest" || fail "mirror of $bucket failed"
  diff_out="$(mc diff "fac/$bucket" "$dest")" || fail "diff of $bucket failed"
  # mc diff: "<" only in source, ">" only at destination, "!" differs.
  bad="$(printf '%s\n' "$diff_out" | grep -c '^[<!]' || true)"
  [ "$bad" -eq 0 ] || fail "$bucket: $bad object(s) missing or different at the destination"
  # mc diff compares name, size and time only: a same-size corrupted copy passes it.
  # shortcut: reads every object on both sides each night, fine at MB-GB scale; compare ETags or provider checksums when buckets get large
  mc find "fac/$bucket" > "$SCRATCH/objects" || fail "listing of $bucket failed"
  differ=0
  while IFS= read -r obj; do
    rel="${obj#*"/$bucket/"}"
    a="$(mc cat "$obj" | sha256sum)" || fail "read of $obj failed"
    b="$(mc cat "$dest/$rel" | sha256sum)" || fail "read of $dest/$rel failed"
    [ "$a" = "$b" ] || { differ=$((differ + 1)); printf 'minio-offsite: content differs: %s\n' "$rel" >&2; }
  done < "$SCRATCH/objects"
  [ "$differ" -eq 0 ] || fail "$bucket: $differ object(s) differ in content at the destination"
  printf 'minio-offsite: OK bucket=%s\n' "$bucket"
done
