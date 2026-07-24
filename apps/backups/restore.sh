#!/usr/bin/env bash
# Guarded, human-run Postgres restore from a MinIO backup object (Factory#321).
#
# NOT a CronJob and NOT synced by ArgoCD (it lives outside apps/backups/manifests
# on purpose). It DROPs and recreates the databases from a pg_dumpall --clean
# backup, so it is destructive by design. Read docs/restore.md first, and quiesce
# the writers (scale pfactory/aifactory/tfactory/cfactory to 0) before running.
#
# Usage:
#   ./restore.sh                       # restore the NEWEST backup (prompts)
#   ./restore.sh factory-cluster-20260724T021500Z.sql.gz   # restore a specific one
#
# Env overrides: NAMESPACE (default factory), MC_IMAGE, PG_IMAGE.
set -euo pipefail

NAMESPACE="${NAMESPACE:-factory}"
MC_IMAGE="${MC_IMAGE:-quay.io/minio/mc:RELEASE.2025-04-03T17-07-56Z}"
PG_IMAGE="${PG_IMAGE:-postgres:16.4}"
OBJECT="${1:-}"           # empty => newest in the bucket
POD="pg-restore-$(date -u +%s)"

echo "Namespace:      ${NAMESPACE}"
echo "Backup object:  ${OBJECT:-<newest in factory-backups/postgres/>}"
echo
echo "This DROPs and recreates pfactory/tfactory/aifactory/cfactory/factory from"
echo "the backup. Current data in those databases will be LOST."
echo "Make sure the writers are scaled to 0 first (see docs/restore.md)."
echo
read -r -p 'Type RESTORE to proceed: ' confirm
[ "${confirm}" = "RESTORE" ] || { echo "aborted"; exit 1; }

cleanup() { kubectl -n "${NAMESPACE}" delete pod "${POD}" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Ephemeral restore Pod: initContainer (mc) downloads the chosen gz into an
# emptyDir; main container (postgres) streams it into psql. Same two-image split
# as the backup CronJob. Creds come from the in-cluster Secrets, never argv.
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  labels: { app: postgres-restore }
spec:
  restartPolicy: Never
  enableServiceLinks: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    fsGroup: 999
    seccompProfile: { type: RuntimeDefault }
  initContainers:
    - name: download
      image: ${MC_IMAGE}
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -euo pipefail
          export MC_CONFIG_DIR=/scratch/.mc
          mc alias set fac http://minio.factory.svc.cluster.local:9000 \
            "\$S3_ACCESS_KEY" "\$S3_SECRET_KEY" >/dev/null
          obj="${OBJECT}"
          if [ -z "\$obj" ]; then
            obj="\$(mc ls fac/factory-backups/postgres/ | awk '{print \$NF}' | sort | tail -1)"
          fi
          [ -n "\$obj" ] || { echo "no backup object found"; exit 1; }
          echo "restoring: \$obj"
          mc cp "fac/factory-backups/postgres/\$obj" /scratch/dump.sql.gz
      env:
        - { name: S3_ACCESS_KEY, valueFrom: { secretKeyRef: { name: minio-creds, key: S3_ACCESS_KEY } } }
        - { name: S3_SECRET_KEY, valueFrom: { secretKeyRef: { name: minio-creds, key: S3_SECRET_KEY } } }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      volumeMounts:
        - { name: scratch, mountPath: /scratch }
  containers:
    - name: restore
      image: ${PG_IMAGE}
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -euo pipefail
          echo "feeding dump into psql (entry db: postgres)..."
          gunzip -c /scratch/dump.sql.gz | psql -h postgres -U factory -d postgres -v ON_ERROR_STOP=1
          echo "restore complete"
      env:
        - name: PGPASSWORD
          valueFrom: { secretKeyRef: { name: factory-secrets, key: POSTGRES_PASSWORD } }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      volumeMounts:
        - { name: scratch, mountPath: /scratch }
  volumes:
    - name: scratch
      emptyDir: { sizeLimit: 5Gi }
YAML

echo "waiting for restore pod to finish..."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${POD}" --timeout=120s || true
kubectl -n "${NAMESPACE}" logs -f "${POD}" -c download || true
kubectl -n "${NAMESPACE}" logs -f "${POD}" -c restore || true

phase="$(kubectl -n "${NAMESPACE}" get pod "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
echo "restore pod phase: ${phase}"
echo "Now run the restore-verification checklist in docs/restore.md before"
echo "scaling the writers back up."
[ "${phase}" = "Succeeded" ]
