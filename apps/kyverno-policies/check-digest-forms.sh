#!/usr/bin/env bash
# Online check that digest-form first-party images are signature-verified
# (Factory#3664). Run by hand: it needs network (ghcr.io, Sigstore TUF/Rekor).
# Deliberately NOT a cli.kyverno.io Test -- CI discovers those and CI has no
# network gate. Uses an empty keychain so only public signatures count.
#   KYVERNO=/path/to/kyverno ./check-digest-forms.sh
set -euo pipefail
cd "$(dirname "$0")"
KY=${KYVERNO:-kyverno}
R=ghcr.io/olafkfreund
SIGNED=sha256:b22c1c7b8f58a365217e154a411604e8bbe7de49187c9066b2eb458d4639f8ea   # aifactory:sha-ec354c0-nix
UNSIGNED=sha256:e81259ebb9c4863d4952d9822ba60ae80c05bef6841e213d8fa6835944ef306c
RUNNER=sha256:e2e42c08f5fb8cc7b0d4e3a11efe9639f0b15f02668d80ae797d461b67746eb9
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo '{}' > "$tmp/config.json"; export DOCKER_CONFIG=$tmp

rc=0
# check <name> <image> <pass|fail>
check() {
  cat > "$tmp/pod.yaml" <<P
apiVersion: v1
kind: Pod
metadata: {name: t, namespace: factory}
spec:
  containers: [{name: c, image: "$2"}]
P
  out=$($KY apply manifests/verify-factory-image-signatures.yaml --resource "$tmp/pod.yaml" 2>&1 || true)
  p=$(sed -n 's/.*pass: \([0-9]*\).*/\1/p' <<<"$out" | tail -1); f=$(sed -n 's/.*fail: \([0-9]*\).*/\1/p' <<<"$out" | tail -1)
  p=${p:-0}; f=${f:-0}
  if { [ "$3" = pass ] && [ "$p" -gt 0 ] && [ "$f" -eq 0 ]; } || { [ "$3" = fail ] && [ "$f" -gt 0 ]; }; then
    echo "ok   $1 (pass=$p fail=$f)"
  else
    echo "FAIL $1: wanted $3, got pass=$p fail=$f"; rc=1
  fi
}

check signed-tag        "$R/aifactory:sha-ec354c0-nix"                 pass
check signed-digest     "$R/aifactory@$SIGNED"                          pass
check signed-tag-digest "$R/aifactory:sha-ec354c0-nix@$SIGNED"          pass
check unsigned-tag      "$R/aifactory:${SIGNED/:/-}.sig"                fail
check unsigned-digest   "$R/aifactory@$UNSIGNED"                        fail
check unsigned-tag-digest "$R/aifactory:${SIGNED/:/-}.sig@$UNSIGNED"    fail
check runner-tag-digest "$R/factory-runner-nix:sha-47900d1@$RUNNER" pass
exit $rc
