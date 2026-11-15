---
status: draft
issue: 332
intent: intent/2026-11-15-332-cred-sync-early-sigterm.md
---

# Spec: cred-sync must stop even when SIGTERM arrives during its startup

## Design

Add one `preStop` hook to the `cred-sync` container in all three Deployments
(`apps/aifactory`, `apps/pfactory`, `apps/tfactory`, file
`manifests/manifests.yaml`). The hook waits until PID 1 has a SIGTERM handler
installed, then exits 0:

```yaml
lifecycle: { preStop: { exec: { command: ["sh", "-c", "until m=$(sed -n 's/^SigCgt:[[:space:]]*//p' /proc/1/status) && [ $((0x${m:-0} & 0x4000)) -ne 0 ]; do sleep 0.1; done"] } } }
```

Why this works:

- The kubelet runs a container's `preStop` hook to completion before it sends
  SIGTERM to that container. So SIGTERM is never sent while the handler is
  missing, which is the root cause in issue #332.
- `SigCgt` in `/proc/1/status` is the kernel's mask of signals the process
  catches. Bit `0x4000` is signal 15 (SIGTERM). The hook reads a fact instead of
  guessing a duration.
- The script's own handler (`signal.signal(signal.SIGTERM, ...)`, added by #308)
  stays as it is and does the exit. The Python script does not change, so the
  three copies stay byte-identical and the adoption guards are untouched.
- The hook writes nothing, so it needs no writable path. It uses `sh`, `sed` and
  `sleep`, which are in the pinned `python:3.12-slim` image.
- Each container's hook and SIGTERM run independently, so the main containers'
  stop path (the 1740-second drain on PFactory) is unchanged. `cred-sync` already
  exits at the start of a pod stop since #308; that does not change either.

Measured on 2026-11-15 with `docker run` of the pinned image and the pod's
settings (`--read-only --user 65532 --cap-drop ALL --cpus 0.1 --memory 64m`),
script taken from `apps/pfactory/manifests/manifests.yaml`:

| Case | Result |
| --- | --- |
| SIGTERM alone, right after start, 5 runs | still running after 3 s, 5 of 5 |
| hook then SIGTERM, right after start, 5 runs | hook exit 0 after 1.6 to 1.8 s; container exit 0 within 2.1 s, 5 of 5 |
| hook then SIGTERM, 30 s after start | hook exit 0; container exit 0 within 0.6 s |

So at the 100m CPU limit the handler takes about 1.7 s to appear.

Test: extend `.github/scripts/test_cred_sync.py` (already run by the
`cred-sync guards` workflow, no new workflow):

- Extract the `preStop` command from the `cred-sync` container of each of the
  three manifests. Fail if it is missing or if the three differ.
- Run the extracted script as PID 1 of a new PID namespace with `unshare`
  (`unshare -Urpf --kill-child --mount-proc`; if unprivileged user namespaces
  are refused, as on Ubuntu 24.04 runners, `sudo -n unshare -pf --kill-child
  --mount-proc`). A shell starts a driver in the background and then `exec`s
  Python, so Python is PID 1. Signals come from the driver inside the namespace.
  A SIGTERM with no handler is dropped for PID 1 whether it comes from inside or
  from a parent namespace, so this matches the kubelet's signal.
- The pre-handler window is made deterministic by starting the script behind a
  3-second `time.sleep`, in place of racing interpreter startup.
- Cases:
  1. Control: delayed start, one SIGTERM at 0 s, no hook. Must still be running
     after 6 s. This proves the harness reproduces the bug.
  2. Delayed start, hook then SIGTERM at 0 s. Must exit 0, not before 2.5 s (the
     window was really exercised) and within 3 s + 5 s.
  3. Normal start, hook then SIGTERM at 0 s. Must exit 0 within 5 s.
  4. Normal start, hook then SIGTERM at 30 s (inside `time.sleep(60)`). Must
     exit 0 within 5 s of the stop.
- A harness that cannot create the namespace fails; it does not skip.

## Alternatives rejected

- **Install the handler as the script's first statement.** Shrinks the window
  but cannot close it: most of the 1.7 s is interpreter startup, before any
  script line runs.
- **`preStop` that sleeps a fixed 1 to 2 s** (issue #332's second option, or the
  native `sleep` action). The measured startup is 1.6 to 1.8 s at the CPU limit,
  so 2 s has no margin and a longer sleep delays every stop for a guess.
- **`preStop` that re-sends SIGTERM until PID 1 is gone.** Correct, but the hook
  is killed with the container, exits non-zero, and the kubelet records a
  `FailedPreStopHook` warning on every pod stop.
- **`shareProcessNamespace: true`.** PID 1 becomes the pause container, so the
  default SIGTERM action applies. But both containers run as uid 65532, so each
  could read the other's processes and files through `/proc/<pid>/root`. That
  weakens container isolation (an intent constraint) and changes the main
  container's process model.
- **`tini` or `dumb-init` as PID 1.** Not in the pinned image; needs a new image
  or dependency (an intent constraint).
- **Native sidecar (`initContainers` with `restartPolicy: Always`).** Moves the
  container, changes start order and stop order, and touches the hardening and
  fleet-match checks that look for `cred-sync` under `containers`. Much larger
  than the problem.
- **Shell wrapper as PID 1 with `trap`.** The shell has the same window, only
  shorter.

## Risks

- All three Deployments roll when Argo CD syncs the merge. Old pods stop on the
  old template (no hook). They are long past startup, so the #308 handler stops
  them.
- If the script never installs the handler (for example Python fails to start
  and the container is in a restart loop), the hook waits until the grace period
  ends and the kubelet kills the container. That equals today's worst case and
  is no worse.
- The hook depends on `/proc/1/status` being readable by uid 65532 in the
  container. Measured: it is, in the pinned image with the pod's settings.
- CI: the namespace harness needs `unshare` and either unprivileged user
  namespaces or passwordless `sudo`. GitHub `ubuntu-latest` has `sudo`. If
  neither works the test fails loudly.
- The test adds about 45 s to the `cred-sync guards` job (limit 30 minutes).

## Verification

- `python3 .github/scripts/test_cred_sync.py` passes on the branch, and fails on
  `origin/main` (no hook to extract).
- With the hook removed from the harness's stop sequence (case 1), the process
  survives: the test shows the bug it guards against.
- The `manifest validation (blocking)` workflow passes (kubeconform schema for
  `lifecycle`, Kyverno suites).
- `cred-sync guards` passes in CI on the PR, which proves the harness works on
  the GitHub runner.
- After merge (owner, by Argo CD sync): pods roll; `kubectl get pod -o yaml`
  shows the hook on `cred-sync`. Read-only check, no `kubectl` writes.
