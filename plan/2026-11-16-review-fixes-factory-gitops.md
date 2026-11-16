---
status: draft
issue: 347
spec: spec/2026-11-16-review-fixes-factory-gitops.md
coders:
  1: coder   # small shell edit plus test hook; I do it myself
  2: coder   # small awk change plus test
  3: coder   # three-line change plus test and doc
reviewers:
  - codex    # independent read of the diff against this plan
---

# Plan: review fixes in factory-gitops

Approved decisions (from the spec): build the MANIFEST from the snapshot tree, not the live
bucket; sample the drill by a date-seeded shuffle (`SAMPLE_SEED`); a missing auth stream exits 1
(egress `no_source` stays 0). Base `main`, one PR. Merging makes Argo CD update three CronJob
scripts; no live action by us.

## Steps

1. `apps/backups/minio-local/minio-local.sh:34-47` and `test.sh`: drop `mc find` and the live
   `mc cat` compare; loop over `find "$tmp/$bucket" -type f`, hash each file, write
   `hash  bucket/rel`; keep the mirror failure check; remove the count check; add a
   `shortcut:` comment. Test: wrapper runs a hook after `mirror` when `AFTER_MIRROR` is set
   (adds `new`, overwrites `a/1`); new case asserts the run passes and the snapshot holds the
   mirror-time `a/1`; `FAIL_CAT` case becomes `FAIL_MIRROR`. Verify in the pinned BusyBox image only.
   Verify: new case fails on origin/main, passes now; `test.sh` in the mc image.
   Traps: `umask 077`, `set -e` in a `while` fed by a file, `.tmp-` cleanup trap.
2. `apps/backups/drill/minio-drill.sh:42` and `test-minio.sh`: shuffle with `awk -v s="$SEED"
   'BEGIN{srand(s)}{printf "%.9f\t%s\n", rand(), $0}' | sort | cut -f2-`, `SEED=${SAMPLE_SEED:-$(date -u +%Y%m%d)}`.
   Test as in the spec (incl. same-seed repeatability and differing seeds). Verify: fails on origin/main, passes now; `test-minio.sh` in the mc image.
   Traps: the chainguard `-dev` image has busybox awk; the `set -u` header.
3. `apps/security-alerts/manifests/alerts.py` `main()`, `test_alerts.py`, `docs/security-alerts.md:17`:
   `no_source` on `auth_failure_spike` sets `rc = 1`; add an auth-404 case (keep the egress-404 rc 0 assertion); document.
   Verify: `python3 apps/security-alerts/manifests/test_alerts.py` prints `ok`; fails on origin/main.
   Traps: never print a value or `str(exception)`.

## Tests

`docker run` the two mc tests as in `.github/workflows/backup-drill-test.yml`;
`python3 apps/security-alerts/manifests/test_alerts.py`; `kustomize build` unchanged.

## Rollback

Revert the PR; Argo CD restores the previous scripts.
