---
status: approved
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
lifecycle: { preStop: { exec: { command: ["sh", "-c", "until grep -Eq '^SigCgt:.*[4-7c-f][0-9a-f]{3}$' /proc/1/status; do sleep 0.1; done"] } } }
```

Why this works:

- The kubelet waits for a container's `preStop` hook to finish before it sends
  SIGTERM to that container. So when the hook runs, SIGTERM is not sent while
  the handler is missing, which is the root cause in issue #332. (The hook
  failing to start is a residual risk, see Risks.)
- `SigCgt` in `/proc/1/status` is the kernel's mask of signals the process
  catches, 16 hex digits. Bit `0x4000` is signal 15 (SIGTERM), so the fourth
  digit from the right has its `4` bit set: one of `4567cdef`. The hook reads a
  fact instead of guessing a duration. Before the handler the mask reads
  `0000000000000002`, after it `0000000000004002` (measured).
- The script's own handler (`signal.signal(signal.SIGTERM, ...)`, added by #308)
  stays as it is and does the exit. The Python script does not change, so the
  three copies stay byte-identical and the adoption guards are untouched.
- The hook writes nothing, so it needs no writable path. It uses `sh`, `grep`
  and `sleep` (fractional, GNU), which are in the pinned `python:3.12-slim`
  image (measured: hook exit 0, `sleep 0.1` exit 0).
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

So at the 100m CPU limit the handler takes about 1.7 s to appear. Of that,
`docker run ... true` takes 0.7 s, a bare `python3 -c pass` 0.8 to 1.3 s, and
the script's imports plus the handler line 1.7 to 2.0 s (3 runs each).

Test: extend `.github/scripts/test_cred_sync.py` (already run by the
`cred-sync guards` workflow, no new workflow):

- Extract the `preStop` command from the `cred-sync` container of each of the
  three manifests. Fail if it is missing or if the three differ.
- Extraction is bounded to the `cred-sync` list item (lines indented deeper
  than `- name: cred-sync`), so PFactory's main-container `preStop` can never be
  picked up in its place. The flow-style `command:` array is valid JSON and is
  parsed with `json.loads`; no PyYAML.
- Run the extracted script as PID 1 of a new PID namespace with `unshare`
  (`unshare -Urpf --kill-child --mount-proc`; if unprivileged user namespaces
  are refused, as on Ubuntu 24.04 runners, `sudo -n` with `unshare -pf
  --kill-child --mount-proc`). Which form works is probed once with a no-op.
  The whole thing runs under `timeout -s KILL` inside the `sudo`, so a stuck
  namespace is always killed from the parent namespace by a process allowed to.
- A shell starts a driver in the background and then `exec`s Python, so Python
  is PID 1. The delay for the deterministic window is a `time.sleep(3)` inside
  the Python `-c` payload, before the script's first line, so PID 1 is Python
  for the whole window.
- The driver first waits until `/proc/1/comm` starts with `python` (the `exec`
  has happened). For the delayed cases it then records whether `SigCgt` still
  lacks SIGTERM; the test fails if the window was not open when the stop
  sequence began. The driver records the hook's exit status, and sends SIGTERM
  only after the hook returned. The driver reports through marker files in a
  temporary directory, because it dies with the namespace.
- Signals come from the driver inside the namespace. A SIGTERM with no handler
  is dropped for PID 1 whether it comes from inside or from a parent namespace,
  so this matches the kubelet's signal.
- Cases, run in parallel (about 31 s wall):
  1. Control: delayed start, window open, one SIGTERM, no hook. Must still be
     running after 6 s. This proves the harness reproduces the bug.
  2. Delayed start, window open, hook then SIGTERM. Hook exit 0; process exit 0
     within 3 s + 5 s.
  3. Normal start, hook then SIGTERM at 0 s. Hook exit 0; process exit 0 within
     5 s.
  4. Normal start, hook then SIGTERM at 30 s (inside `time.sleep(60)`). Hook
     exit 0; process exit 0 within 5 s of the stop.
- A harness that cannot create the namespace fails; it does not skip.

## Alternatives rejected

- **Install the handler as the script's first statement.** Shrinks the window
  (the imports are about half of it) but cannot close it: the interpreter needs
  0.1 to 0.6 s at the CPU limit before any script line runs. Not done in
  addition either: with the hook it buys nothing, and it would edit the script
  in three places.
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
- Residual: if the hook cannot start or fails (a runtime or resource error on
  the exec), the kubelet records `FailedPreStopHook`, does not retry, and sends
  SIGTERM at once. In the first seconds of the container that is the old race.
  The window for it is the same as today's and needs a second fault, so the
  change is never worse than now. Not provoked in a test.
- If PID 1 stays alive but never installs the handler, the hook runs until the
  grace period ends. The kubelet then stops waiting, sends SIGTERM and kills
  the container after a short minimum window (2 s in Kubernetes 1.31). That
  equals today's worst case. If PID 1 exits, the hook dies with it.
- The harness runs the hook on the CI host, not in the image: root or the
  runner's uid, writable `/tmp`, Ubuntu's tools. A later edit to the hook that
  uses a tool missing from `python:3.12-slim`, or that writes a file, would
  pass CI and fail in the pod. The current command was checked in the image by
  hand (table above). Repeat that check when the hook changes.
- The hook depends on `/proc/1/status` being readable by uid 65532 in the
  container. Measured: it is, in the pinned image with the pod's settings.
- CI: the namespace harness needs `unshare` and either unprivileged user
  namespaces or passwordless `sudo`. GitHub `ubuntu-latest` has `sudo`. If
  neither works the test fails loudly.
- The test adds about 35 s to the `cred-sync guards` job (limit 30 minutes).

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
