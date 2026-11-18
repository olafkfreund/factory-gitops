#!/bin/sh
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
script_dir=$(dirname "$0")
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
    case "$2" in off/*) [ -z "${FAIL_LS:-}" ] || exit 1 ;; esac
    for file in "$STUB_ROOT/$2"*; do
      [ -f "$file" ] || continue
      printf '2026-01-01 00:00:00 1 %s\n' "${file##*/}"
    done
    ;;
  mirror)
    # Factory#3806: every mirror call must carry the worker cap.
    [ "$#" -eq 5 ] && [ "$2" = --max-workers ] && [ "$3" = "${EXPECT_WORKERS:-4}" ] || exit 97
    mkdir -p "$STUB_ROOT/$5"
    for file in "$STUB_ROOT/$4"*; do
      [ -f "$file" ] || continue
      target="$STUB_ROOT/$5${file##*/}"
      [ -e "$target" ] || cp "$file" "$target"
    done
    ;;
  cat)
    [ "$#" -eq 2 ]
    cat "$STUB_ROOT/$2"
    ;;
  cp)
    [ "$#" -eq 3 ]
    cp "$2" "$STUB_ROOT/$3"
    ;;
  pipe)
    [ "$#" -eq 2 ]
    cat > "$STUB_ROOT/$2"
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
    happy)
      # An older dump and a key that sorts last: the newest matching name must win.
      printf 'old backup\n' | gzip > "$source_dir/factory-cluster-$(date -u -d "@$((now - 864000))" +%Y%m%dT%H%M%SZ).sql.gz"
      printf 'notes\n' > "$source_dir/zzz-notes.txt" ;;
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
# Encrypted path (Factory#3681): the real age binary from fetch-age.sh, a throwaway key.
SCRATCH="$tmp/agebin" OFFSITE_AGE_RECIPIENT=x WITH_KEYGEN=1 sh "$script_dir/fetch-age.sh" >/dev/null \
  || { echo 'test.sh: FAIL fetch-age.sh' >&2; exit 1; }
REAL_AGE="$tmp/agebin/bin/age"
"$tmp/agebin/bin/age-keygen" -o "$tmp/key.txt" 2>/dev/null
RECIPIENT="$("$tmp/agebin/bin/age-keygen" -y "$tmp/key.txt")"
unset WITH_KEYGEN
run_enc() {
  case_name=$1
  expected=$2
  STUB_ROOT="$tmp/$case_name/root"
  SCRATCH="$tmp/$case_name/scratch"
  AGE_BIN=$REAL_AGE
  export STUB_ROOT SCRATCH AGE_BIN
  OFFSITE_AGE_RECIPIENT=$RECIPIENT
  export OFFSITE_AGE_RECIPIENT
  source_dir="$STUB_ROOT/fac/factory-backups/postgres"
  target_dir="$STUB_ROOT/off/$OFFSITE_S3_BUCKET/postgres"
  mkdir -p "$source_dir" "$target_dir" "$SCRATCH"
  name="factory-cluster-$(date -u -d "@$((now - 3600))" +%Y%m%dT%H%M%SZ).sql.gz"
  printf 'valid backup\n' | gzip > "$source_dir/$name"
  case "$case_name" in
    enc_badgzip) printf 'not gzip\n' > "$source_dir/$name" ;;
    enc_badkey) OFFSITE_AGE_RECIPIENT='age1;rm' ;;
    enc_nokey) OFFSITE_AGE_RECIPIENT=bogus ;;
    enc_noage) AGE_BIN=/nonexistent/age ;;
    enc_present_empty) : > "$target_dir/$name.age" ;;
    enc_present_noheader) printf 'plain text\n' > "$target_dir/$name.age" ;;
    enc_sidecar_bad) printf 'age-encryption.org/v1\nx\n' > "$target_dir/$name.age"; echo deadbeef > "$target_dir/$name.age.sha256" ;;
    enc_present_nosidecar) printf 'age-encryption.org/v1\nx\n' > "$target_dir/$name.age" ;;
  esac
  export OFFSITE_AGE_RECIPIENT AGE_BIN
  if /bin/sh "$script_dir/offsite-copy.sh" > "$tmp/$case_name/output" 2>&1; then status=0; else status=1; fi
  if [ "$expected" = OK ]; then
    if [ "$status" -eq 0 ] && grep -q 'offsite-copy: OK name=.*\.age encrypted=age' "$tmp/$case_name/output"; then
      passed=$((passed + 1)); return
    fi
  elif [ "$status" -eq 1 ] && grep -Fq "offsite-copy: FAIL: $expected" "$tmp/$case_name/output"; then
    passed=$((passed + 1)); return
  fi
  printf 'test.sh: FAIL %s (status=%s):\n' "$case_name" "$status" >&2
  cat "$tmp/$case_name/output" >&2
  failed=$((failed + 1))
}
run_enc enc_happy OK
# Decrypts with the throwaway key to the same content as the source dump.
"$tmp/agebin/bin/age" -d -i "$tmp/key.txt" "$tmp/enc_happy/root/off/offsite-backups/postgres/"*.age | gzip -dc | grep -q 'valid backup' \
  && passed=$((passed + 1)) || { echo 'test.sh: FAIL enc_happy does not decrypt to the dump' >&2; failed=$((failed + 1)); }
