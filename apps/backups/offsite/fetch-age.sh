#!/bin/sh
# Init container step (Factory#3681, #3691): put a pinned age binary in
# $SCRATCH/bin, only when encryption is on (OFFSITE_AGE_RECIPIENT set).
# Same file in apps/backups/offsite and apps/backups/minio-offsite.
# WITH_KEYGEN=1 also extracts age-keygen (tests only).
set -euo pipefail

if [ -z "${OFFSITE_AGE_RECIPIENT:-}" ]; then
  echo 'fetch-age: no recipient set, skipped'
  exit 0
fi
SCRATCH=${SCRATCH:-/scratch}
url=https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-linux-amd64.tar.gz
sha=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
mkdir -p "$SCRATCH/bin" "$SCRATCH/dl"
wget -q -O "$SCRATCH/dl/age.tgz" "$url" || { echo 'fetch-age: FAIL: download failed' >&2; exit 1; }
echo "$sha  $SCRATCH/dl/age.tgz" | sha256sum -c - >/dev/null 2>&1 || { echo 'fetch-age: FAIL: checksum mismatch' >&2; exit 1; }
members=age/age
[ "${WITH_KEYGEN:-}" = 1 ] && members="$members age/age-keygen"
# shellcheck disable=SC2086
tar -xzf "$SCRATCH/dl/age.tgz" -C "$SCRATCH/dl" $members
for m in $members; do mv "$SCRATCH/dl/$m" "$SCRATCH/bin/"; chmod 0555 "$SCRATCH/bin/${m#age/}"; done
rm -rf "$SCRATCH/dl"
echo 'fetch-age: OK age v1.3.2'
