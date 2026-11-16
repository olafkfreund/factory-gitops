#!/bin/sh
# Off-cluster copy of the MinIO artifact and evidence buckets (Factory#3691).
# Mirrors without --remove and without --overwrite (a backup must not mirror
# deletions or rewrites), then checks every source object is present and equal
# at the destination. Objects only at the destination (kept after a source
# delete) are fine.
set -eu

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
export MC_CONFIG_DIR="$SCRATCH/.mc"
mc alias set fac "${SOURCE_ENDPOINT:-http://minio.factory.svc.cluster.local:9000}" \
  "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null 2>&1 || fail 'source alias failed'
mc alias set off "$OFFSITE_S3_ENDPOINT" "$OFFSITE_S3_ACCESS_KEY" \
  "$OFFSITE_S3_SECRET_KEY" >/dev/null 2>&1 || fail 'destination alias failed'

# factory-backups is not here: the postgres dumps have their own copy (#3681).
for bucket in factory-artifacts factory-evidence; do
  dest="off/$OFFSITE_S3_BUCKET/minio/$bucket"
  mc mirror "fac/$bucket" "$dest" || fail "mirror of $bucket failed"
  diff_out="$(mc diff "fac/$bucket" "$dest")" || fail "diff of $bucket failed"
  # mc diff: "<" only in source, ">" only at destination, "!" differs.
  bad="$(printf '%s\n' "$diff_out" | grep -c '^[<!]' || true)"
  [ "$bad" -eq 0 ] || fail "$bucket: $bad object(s) missing or different at the destination"
  printf 'minio-offsite: OK bucket=%s\n' "$bucket"
done