for f in "$tmp"/enc_happy/root/off/offsite-backups/postgres/*.age; do
  [ "$(sha256sum "$f" | cut -d ' ' -f 1)" = "$(cut -d ' ' -f 1 "$f.sha256")" ] \
    && passed=$((passed + 1)) || { echo 'test.sh: FAIL enc_happy checksum file' >&2; failed=$((failed + 1)); }
done
run_enc enc_badgzip 'source dump is invalid gzip'
run_enc enc_badkey 'OFFSITE_AGE_RECIPIENT is not an age public key'
run_enc enc_nokey 'OFFSITE_AGE_RECIPIENT is not an age public key'
run_enc enc_noage 'age binary missing'
run_enc enc_present_empty 'destination object is empty'
run_enc enc_present_noheader 'destination object is not an age file'
run_enc enc_sidecar_bad 'destination hash differs from its checksum file'
run_enc enc_present_nosidecar OK
grep -q 'WARN no checksum file' "$tmp/enc_present_nosidecar/output" && passed=$((passed + 1)) \
  || { echo 'test.sh: FAIL missing checksum file did not warn' >&2; failed=$((failed + 1)); }
# A retry for the same dump: pass, and the stored object is not rewritten.
run_enc enc_retry OK
before="$(sha256sum "$tmp/enc_retry/root/off/offsite-backups/postgres/"*.age | cut -d ' ' -f 1)"
/bin/sh "$script_dir/offsite-copy.sh" > "$tmp/enc_retry/output2" 2>&1 \
  && [ "$before" = "$(sha256sum "$tmp/enc_retry/root/off/offsite-backups/postgres/"*.age | cut -d ' ' -f 1)" ] \
  && passed=$((passed + 1)) || { echo 'test.sh: FAIL retry rewrote or failed' >&2; cat "$tmp/enc_retry/output2" >&2; failed=$((failed + 1)); }
# Corrupted copy after upload: the stub cp truncates.
cp "$tmp/bin/mc" "$tmp/bin/mc.real"
sed 's|cp "\$2" "\$STUB_ROOT/\$3"|head -c 10 "$2" > "$STUB_ROOT/$3"|' "$tmp/bin/mc.real" > "$tmp/bin/mc"; chmod +x "$tmp/bin/mc"
run_enc enc_corrupt 'destination hash differs from source'
FAIL_LS=1 run_enc enc_ls_error 'destination listing failed'
unset FAIL_LS
cp "$tmp/bin/mc.real" "$tmp/bin/mc"
printf 'test.sh: %s passed\n' "$passed"
[ "$passed" -gt 0 ] && [ "$failed" -eq 0 ]
