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
echo "ALL PASS"
