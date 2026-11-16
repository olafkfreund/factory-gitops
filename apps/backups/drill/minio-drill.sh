#!/bin/sh
# MinIO restore drill (Factory#3691): restore a bounded sample from the newest
# complete local snapshot into a scratch bucket, check every restored object
# against the snapshot MANIFEST (never against live data), empty the scratch
# bucket, and write $SCRATCH/result.json with the full-path rto_seconds.
# Exits 0 whenever it could write the result; the last container turns the
# verdict into the Job status.
set -u
S=${SCRATCH:-/scratch}
BACKUP=${BACKUP:-/backup}
BUCKETS=${BUCKETS:-factory-artifacts factory-evidence}
SCRATCH_BUCKET=${SCRATCH_BUCKET:-restore-drill-scratch}
SAMPLE_COUNT=${SAMPLE_COUNT:-20}
MAX_OBJECT_BYTES=${MAX_OBJECT_BYTES:-52428800}
MAX_SNAPSHOT_AGE_SECONDS=${MAX_SNAPSHOT_AGE_SECONDS:-90000}   # 25h: last night's snapshot is 25h old at worst
export MC_CONFIG_DIR="$S/.mc"
now() { date -u +%s; }
t0=$(now)
problems=""; add() { problems="${problems:+$problems,}\"$1\""; }
snap=none; age=-1; objs=0; bytes=0; snap_bytes=0; lookup_s=0; restore_s=0; verify_s=0

run() {
  # Newest generation that has COMPLETE (a half-written one has no gen- name at all).
  for d in $(ls -d "$BACKUP"/gen-* 2>/dev/null | sort -r); do
    [ -f "$d/COMPLETE" ] && { snap="$d"; break; }
  done
  [ "$snap" != none ] || { add no_snapshot; return; }
  age=$(( $(now) - $(cat "$snap/COMPLETE") ))
  [ "$age" -le "$MAX_SNAPSHOT_AGE_SECONDS" ] || add snapshot_stale
  [ "$age" -ge -300 ] || add snapshot_future_dated
  snap_bytes=$(( $(du -sk "$snap" | cut -f1) * 1024 ))
  [ -s "$snap/MANIFEST.sha256" ] || { add manifest_missing; return; }
  mc alias set fac "${SOURCE_ENDPOINT:-http://minio.factory.svc.cluster.local:9000}" \
    "${S3_ACCESS_KEY:-}" "${S3_SECRET_KEY:-}" >/dev/null 2>&1 || { add alias_failed; return; }
  mc mb --ignore-existing "fac/$SCRATCH_BUCKET" >/dev/null 2>&1 \
    && mc encrypt set sse-s3 "fac/$SCRATCH_BUCKET" >/dev/null 2>&1 || { add scratch_bucket_failed; return; }
  lookup_s=$(( $(now) - t0 ))

  a=$(now)
  : > "$S/sample"
  for b in $BUCKETS; do
    grep -E "^[0-9a-f]{64}  $b/" "$snap/MANIFEST.sha256" | sort -k2 > "$S/lines" || true
    [ -s "$S/lines" ] || { add "empty_bucket_$b"; continue; }
    n=0
    while IFS= read -r line; do
      [ "$n" -lt "$SAMPLE_COUNT" ] || break
      f="${line#*  }"
      sz=$(wc -c < "$snap/$f" 2>/dev/null) || { add "snapshot_file_missing_$b"; continue; }
      [ "$sz" -le "$MAX_OBJECT_BYTES" ] || continue
      printf '%s\n' "$line" >> "$S/sample"; n=$((n + 1))
    done < "$S/lines"
  done
  while IFS= read -r line; do
    f="${line#*  }"
    mc cp "$snap/$f" "fac/$SCRATCH_BUCKET/$f" >/dev/null 2>&1 || add "restore_failed"
  done < "$S/sample"
  restore_s=$(( $(now) - a ))

  a=$(now)
  while IFS= read -r line; do
    f="${line#*  }"; want="${line%%  *}"
    got="$(mc cat "fac/$SCRATCH_BUCKET/$f" | sha256sum)" || got=read_failed
    [ "${got%% *}" = "$want" ] || add "restore_mismatch"
    objs=$((objs + 1)); bytes=$((bytes + $(wc -c < "$snap/$f")))
    mc rm "fac/$SCRATCH_BUCKET/$f" >/dev/null 2>&1 || add "scratch_cleanup_failed"
  done < "$S/sample"
  verify_s=$(( $(now) - a ))
  [ "$objs" -gt 0 ] || add no_objects_restored
}
run

end=$(now)
ok=true; [ -z "$problems" ] || ok=false
printf '{"ok":%s,"problems":[%s],"snapshot":"%s","snapshot_age_seconds":%s,"snapshot_bytes":%s,"sample_objects":%s,"sample_bytes":%s,"lookup_seconds":%s,"restore_seconds":%s,"verify_seconds":%s,"rto_seconds":%s}\n' \
  "$ok" "$problems" "${snap##*/}" "$age" "$snap_bytes" "$objs" "$bytes" "$lookup_s" "$restore_s" "$verify_s" "$(( end - t0 ))" > "$S/result.json"
cat "$S/result.json"
exit 0
