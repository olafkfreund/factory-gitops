#!/bin/sh
# minio-drill.sh against the REAL mc, with "fac/" mapped to a local directory.
# Run in the pinned mc image.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
real_mc="$(command -v mc)"
mkdir -p "$tmp/bin" "$tmp/s"
cat > "$tmp/bin/mc" <<EOS
#!/bin/sh
[ "\$1" = alias ] && exit 0
[ "\$1" = cat ] && [ -n "\${FAIL_CAT:-}" ] && exit 1
[ "\$1" = encrypt ] && exit 0   # SSE-S3 needs a real server
for a in "\$@"; do
  case "\$a" in fac/*) a="$tmp/root/\$a" ;; esac
  set -- "\$@" "\$a"; shift
done
exec "$real_mc" "\$@"
EOS
chmod +x "$tmp/bin/mc"
PATH="$tmp/bin:$PATH"; export PATH
S3_ACCESS_KEY=a S3_SECRET_KEY=b SCRATCH="$tmp/s" BACKUP="$tmp/backup"
export S3_ACCESS_KEY S3_SECRET_KEY SCRATCH BACKUP
G="$tmp/backup/gen-20990101T000000Z"
mk() { # fresh good snapshot with a manifest, COMPLETE = now
  rm -rf "$tmp/backup" "$tmp/root" "$tmp/s"/*; mkdir -p "$G/factory-artifacts/a" "$G/factory-evidence"
  echo one > "$G/factory-artifacts/a/1"; echo two > "$G/factory-evidence/2"
  { echo "$(sha256sum < "$G/factory-artifacts/a/1" | cut -d' ' -f1)  factory-artifacts/a/1"
    echo "$(sha256sum < "$G/factory-evidence/2" | cut -d' ' -f1)  factory-evidence/2"; } > "$G/MANIFEST.sha256"
  date -u +%s > "$G/COMPLETE"
}
check() { grep -q -- "$2" "$tmp/s/result.json" || { echo "FAIL $1: expected $2 in:"; cat "$tmp/s/result.json"; exit 1; }; echo "PASS $1"; }
drill() { sh "$here/minio-drill.sh" >/dev/null; }

mk; drill
check good '"ok":true'
check good-counts '"sample_objects":2'
[ -z "$(find "$tmp/root/fac/restore-drill-scratch" -type f)" ] || { echo "FAIL scratch not emptied"; exit 1; }
echo "PASS scratch emptied"
grep -q '"rto_seconds":[0-9]' "$tmp/s/result.json" && echo "PASS rto recorded"

mk; drill   # live data does not exist at all: restore is checked against the manifest, not live
check no-live-data-needed '"ok":true'

mk; echo corrupt > "$G/factory-evidence/2"; drill
check corrupted-snapshot 'restore_mismatch'

mk; rm "$G/COMPLETE"; drill
check no-complete 'no_snapshot'

mk; echo 1 > "$G/COMPLETE"; drill
check stale 'snapshot_stale'

mk; : > "$G/MANIFEST.sha256"; drill
check empty-manifest 'manifest_missing'

mk; grep -v factory-evidence "$G/MANIFEST.sha256" > "$tmp/m"; mv "$tmp/m" "$G/MANIFEST.sha256"; drill
check empty-bucket 'empty_bucket_factory-evidence'

mk; MAX_OBJECT_BYTES=1 drill   # every object over the cap: nothing restored must be red
check oversize-skipped 'no_objects_restored'
mk; : > "$G/factory-evidence/2"; sed -i "s/^.*  factory-evidence/$(printf '' | sha256sum | cut -d' ' -f1)  factory-evidence/" "$G/MANIFEST.sha256"
FAIL_CAT=1 drill   # a failed read of an empty object must not pass as its hash
check failed-read 'restore_mismatch'

mk; echo 0123456789 > "$G/factory-evidence/2"; MAX_OBJECT_BYTES=5 drill   # evidence object over cap, artifacts fine
check bucket-without-sample 'no_sample_factory-evidence'
# The sample rotates: 10 objects, 3 per run. Same seed repeats; other seeds reach past the first three paths.
mk; for i in 01 02 03 04 05 06 07 08 09 10; do echo "o$i" > "$G/factory-evidence/o$i"; echo "$(sha256sum < "$G/factory-evidence/o$i" | cut -d' ' -f1)  factory-evidence/o$i" >> "$G/MANIFEST.sha256"; done
pick() { SAMPLE_COUNT=3 SAMPLE_SEED=$1 sh "$here/minio-drill.sh" >/dev/null; grep factory-evidence "$tmp/s/sample" | sort | tr '\n' ' '; }
a="$(pick 1)"; [ "$a" = "$(pick 1)" ] || { echo "FAIL same seed gave another sample"; exit 1; }
all="$a"; differs=no
for s in 2 3 4 5 6; do p="$(pick $s)"; all="$all$p"; [ "$p" = "$a" ] || differs=yes; done
[ "$differs" = yes ] || { echo "FAIL seeds do not change the sample"; exit 1; }
printf '%s' "$all" | grep -Eq 'o(0[3-9]|10)' || { echo "FAIL sample never leaves the first paths"; exit 1; }
check seeded-run '"sample_objects":4'
echo "PASS sample rotates"
echo "ALL PASS"
