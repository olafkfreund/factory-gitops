#!/bin/sh
# Step 1 of the restore drill: fetch the newest dump and start the RTO clock.
# Never fails the pod: a failure is written as a not-ok result so the evidence
# and job_health steps still run; the last container turns it into a red Job.
set -u
S=${SCRATCH:-/scratch}
t0="$(date -u +%s)"
printf '%s\n' "$t0" > "$S/t0"
fail() {
  printf '{"ok":false,"problems":["%s"],"dump":"none","dump_bytes":0,"dump_age_seconds":-1,"fetch_seconds":0,"initdb_seconds":0,"restore_seconds":0,"check_seconds":0,"rto_seconds":%s,"databases":0,"tables":0,"rows":0,"restore_errors":0}\n' \
    "$1" "$(( $(date -u +%s) - t0 ))" > "$S/result.json"
  echo "fetch: FAIL $1" >&2
  exit 0
}
export MC_CONFIG_DIR="$S/.mc"
mc alias set fac "${SOURCE_ENDPOINT:-http://minio.factory.svc.cluster.local:9000}" \
  "${S3_ACCESS_KEY:-}" "${S3_SECRET_KEY:-}" >/dev/null 2>&1 || fail fetch_alias_failed
# mc find is unordered; names embed a UTC stamp, so sort puts the newest last.
# Capture first: `$(a | b) || x` tests only the last stage, so a failed `mc find` would read as no_dump_found.
list="$(mc find fac/factory-backups/postgres --name 'factory-cluster-*.sql.gz')" || fail fetch_list_failed
latest="$(printf '%s\n' "$list" | sort | tail -n 1)"
[ -n "$latest" ] || fail no_dump_found
mc cp "$latest" "$S/dump.sql.gz" >/dev/null 2>&1 || fail fetch_copy_failed
printf '%s\n' "${latest##*/}" > "$S/dump.name"
date -u +%s > "$S/t_fetched"
echo "fetch: OK ${latest##*/}"
