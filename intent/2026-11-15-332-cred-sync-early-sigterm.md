---
status: approved
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
by 12:18:33Z. `cred-sync` kept its 60-second loop, so the pod stayed
`Terminating` until SIGKILL at the end of `terminationGracePeriodSeconds: 1800`,
with the RWO volume still mounted. Those times are observed (issue #332). That
the signal fell in the startup window is inferred: nothing recorded when it was
delivered. The mechanism is reproducible: a process that is PID 1 of a PID
namespace and has not yet installed a handler survives SIGTERM.

The same script is vendored in three Deployments (`apps/aifactory`,
`apps/pfactory`, `apps/tfactory`), so all three have the window. On AIFactory
and TFactory the default 30-second grace period limits the hang to 30 seconds.

## Proposed outcome

- When the kubelet stops the `cred-sync` container at any moment after it
  starts, including before the script has installed its handler, the container
  exits within 5 seconds of the handler being installed, or within 5 seconds of
  the stop if it already was.
- The behaviour is proved by a test that runs in CI without a cluster. The test
  runs the script as PID 1 of a PID namespace, makes the pre-handler window
  deterministic instead of racing it, and fails on the current manifests.
- All three vendored copies carry the same fix, and CI fails if they differ.

## Affected users and systems

- Deployments `aifactory`, `pfactory`, `tfactory` in factory-gitops. Merging
  changes the pod template, so Argo CD rolls all three.
- CI: the `cred-sync guards` workflow.
- No change to what `cred-sync` copies or when it adopts a credential.
- Not affected: the Helm charts in AIFactory, PFactory and TFactory do not
  define `cred-sync` (checked with grep on 2026-11-15).

## Constraints

- Must not weaken the pod's security settings (`readOnlyRootFilesystem`,
  dropped capabilities, container isolation).
- Must not add an image or a dependency: the sidecar is `python:3.12-slim`,
  pinned by digest.
- The three copies of the script must stay byte-identical
  (`.github/scripts/test_cred_sync.py` enforces it for the script only). Any
  part of the fix outside the script must be held identical the same way, and
  the existing adoption guards must keep running against the embedded script.
- The sidecar has no writable `/tmp` or home: its only writable path is
  `/h/.claude`, shared with the main container, and nothing but credentials
  may be written there. It runs as uid 65532.
- Must not change the main containers' stop path (the 1740-second `preStop`
  drain on PFactory).
- No `kubectl` writes; delivery is by merge and Argo CD sync.

## Open questions

None.
