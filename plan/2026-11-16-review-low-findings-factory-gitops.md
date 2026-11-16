---
status: approved
issue: 337
spec: spec/2026-11-16-review-low-findings-factory-gitops.md
coders:
  1: coder   # lead implements it: one small shell block, already written and tested
  2: coder   # lead: new test and workflow
reviewers:
  - codex    # read-only: final diff review
---

# Plan: LOW findings from the wave-8 review (#337, #340, #341)

Approved decisions (from the spec): fix only #337; #340 and #341 are refuted with evidence
and change nothing. In the MinIO STS block, make `policy attach` idempotent by accepting a
failure only if `user info` shows exactly the `aifactory-sts` policy on its `PolicyName:` line; best-effort disable
other users holding that policy. Shell uses `case` only (the image has no grep/sed/awk).

## Steps

1. `apps/minio/manifests/manifests.yaml` STS block (after `mc admin user add`): replace the bare
   `policy attach` with the `if !` / `case` form and add the rotation loop → verify by
   `python3 .github/scripts/test_minio_sts.py`.
   Traps: no grep/sed/awk in the image; hook runs under `set -e`; no secret on argv beyond the
   existing `user add`; do not touch apps/security-alerts.
2. `.github/scripts/test_minio_sts.py` and `.github/workflows/minio-sts-test.yml`: slice the block
   from the manifest, run under `sh -e` with a stub `mc` and only `cat` on PATH → verify by the
   same command, and `TEST_SH="/abs/path/busybox sh"` once.
   Traps: workflow action pin copied from cred-broker-test.yml.

## Tests

`python3 .github/scripts/test_minio_sts.py` prints `ok`; the manifest-validate workflow is green.

## Rollback

Revert the PR. The live user keeps its policy; a disabled old user is re-enabled with
`mc admin user enable fac <key>`.

## Owner actions (not in this PR)

- #340: replace the shared `factory-secrets/GITHUB_TOKEN` with a fine-grained token limited to
  issues on the alert repo for the cred-broker and secret-rotation CronJobs.
- #337: after the next STS key rotation, confirm in the hook log that the previous user was
  disabled; if not, run `mc admin user disable fac <old key>` / `remove`.
