#!/bin/sh
# fetch.sh against the REAL mc with fac/ mapped to a local directory.
# Run in the pinned mc image.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
real_mc="$(command -v mc)"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/mc" <<EOS
#!/bin/sh
[ "\$1" = alias ] && exit 0
for a in "\$@"; do
  case "\$a" in fac/*) a="$tmp/root/\$a" ;; esac
  set -- "\$@" "\$a"; shift
done
exec "$real_mc" "\$@"
EOS
chmod +x "$tmp/bin/mc"
PATH="$tmp/bin:$PATH"; export PATH
S3_ACCESS_KEY=a S3_SECRET_KEY=b; export S3_ACCESS_KEY S3_SECRET_KEY
d="$tmp/root/fac/factory-backups/postgres"

mkdir -p "$tmp/s0"; SCRATCH="$tmp/s0" sh "$here/fetch.sh" >/dev/null 2>&1
grep -q '"ok":false.*no_dump_found' "$tmp/s0/result.json" || { echo "FAIL absent dump"; cat "$tmp/s0/result.json"; exit 1; }
echo "PASS absent dump is a not-ok result, exit 0"

mkdir -p "$d" "$tmp/s1"
for n in 20260101T000000Z 20260103T000000Z 20260102T000000Z; do echo "$n" > "$d/factory-cluster-$n.sql.gz"; done
SCRATCH="$tmp/s1" sh "$here/fetch.sh" >/dev/null
[ "$(cat "$tmp/s1/dump.name")" = factory-cluster-20260103T000000Z.sql.gz ] || { echo "FAIL newest not chosen"; exit 1; }
[ "$(cat "$tmp/s1/dump.sql.gz")" = 20260103T000000Z ] && [ ! -f "$tmp/s1/result.json" ] || { echo "FAIL fetch content"; exit 1; }
echo "PASS newest dump chosen"
echo "ALL PASS"
