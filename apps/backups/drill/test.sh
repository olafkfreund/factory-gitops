#!/bin/bash
# Runs drill.sh for real: builds a source cluster shaped like production (bootstrap
# role factory, five databases), takes the same pg_dumpall --clean | gzip, then
# checks the verdicts. Run inside the pinned postgres image as a non-root user.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'pg_ctl -D "$T/src" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
mkdir -p "$T/sock"
initdb -U factory --auth=trust -D "$T/src" >/dev/null
pg_ctl -D "$T/src" -w -o "-c listen_addresses= -c unix_socket_directories=$T/sock" -l "$T/src.log" start >/dev/null
# Shaped like production (Factory#3807): no `factory` database, cfactory empty, an extra role+database.
psql -X -q -h "$T/sock" -U factory -d postgres -c "create role myfriends login" -c "create database myfriends owner myfriends" -c "create database cfactory"
for db in pfactory tfactory aifactory; do
  psql -X -q -h "$T/sock" -U factory -d postgres -c "create database $db"
  psql -X -q -h "$T/sock" -U factory -d "$db" -c "create table job_states(id serial primary key, v text); insert into job_states(v) select 'x' from generate_series(1,10)"
done
psql -X -q -h "$T/sock" -U factory -d postgres -c "alter role factory password 'prod-secret'"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
name="factory-cluster-$stamp.sql.gz"
pg_dumpall -h "$T/sock" -U factory --clean | gzip -9 > "$T/$name"

case_dir() { # $1 dir; copies the good dump in
  mkdir -p "$1"; cp "$T/$name" "$1/dump.sql.gz"; echo "$name" > "$1/dump.name"
  date -u +%s > "$1/t0"; date -u +%s > "$1/t_fetched"
}
check() { # $1 label, $2 dir, $3 pattern that must be in result.json
  grep -q -- "$3" "$2/result.json" || { echo "FAIL $1: expected $3 in:"; cat "$2/result.json"; exit 1; }
  echo "PASS $1"
}

case_dir "$T/good"; SCRATCH="$T/good" bash "$here/drill.sh" >/dev/null
check good "$T/good" '"ok":true'
check good-counts "$T/good" '"databases":4,"tables":3,"rows":30,"restore_errors":0'

case_dir "$T/trunc"; head -c 200 "$T/$name" > "$T/trunc/dump.sql.gz"
SCRATCH="$T/trunc" bash "$here/drill.sh" >/dev/null
check truncated "$T/trunc" '"ok":false'
check truncated-reason "$T/trunc" 'dump_not_valid_gzip'

case_dir "$T/missing"; SCRATCH="$T/missing" EXPECTED_DBS="pfactory nosuchdb" bash "$here/drill.sh" >/dev/null
check missing-db "$T/missing" 'missing_db_nosuchdb'

# Replay dies after CREATE DATABASE of the last db: the FATAL must not hide as "0 errors".
case_dir "$T/fatal"; gunzip -c "$T/$name" | sed 's/^\\connect tfactory/\\connect nosuchdb_x/' | gzip > "$T/fatal/dump.sql.gz"
SCRATCH="$T/fatal" bash "$here/drill.sh" >/dev/null
check fatal-counted "$T/fatal" '"ok":false'

case_dir "$T/old"; echo factory-cluster-20200101T000000Z.sql.gz > "$T/old/dump.name"
SCRATCH="$T/old" bash "$here/drill.sh" >/dev/null
check stale "$T/old" 'dump_stale'
case_dir "$T/future"; echo factory-cluster-20990101T000000Z.sql.gz > "$T/future/dump.name"
SCRATCH="$T/future" bash "$here/drill.sh" >/dev/null
check future-dated "$T/future" 'dump_future_dated'

# Valid gzip, cut short before the pg_dumpall end marker: gzip -t passes, the drill must not.
case_dir "$T/cut"; gunzip -c "$T/$name" | head -n 40 | gzip > "$T/cut/dump.sql.gz"
SCRATCH="$T/cut" bash "$here/drill.sh" >/dev/null
check incomplete-sql "$T/cut" 'dump_incomplete'
echo "ALL PASS"
