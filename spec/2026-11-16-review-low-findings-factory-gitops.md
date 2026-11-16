---
status: approved
issue: 337
intent: intent/2026-11-16-review-low-findings-factory-gitops.md
---

# Spec: LOW findings from the wave-8 review (#337, #340, #341)

## Design

Only #337 changes code. In the STS block of the PostSync hook in
`apps/minio/manifests/manifests.yaml`:

1. `if ! mc admin policy attach ...; then` read `mc admin user info` and accept only when its
   `PolicyName` line carries exactly `aifactory-sts` (not `other-aifactory-sts`, not
   `aifactory-sts-extra`); otherwise `exit 1`. Any other attach failure still fails the hook.
2. After attach, read `mc admin user list --json` line by line; for lines whose `policyName`
   is `aifactory-sts` and whose key is not the current one, `mc admin user disable`. The
   pipeline ends in `|| true`: clean-up is best-effort and never fails the hook. Disable, not
   remove: reversible. Removal stays an owner step.
   The MinIO client image has NO grep, sed or awk (comment at manifests.yaml:297), so both
   steps use only shell `case` and parameter expansion (codex review finding, confirmed).
3. Test `.github/scripts/test_minio_sts.py` slices that block out of the manifest and runs it
   under `sh -e` with a stub `mc` and only `cat` on PATH, as in the image (attach ok, already attached, genuinely failing, similarly
   named policies, rotation picks only the old user). Run by `.github/workflows/minio-sts-test.yml`.

#341 and #340 are refuted (see the intent): no change. Owner actions are reported in the PR.

## Alternatives rejected

- Parse `attach` stderr for "already attached": couples to mc's message text.
- `policy detach` then `attach`: briefly strips access on every sync.
- Remove the old user: irreversible, and relies on best-effort listing.
- Record the previous key in a Secret to identify it: needs a writable Secret and RBAC for a LOW item.

## Risks

- `mc user list --json` format: if it has no `policyName`, no old user is disabled (silent).
  The owner step covers it.
- Test runs host `sh` (also checked once under busybox ash), not the Chainguard image's bash.
- Disabling the user of an in-flight AssumeRole session ends that session: that is the point.

## Verification

`python3 .github/scripts/test_minio_sts.py` passes and fails on the pre-fix block; the
manifest still parses (manifest-validate workflow).
