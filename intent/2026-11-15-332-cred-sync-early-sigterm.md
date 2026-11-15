---
status: draft
issue: 332
author: olafkfreund
---

# Intent: cred-sync must stop even when SIGTERM arrives during its startup

## Problem

The `cred-sync` sidecar runs as PID 1 of its container. Linux drops a signal sent
to PID 1 when no handler is installed for it. #308 installed a SIGTERM handler
in the script, but the handler only exists once Python has started and reached
that line. A SIGTERM that arrives before then is dropped, and the kubelet sends
only one.

On 2026-11-14 the #319 rollout created surge pod `pfactory-79947f58f7-jzptp` at
12:18:22Z and the HPA removed it at 12:18:23Z. The `pfactory` container exited
by 12:18:33Z. `cred-sync` never saw the signal and kept its 60-second loop, so
the pod stayed `Terminating` until SIGKILL at the end of
`terminationGracePeriodSeconds: 1800`, with the RWO volume still mounted.

The same script is vendored in three Deployments (`apps/aifactory`,
`apps/pfactory`, `apps/tfactory`), so all three have the window. On AIFactory
and TFactory the default 30-second grace period limits the hang to 30 seconds.

## Proposed outcome

- A pod deleted at any moment after the `cred-sync` container starts, including
  its first second, has `cred-sync` exit within a few seconds of the stop.
- The behaviour is proved by a test that runs in CI without a cluster and that
  fails on the current manifests.
- All three vendored copies carry the same fix.

## Affected users and systems

- Deployments `aifactory`, `pfactory`, `tfactory` in factory-gitops. Merging
  changes the pod template, so Argo CD rolls all three.
- CI: the `cred-sync guards` workflow.
- No change to what `cred-sync` copies or when it adopts a credential.

## Constraints

- Must not weaken the pod's security settings (`readOnlyRootFilesystem`,
  dropped capabilities, container isolation).
- Must not add an image or a dependency: the sidecar is `python:3.12-slim`,
  pinned by digest.
- The three copies of the script must stay byte-identical
  (`.github/scripts/test_cred_sync.py` enforces it).
- Must not change the main containers' stop path (the 1740-second `preStop`
  drain on PFactory).
- No `kubectl` writes; delivery is by merge and Argo CD sync.

## Open questions

None.
