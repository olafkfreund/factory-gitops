#!/bin/bash
# Step 2 of the restore drill: replay the dump into a throwaway Postgres that
# lives only in this pod (unix socket, no listener), check the restored data,
# write $SCRATCH/result.json. Exits 0 whenever it could write the result; the
# verdict is in the file and the last container turns it into the Job status.
set -uo pipefail
S=${SCRATCH:-/scratch}
EXPECTED_DBS=${EXPECTED_DBS:-pfactory tfactory aifactory cfactory factory}
# The bootstrap database `factory` may legitimately hold no tables, so only these must.
TABLE_DBS=${TABLE_DBS:-pfactory tfactory aifactory cfactory}
MAX_RESTORE_ERRORS=${MAX_RESTORE_ERRORS:-0}
MAX_DUMP_AGE_SECONDS=${MAX_DUMP_AGE_SECONDS:-90000}   # 25h: yesterday's dump is 25h old at worst
export HOME="$S" TMPDIR="$S"
SOCK="$S/sock"; PGDATA="$S/pgdata"
[ ! -f "$S/result.json" ] || { echo "drill: fetch already failed, skipping"; exit 0; }
PSQL=(psql -X -q -h "$SOCK" -U factory)
problems=()
trap 'pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true' EXIT
now() { date -u +%s; }
t0=$(cat "$S/t0" 2>/dev/null || now)
t_fetched=$(cat "$S/t_fetched" 2>/dev/null || now)
name=$(cat "$S/dump.name" 2>/dev/null || echo unknown)
bytes=$(wc -c < "$S/dump.sql.gz" 2>/dev/null || echo 0)
errors=0; tables=0; rows=0; dbs=0; initdb_s=0; restore_s=0; check_s=0

# Dump age comes from the name: factory-cluster-YYYYMMDDThhmmssZ.sql.gz
ts=${name#factory-cluster-}; ts=${ts%.sql.gz}
age=-1
if [[ "$ts" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]]; then
  d=$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null) && age=$(( $(now) - d ))
else
  problems+=("bad_dump_name")
fi

[ "$age" -le "$MAX_DUMP_AGE_SECONDS" ] || problems+=("dump_stale")
[ "$age" -ge -300 ] || problems+=("dump_future_dated")

run() {
  if ! gzip -t "$S/dump.sql.gz" 2>/dev/null; then problems+=("dump_not_valid_gzip"); return; fi
  [ "$bytes" -gt 0 ] || { problems+=("dump_empty"); return; }
  # A cut-short but well-formed gzip passes gzip -t; pg_dumpall ends with this marker.
  gunzip -c "$S/dump.sql.gz" | tail -n 5 | grep -q 'PostgreSQL database cluster dump complete' \
    || { problems+=("dump_incomplete"); return; }
  local a; a=$(now)
  mkdir -p "$SOCK"
  initdb -U factory --auth=trust -D "$PGDATA" >"$S/initdb.log" 2>&1 || { problems+=("initdb_failed"); return; }
  pg_ctl -D "$PGDATA" -w -t 60 -l "$S/pg.log" \
    -o "-c listen_addresses= -c unix_socket_directories=$SOCK -c fsync=off" start >/dev/null 2>&1 \
    || { problems+=("postgres_start_failed"); return; }
  initdb_s=$(( $(now) - a ))

  a=$(now)
  gunzip -c "$S/dump.sql.gz" | "${PSQL[@]}" -d postgres -v ON_ERROR_STOP=0 >"$S/restore.log" 2>&1
  [ "${PIPESTATUS[0]}" -eq 0 ] || problems+=("gunzip_failed")
  # Replaying onto a fresh cluster always gives these three: DROP DATABASE of a
  # database that does not exist yet, DROP/CREATE ROLE of the bootstrap role.
  errors=$(grep -E 'ERROR:|FATAL:|PANIC:|psql: error|invalid command' "$S/restore.log" | grep -vcE 'database ".*" does not exist|current user cannot be dropped|role "factory" already exists' || true)
  restore_s=$(( $(now) - a ))
  [ "$errors" -le "$MAX_RESTORE_ERRORS" ] || problems+=("restore_errors_${errors}")

  a=$(now)
  local present db n t r tbl
  present=$("${PSQL[@]}" -d postgres -Atc "select datname from pg_database")
  for db in $EXPECTED_DBS; do
    if ! grep -qx "$db" <<<"$present"; then problems+=("missing_db_${db}"); continue; fi
    dbs=$((dbs + 1))
    t=$("${PSQL[@]}" -d "$db" -Atc "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
    if [ "${t:-0}" -lt 1 ]; then
      case " $TABLE_DBS " in *" $db "*) problems+=("no_tables_${db}") ;; esac
      continue
    fi
    tables=$((tables + t))
    # shortcut: exact count(*) per table is fine at MB scale; sample or use reltuples when dumps reach GBs
    for tbl in $("${PSQL[@]}" -d "$db" -Atc "select format('%I.%I',schemaname,tablename) from pg_tables where schemaname not in ('pg_catalog','information_schema')"); do
      r=$("${PSQL[@]}" -d "$db" -Atc "select count(*) from $tbl") || { problems+=("count_failed_${db}"); continue; }
      rows=$((rows + r))
    done
    pg_dump -s -h "$SOCK" -U factory "$db" >/dev/null 2>&1 || problems+=("schema_dump_failed_${db}")
  done
  check_s=$(( $(now) - a ))
  [ "$rows" -gt 0 ] || problems+=("no_rows")
}
run

pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
end=$(now)
rm -rf "$PGDATA" "$S/dump.sql.gz"   # the evidence is result.json; do not leave a cluster on the node
ok=true; [ "${#problems[@]}" -eq 0 ] || ok=false
plist=""; for p in "${problems[@]}"; do plist+="${plist:+,}\"$p\""; done
printf '{"ok":%s,"problems":[%s],"dump":"%s","dump_bytes":%s,"dump_age_seconds":%s,"fetch_seconds":%s,"initdb_seconds":%s,"restore_seconds":%s,"check_seconds":%s,"rto_seconds":%s,"databases":%s,"tables":%s,"rows":%s,"restore_errors":%s}\n' \
  "$ok" "$plist" "$name" "$bytes" "$age" "$(( t_fetched - t0 ))" "$initdb_s" "$restore_s" "$check_s" "$(( end - t0 ))" \
  "$dbs" "$tables" "$rows" "$errors" > "$S/result.json"
cat "$S/result.json"
exit 0
