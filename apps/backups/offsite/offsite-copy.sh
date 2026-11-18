#!/bin/sh
set -euo pipefail

fail() {
  printf 'offsite-copy: FAIL: %s\n' "$1" >&2
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
MAX_AGE_SECONDS=${MAX_AGE_SECONDS:-43200}
case "$MAX_AGE_SECONDS" in
  ''|*[!0-9]*) fail 'invalid MAX_AGE_SECONDS' ;;
esac
export MC_CONFIG_DIR="$SCRATCH/.mc"
mc alias set fac "${SOURCE_ENDPOINT:-http://minio.factory.svc.cluster.local:9000}" \
  "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null 2>&1 || fail 'source alias failed'
mc alias set off "$OFFSITE_S3_ENDPOINT" "$OFFSITE_S3_ACCESS_KEY" \
  "$OFFSITE_S3_SECRET_KEY" >/dev/null 2>&1 || fail 'destination alias failed'

name="$(mc ls fac/factory-backups/postgres/ | \
  awk '$NF ~ /^factory-cluster-.*\.sql\.gz$/ { print $NF }' | sort | tail -n 1)" || fail 'source listing failed'
[ -n "$name" ] || fail 'no dump found'
timestamp=${name#factory-cluster-}
timestamp=${timestamp%.sql.gz}
case "$timestamp" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) fail 'invalid dump timestamp' ;;
esac
formatted="$(printf '%s\n' "$timestamp" | awk '{ printf "%s-%s-%s %s:%s:%s", substr($0,1,4), substr($0,5,2), substr($0,7,2), substr($0,10,2), substr($0,12,2), substr($0,14,2) }')" || fail 'invalid dump timestamp'
stamp="$(date -u -d "$formatted" +%s 2>/dev/null)" || fail 'invalid dump timestamp'
now="$(date -u +%s)" || fail 'current time unavailable'
age=$((now - stamp))
[ "$age" -ge -300 ] || fail 'dump is future-dated'
# The limit must stay below 25h: yesterday's dump is 25h old at this job's start.
[ "$age" -le "$MAX_AGE_SECONDS" ] || fail 'dump is stale'

if [ -n "${OFFSITE_AGE_RECIPIENT:-}" ]; then
  # Encrypted copy (Factory#3681): age output differs on every run, so an object
  # that is already there is checked, never re-encrypted or overwritten.
  case "$OFFSITE_AGE_RECIPIENT" in
    age1*[!a-z0-9]*|age1) fail 'OFFSITE_AGE_RECIPIENT is not an age public key' ;;
    age1*) ;;
    *) fail 'OFFSITE_AGE_RECIPIENT is not an age public key' ;;
  esac
  AGE_BIN=${AGE_BIN:-$SCRATCH/bin/age}
  [ -x "$AGE_BIN" ] || fail 'age binary missing (init container did not run)'
  mc cat "fac/factory-backups/postgres/$name" | gzip -t 2>/dev/null || fail 'source dump is invalid gzip'
  dest="off/$OFFSITE_S3_BUCKET/postgres"
  # Fail closed: a listing that errors must never read as "nothing there", or the
  # upload below could replace an existing copy. S3 lists an unused prefix as empty.
  listing="$(mc ls "$dest/")" || fail 'destination listing failed'
  has() { printf '%s\n' "$listing" | awk -v n="$1" '$NF == n { f = 1 } END { exit !f }'; }
  if has "$name.age"; then
    mc cat "$dest/$name.age" > "$SCRATCH/readback.age" || fail 'destination read-back failed'
    [ -s "$SCRATCH/readback.age" ] || fail 'destination object is empty'
    [ "$(head -n 1 "$SCRATCH/readback.age")" = age-encryption.org/v1 ] || fail 'destination object is not an age file'
    hash="$(sha256sum "$SCRATCH/readback.age" | cut -d ' ' -f 1)" || fail 'destination hash failed'
    if has "$name.age.sha256"; then
      want="$(mc cat "$dest/$name.age.sha256" | cut -d ' ' -f 1)" || fail 'checksum read failed'
      [ "$want" = "$hash" ] || fail 'destination hash differs from its checksum file'
    else
      printf 'offsite-copy: WARN no checksum file for %s.age\n' "$name" >&2
    fi
  else
    mc cat "fac/factory-backups/postgres/$name" | "$AGE_BIN" -r "$OFFSITE_AGE_RECIPIENT" -o "$SCRATCH/$name.age" || fail 'encryption failed'
    [ -s "$SCRATCH/$name.age" ] || fail 'encrypted dump is empty'
    hash="$(sha256sum "$SCRATCH/$name.age" | cut -d ' ' -f 1)" || fail 'local hash failed'
    mc cp "$SCRATCH/$name.age" "$dest/$name.age" >/dev/null || fail 'upload failed'
    back="$(mc cat "$dest/$name.age" | sha256sum | cut -d ' ' -f 1)" || fail 'destination read-back failed'
    [ "$back" = "$hash" ] || fail 'destination hash differs from source'
    printf '%s\n' "$hash" | mc pipe "$dest/$name.age.sha256" >/dev/null || fail 'checksum upload failed'
  fi
  printf 'offsite-copy: OK name=%s.age encrypted=age sha256=%s age_seconds=%s\n' "$name" "$hash" "$age"
  exit 0
fi

mc mirror --max-workers "$MC_MAX_WORKERS" fac/factory-backups/postgres/ "off/$OFFSITE_S3_BUCKET/postgres/" || fail 'mirror failed'
# shortcut: reads the whole newest dump back each night, fine at MB size; compare provider checksums when dumps reach GBs
mc cat "off/$OFFSITE_S3_BUCKET/postgres/$name" > "$SCRATCH/readback.gz" || fail 'destination read-back failed'
[ -s "$SCRATCH/readback.gz" ] || fail 'destination dump is empty'
gzip -t "$SCRATCH/readback.gz" 2>/dev/null || fail 'destination dump is invalid gzip'
destination_hash="$(sha256sum "$SCRATCH/readback.gz" | cut -d ' ' -f 1)" || fail 'destination hash failed'
source_hash="$(mc cat "fac/factory-backups/postgres/$name" | sha256sum | cut -d ' ' -f 1)" || fail 'source read-back failed'
[ "$destination_hash" = "$source_hash" ] || fail 'destination hash differs from source'
bytes="$(wc -c < "$SCRATCH/readback.gz" | awk '{ print $1 }')" || fail 'byte count failed'
printf 'offsite-copy: OK name=%s bytes=%s sha256=%s age_seconds=%s\n' "$name" "$bytes" "$destination_hash" "$age"
