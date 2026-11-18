#!/bin/sh
# Runs minio-local.sh against the REAL mc, with "fac/" mapped to a local
# directory by a thin wrapper. Run in the pinned mc image.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
real_mc="$(command -v mc)"
mkdir -p "$tmp/bin" "$tmp/scratch" "$tmp/backup"
cat > "$tmp/bin/mc" <<EOS
#!/bin/sh
[ "\$1" = alias ] && exit 0
[ "\$1" = mirror ] && { [ "\$2" = --max-workers ] && [ "\$3" = "\${EXPECT_WORKERS:-4}" ] || { echo "mirror without the --max-workers cap" >&2; exit 97; }; }   # Factory#3806
[ "\$1" = mirror ] && [ -n "\${FAIL_MIRROR:-}" ] && exit 1
for a in "\$@"; do
  case "\$a" in fac/*) a="$tmp/root/\$a" ;; esac
  set -- "\$@" "\$a"; shift
done
# On a local filesystem mc find also lists directories; S3 has none.
if [ "\$1" = find ]; then "$real_mc" "\$@" | while IFS= read -r p; do [ -f "\$p" ] && echo "\$p"; done; exit 0; fi
if [ "\$1" = mirror ] && [ -n "\${AFTER_MIRROR:-}" ]; then   # a factory writes right after the copy
  "$real_mc" "\$@" || exit 1
  echo late > "$tmp/root/fac/factory-artifacts/a/new"; echo overwritten > "$tmp/root/fac/factory-artifacts/a/1"; exit 0
fi
exec "$real_mc" "\$@"
EOS
chmod +x "$tmp/bin/mc"
PATH="$tmp/bin:$PATH"; export PATH
S3_ACCESS_KEY=a S3_SECRET_KEY=b SCRATCH="$tmp/scratch" BACKUP="$tmp/backup" KEEP=3
export S3_ACCESS_KEY S3_SECRET_KEY SCRATCH BACKUP KEEP
R="$tmp/root/fac"; B="$tmp/backup"
mkdir -p "$R/factory-artifacts/a" "$R/factory-evidence/e"
echo one > "$R/factory-artifacts/a/1"; echo two > "$R/factory-evidence/e/2"
run() { sleep 1; sh "$here/minio-local.sh" >/dev/null 2>&1; }   # distinct stamps
gens() { ls -d "$B"/gen-* 2>/dev/null | wc -l; }

run || { echo "FAIL good run"; exit 1; }
g1="$(ls -d "$B"/gen-*)"
[ "$(cat "$g1/factory-artifacts/a/1")" = one ] && [ -s "$g1/COMPLETE" ] && grep -q ' factory-evidence/e/2$' "$g1/MANIFEST.sha256" || { echo "FAIL snapshot content"; exit 1; }
echo "PASS good run"

echo changed > "$R/factory-artifacts/a/1"; rm "$R/factory-evidence/e/2"   # rewritten and deleted at source
run || { echo "FAIL second run"; exit 1; }
[ "$(gens)" -eq 2 ] && [ "$(cat "$g1/factory-artifacts/a/1")" = one ] && [ -f "$g1/factory-evidence/e/2" ] || { echo "FAIL old generation not kept"; exit 1; }
g2="$(ls -d "$B"/gen-* | tail -n 1)"
[ "$(cat "$g2/factory-artifacts/a/1")" = changed ] || { echo "FAIL rewritten key not captured"; exit 1; }
echo "PASS rewrite lands in a new generation, old one kept"

AFTER_MIRROR=1 run || { echo "FAIL write during snapshot failed the run"; exit 1; }
g3="$(ls -d "$B"/gen-* | tail -n 1)"
[ "$(cat "$g3/factory-artifacts/a/1")" = changed ] && ! [ -e "$g3/factory-artifacts/a/new" ] && grep -q ' factory-artifacts/a/1$' "$g3/MANIFEST.sha256" || { echo "FAIL snapshot not the mirror-time state"; exit 1; }
echo "PASS write after the mirror does not fail the run"

if FAIL_MIRROR=1 sh "$here/minio-local.sh" >/dev/null 2>&1; then echo "FAIL failed read passed"; exit 1; fi
[ "$(gens)" -eq 3 ] && ! ls "$B"/.tmp-* >/dev/null 2>&1 || { echo "FAIL failed run left a partial snapshot"; exit 1; }
echo "PASS failed run leaves no generation"

run; run
[ "$(gens)" -eq 3 ] || { echo "FAIL keeps only 3 generations (have $(gens))"; exit 1; }
[ ! -d "$g1" ] || { echo "FAIL oldest not pruned"; exit 1; }
echo "PASS keeps 3 generations"
MC_MAX_WORKERS=2 EXPECT_WORKERS=2 run || { echo "FAIL MC_MAX_WORKERS override"; exit 1; }
for bad in 0 00 x; do MC_MAX_WORKERS=$bad sh "$here/minio-local.sh" >/dev/null 2>&1 && { echo "FAIL bad MC_MAX_WORKERS $bad accepted"; exit 1; }; done
echo "PASS worker cap overridable, bad values rejected"
echo "ALL PASS"
