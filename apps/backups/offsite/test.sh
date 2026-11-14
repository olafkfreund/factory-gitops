#!/bin/sh
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
script_dir=${0%/*}
mkdir -p "$tmp/bin"
cat > "$tmp/bin/mc" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
  alias)
    [ "$2" = set ] && [ "$#" -eq 6 ]
    ;;
  ls)
    [ "$#" -eq 2 ]
    for file in "$STUB_ROOT/$2"*; do
      [ -f "$file" ] || continue
      printf '2026-01-01 00:00:00 1 %s\n' "${file##*/}"
    done
    ;;
  mirror)
    [ "$#" -eq 3 ]
    mkdir -p "$STUB_ROOT/$3"
    for file in "$STUB_ROOT/$2"*; do
      [ -f "$file" ] || continue
      target="$STUB_ROOT/$3${file##*/}"
      [ -e "$target" ] || cp "$file" "$target"
    done
    ;;
  cat)
    [ "$#" -eq 2 ]
    cat "$STUB_ROOT/$2"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/mc"
PATH="$tmp/bin:$PATH"
export PATH
S3_ACCESS_KEY=source-key
S3_SECRET_KEY=source-secret
OFFSITE_S3_ENDPOINT=https://example.invalid
OFFSITE_S3_BUCKET=offsite-backups
OFFSITE_S3_ACCESS_KEY=destination-key
OFFSITE_S3_SECRET_KEY=destination-secret
export S3_ACCESS_KEY S3_SECRET_KEY OFFSITE_S3_ENDPOINT OFFSITE_S3_BUCKET
export OFFSITE_S3_ACCESS_KEY OFFSITE_S3_SECRET_KEY

now="$(date -u +%s)"
passed=0
failed=0
run_case() {
  case_name=$1
  expected=$2
  STUB_ROOT="$tmp/$case_name/root"
  SCRATCH="$tmp/$case_name/scratch"
  export STUB_ROOT SCRATCH
  source_dir="$STUB_ROOT/fac/factory-backups/postgres"
  target_dir="$STUB_ROOT/off/$OFFSITE_S3_BUCKET/postgres"
  mkdir -p "$source_dir" "$target_dir" "$SCRATCH"
  OFFSITE_S3_ENDPOINT=https://example.invalid
  export OFFSITE_S3_ENDPOINT
  name="factory-cluster-$(date -u -d "@$((now - 3600))" +%Y%m%dT%H%M%SZ).sql.gz"
  case "$case_name" in
    stale) name="factory-cluster-$(date -u -d "@$((now - 90000))" +%Y%m%dT%H%M%SZ).sql.gz" ;;
    future) name="factory-cluster-$(date -u -d "@$((now + 7200))" +%Y%m%dT%H%M%SZ).sql.gz" ;;
    unparsable) name=factory-cluster-garbage.sql.gz ;;
  esac
  case "$case_name" in
    no_dump) ;;
    invalid_gzip) printf 'not gzip\n' > "$source_dir/$name" ;;
    *) printf 'valid backup\n' | gzip > "$source_dir/$name" ;;
  esac
  case "$case_name" in
    corrupt) printf 'different backup\n' | gzip > "$target_dir/$name" ;;
    empty) : > "$target_dir/$name" ;;
    invalid_gzip) cp "$source_dir/$name" "$target_dir/$name" ;;
    older_kept) printf 'older backup\n' | gzip > "$target_dir/older.sql.gz" ;;
    http) OFFSITE_S3_ENDPOINT=http://example.invalid; export OFFSITE_S3_ENDPOINT ;;
  esac
  if /bin/sh "$script_dir/offsite-copy.sh" > "$tmp/$case_name/output" 2>&1; then
    status=0
  else
    status=1
  fi
  if [ "$expected" = OK ]; then
    if [ "$status" -eq 0 ] && grep -q 'offsite-copy: OK name=' "$tmp/$case_name/output" \
      && [ -s "$target_dir/$name" ] \
      && { [ "$case_name" != older_kept ] || [ -s "$target_dir/older.sql.gz" ]; }; then
      passed=$((passed + 1))
      return
    fi
  elif [ "$status" -eq 1 ] && grep -Fq "offsite-copy: FAIL: $expected" "$tmp/$case_name/output"; then
    passed=$((passed + 1))
    return
  fi
  printf 'test.sh: FAIL %s (status=%s):\n' "$case_name" "$status" >&2
  cat "$tmp/$case_name/output" >&2
  failed=$((failed + 1))
}

run_case happy OK
run_case stale 'dump is stale'
run_case future 'dump is future-dated'
run_case unparsable 'invalid dump timestamp'
run_case no_dump 'no dump found'
run_case corrupt 'destination hash differs from source'
run_case empty 'destination dump is empty'
run_case invalid_gzip 'destination dump is invalid gzip'
run_case http 'destination endpoint must use https://'
run_case older_kept OK
printf 'test.sh: %s passed\n' "$passed"
[ "$passed" -gt 0 ] && [ "$failed" -eq 0 ]
