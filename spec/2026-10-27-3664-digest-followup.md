---
status: draft
issue: 3664
repo-issue: olafkfreund/Factory#3664
intent: intent/2026-10-27-3664-digest-followup.md
---

# Spec: follow-ups to the digest-reference admission fix (#316)

## Design

- Repin `AIFACTORY_IMAGE` to `ghcr.io/olafkfreund/aifactory:sha-ec354c0-nix`,
  the same image as `AIFACTORY_BUILD_IMAGE`. The ccbd0ce pin (79845cd, RFC-0017
  #190) existed so build Jobs carry the #727 fixes. The manifest already
  records the `-nix` build image as a strict superset of ccbd0ce, and it is
  what build Jobs run today. Keep the variable rather than dropping it: without
  it the fallback is `DEFAULT_NIX_IMAGE`, which cannot run the build entrypoint.
- Runbook paragraph in `docs/image-signature-admission.md` (escape-hatch
  section), plus a short PANIC.sh header note:
  - digest pins verify at admission, so they need ghcr.io and Sigstore/Rekor;
  - denials surface as ReplicaSet/Job `FailedCreate` events, or as a
    Deployment stuck `Progressing`, while Argo stays Synced.

## Alternatives rejected

- Drop `AIFACTORY_IMAGE`: swaps one trap (denied) for another (a build image
  that cannot run).
- Leave ccbd0ce: unsigned, so it is denied the moment the override goes.
- Build a real alert rule: out of scope for a note; the signals are named.

## Risks

The aifactory Deployment restarts once. Builds already run this image.

## Verification

Server-side dry-run of a Pod on the new value gives verify-images `pass`. CI is
green. After sync, the aifactory rollout completes and the live env shows the
new value.
