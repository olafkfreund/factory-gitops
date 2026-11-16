#!/bin/sh
# Runs minio-offsite.sh against the REAL mc, with "fac/" and "off/" mapped to
# local directories by a thin wrapper. Run in the pinned mc image.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
real_mc="$(command -v mc)"
mkdir -p "$tmp/bin" "$tmp/scratch"
cat > "$tmp/bin/mc" <<EOS
#!/bin/sh
[ "\$1" = alias ] && exit 0
[ "\$1" = cat ] && [ -n "\${FAIL_CAT:-}" ] && exit 1
for a in "\$@"; do
  case "\$a" in
    fac/*|off/*) a="$tmp/root/\$a" ;;
  esac
  set -- "\$@" "\$a"; shift
done
# On a local filesystem mc find also lists directories; S3 has none.
if [ "\$1" = find ]; then "$real_mc" "\$@" | while IFS= read -r p; do [ -f "\$p" ] && echo "\$p"; done; exit 0; fi
exec "$real_mc" "\$@"
EOS
chmod +x "$tmp/bin/mc"
PATH="$tmp/bin:$PATH"; export PATH
S3_ACCESS_KEY=a S3_SECRET_KEY=b OFFSITE_S3_ENDPOINT=https://example.invalid OFFSITE_S3_BUCKET=bk
OFFSITE_S3_ACCESS_KEY=c OFFSITE_S3_SECRET_KEY=d SCRATCH="$tmp/scratch"
export S3_ACCESS_KEY S3_SECRET_KEY OFFSITE_S3_ENDPOINT OFFSITE_S3_BUCKET OFFSITE_S3_ACCESS_KEY OFFSITE_S3_SECRET_KEY SCRATCH
R="$tmp/root"
mkdir -p "$R/fac/factory-artifacts/a" "$R/fac/factory-evidence/e"
echo one > "$R/fac/factory-artifacts/a/1"; echo two > "$R/fac/factory-evidence/e/2"

sh "$here/minio-offsite.sh" >/dev/null || { echo "FAIL good copy"; exit 1; }
[ "$(cat "$R/off/bk/minio/factory-artifacts/a/1")" = one ] || { echo "FAIL copy missing"; exit 1; }
echo "PASS good copy"

rm "$R/fac/factory-artifacts/a/1"   # deleted at source: backup keeps it, job stays green
sh "$here/minio-offsite.sh" >/dev/null || { echo "FAIL source delete must not fail"; exit 1; }
[ -f "$R/off/bk/minio/factory-artifacts/a/1" ] || { echo "FAIL backup lost a deleted object"; exit 1; }
echo "PASS source delete keeps backup"

echo changed-length > "$R/fac/factory-evidence/e/2"   # rewritten in place: not overwritten, must fail loudly
if sh "$here/minio-offsite.sh" >/dev/null 2>&1; then echo "FAIL changed object must fail"; exit 1; fi
[ "$(cat "$R/off/bk/minio/factory-evidence/e/2")" = two ] || { echo "FAIL destination was overwritten"; exit 1; }
echo "PASS changed object fails, destination untouched"

echo two > "$R/fac/factory-evidence/e/2"; echo six > "$R/off/bk/minio/factory-evidence/e/2"   # same size, other bytes
if sh "$here/minio-offsite.sh" >/dev/null 2>&1; then echo "FAIL same-size corruption passed"; exit 1; fi
echo "PASS same-size corruption fails"

# Reads that fail must not hash as two equal empty inputs.
echo two > "$R/off/bk/minio/factory-evidence/e/2"
if FAIL_CAT=1 sh "$here/minio-offsite.sh" >/dev/null 2>&1; then echo "FAIL failed reads passed"; exit 1; fi
echo "PASS failed reads fail"

if OFFSITE_S3_ENDPOINT=http://x sh "$here/minio-offsite.sh" >/dev/null 2>&1; then echo "FAIL http endpoint accepted"; exit 1; fi
echo "PASS refuses http endpoint"
# Encrypted path (Factory#3691): real age from fetch-age.sh, a throwaway key.
SCRATCH="$tmp/agebin" OFFSITE_AGE_RECIPIENT=x WITH_KEYGEN=1 sh "$here/fetch-age.sh" >/dev/null || { echo "FAIL fetch-age.sh"; exit 1; }
"$tmp/agebin/bin/age-keygen" -o "$tmp/key.txt" 2>/dev/null
RECIP="$("$tmp/agebin/bin/age-keygen" -y "$tmp/key.txt")"
SCRATCH="$tmp/scratch"; AGE_BIN="$tmp/agebin/bin/age"; export SCRATCH AGE_BIN
rm -rf "$R/off" "$R/fac"; mkdir -p "$R/off/bk" "$R/fac/factory-artifacts/a" "$R/fac/factory-evidence"
echo one > "$R/fac/factory-artifacts/a/1"; echo two > "$R/fac/factory-artifacts/2"   # evidence stays empty
day="$(date -u +%Y%m%d)"
snap="$R/off/bk/minio/factory-artifacts/snapshots/factory-artifacts-$day.tar.gz.age"
OFFSITE_AGE_RECIPIENT=$RECIP sh "$here/minio-offsite.sh" >"$tmp/out" 2>&1 || { cat "$tmp/out"; echo "FAIL encrypted copy"; exit 1; }
grep -q 'minio-offsite: OK bucket=factory-artifacts encrypted=age' "$tmp/out" || { echo "FAIL no OK line"; exit 1; }
[ -f "$R/off/bk/minio/factory-evidence/snapshots/factory-evidence-$day.tar.gz.age" ] || { echo "FAIL empty bucket snapshot missing"; exit 1; }
mkdir -p "$tmp/restore"
"$tmp/agebin/bin/age" -d -i "$tmp/key.txt" "$snap" | tar -xzf - -C "$tmp/restore"
[ "$(cat "$tmp/restore/factory-artifacts/a/1")" = one ] && [ "$(cat "$tmp/restore/factory-artifacts/2")" = two ] || { echo "FAIL snapshot does not restore"; exit 1; }
[ "$(sha256sum "$snap" | cut -d ' ' -f 1)" = "$(cut -d ' ' -f 1 "$snap.sha256")" ] || { echo "FAIL checksum file"; exit 1; }
echo "PASS encrypted snapshot restores with the offline key"

before="$(sha256sum "$snap")"
OFFSITE_AGE_RECIPIENT=$RECIP sh "$here/minio-offsite.sh" >/dev/null 2>&1 || { echo "FAIL retry"; exit 1; }
[ "$before" = "$(sha256sum "$snap")" ] || { echo "FAIL retry rewrote the snapshot"; exit 1; }
echo "PASS retry passes and does not rewrite"

if OFFSITE_AGE_RECIPIENT='age1;x' sh "$here/minio-offsite.sh" >/dev/null 2>&1; then echo "FAIL bad recipient accepted"; exit 1; fi
if OFFSITE_AGE_RECIPIENT=$RECIP AGE_BIN=/nonexistent sh "$here/minio-offsite.sh" >/dev/null 2>&1; then echo "FAIL missing age accepted"; exit 1; fi
echo "PASS refuses bad recipient and missing age"

echo deadbeef > "$snap.sha256"
if OFFSITE_AGE_RECIPIENT=$RECIP sh "$here/minio-offsite.sh" >/dev/null 2>&1; then echo "FAIL checksum mismatch passed"; exit 1; fi
rm "$snap.sha256"
OFFSITE_AGE_RECIPIENT=$RECIP sh "$here/minio-offsite.sh" >"$tmp/out" 2>&1 || { echo "FAIL missing checksum must pass"; exit 1; }
grep -q 'WARN no checksum file' "$tmp/out" || { echo "FAIL missing checksum did not warn"; exit 1; }
echo "PASS checksum mismatch fails, missing checksum warns"

echo plain > "$snap"
if OFFSITE_AGE_RECIPIENT=$RECIP sh "$here/minio-offsite.sh" >/dev/null 2>&1; then echo "FAIL headerless object passed"; exit 1; fi
: > "$snap"
if OFFSITE_AGE_RECIPIENT=$RECIP sh "$here/minio-offsite.sh" >/dev/null 2>&1; then echo "FAIL empty object passed"; exit 1; fi
echo "PASS headerless and empty destination objects fail"
echo "ALL PASS"
