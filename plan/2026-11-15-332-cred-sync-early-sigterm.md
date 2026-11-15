---
status: draft
issue: 332
spec: spec/2026-11-15-332-cred-sync-early-sigterm.md
coders:
  1: coder   # three identical five-line inserts; too small to hand to another provider
  2: codex   # small tricky logic: PID-namespace harness with signal timing
reviewers:
  - codex    # independent read of the diff against this plan
  - agy      # second independent read; asked for by name in the bulk-run brief
---

# Plan: cred-sync must stop even when SIGTERM arrives during its startup

## Approved decisions (from the spec)

- `cred-sync` is PID 1 of its container. A SIGTERM that arrives before the
  script's handler exists is dropped, and the kubelet sends only one. At the
  100m CPU limit the handler appears about 1.7 s after start.
- Fix: a `preStop` exec hook on the `cred-sync` container, identical in
  `apps/aifactory`, `apps/pfactory` and `apps/tfactory`. It waits until PID 1
  catches SIGTERM (`SigCgt` bit `0x4000` in `/proc/1/status`), then exits 0. The
  kubelet sends SIGTERM only after the hook returns.
- The Python script is NOT edited. Its three copies stay byte-identical.
- Nothing else in the pod changes: no `shareProcessNamespace`, no new image, no
  change to the main containers or to `terminationGracePeriodSeconds`.
- The test goes into the existing `.github/scripts/test_cred_sync.py`, run by
  the existing `cred-sync guards` workflow. No new workflow, no new dependency
  (stdlib only, no PyYAML).
- Base branch `main`. No `kubectl` writes. Merging makes Argo CD roll all three
  Deployments; the PR body must say so.

## Steps

1. `apps/pfactory/manifests/manifests.yaml` (before line 220),
   `apps/aifactory/manifests/manifests.yaml` (before line 238),
   `apps/tfactory/manifests/manifests.yaml` (before line 376): in the
   `cred-sync` container, between the end of the inline script (the line
   `                  main()`) and that container's `          securityContext:`,
   insert exactly these five lines (10 spaces of indent), the same in all three:

   ```yaml
             # factory-gitops#332: as PID 1 this container drops a SIGTERM that arrives before
             # the script installs its handler (about 1.7s at the 100m CPU limit), and the
             # kubelet sends only one. So wait until PID 1 catches SIGTERM: SigCgt bit 0x4000,
             # which makes the 4th hex digit from the right one of 4567cdef.
             lifecycle: { preStop: { exec: { command: ["sh", "-c", "until grep -Eq '^SigCgt:.*[4-7c-f][0-9a-f]{3}$' /proc/1/status; do sleep 0.1; done"] } } }
   ```

   → verify by `grep -c "until grep -Eq '^SigCgt" apps/{aifactory,pfactory,tfactory}/manifests/manifests.yaml`
   (1 each) and `python3 .github/scripts/test_cred_sync.py` (the existing guards
   still pass: the script block is unchanged and still ends where it did).
   Traps: line numbers are from `origin/main` at e49d6b4; match on the text, not
   the number. Each file has other `securityContext:` lines: use the first one
   after `- name: cred-sync`. Do not touch the block scalar. PFactory's main
   container has its own `lifecycle:` line near line 461: leave it alone.

2. `.github/scripts/test_cred_sync.py`: add the stop-path test after the
   adoption `CASES` loop and the adoption-log check, before `if failures:`, and
   append its failures to the same `failures` list. Update the module docstring
   with one paragraph on #332. Contents:

   a. `prestop(app)`: take the lines of the manifest after `- name: cred-sync`
      up to the first non-blank line whose indent is less than or equal to that
      line's indent (the end of the list item). Among them require exactly one
      line whose stripped text starts with `lifecycle:`; take
      `re.search(r"command: (\[.*\])", line)` and `json.loads` it. Missing or
      more than one: `SystemExit("::error::...")`. The three results must be
      equal, else `SystemExit` (drift).

   b. Namespace prefix, probed once with `true`:
      `["unshare", "-Urpf", "--kill-child", "--mount-proc"]`, else
      `["sudo", "-n"]` in front of `["unshare", "-pf", "--kill-child", "--mount-proc"]`.
      Neither works: `SystemExit("::error::...")`. Never skip.

   c. One case = one temporary directory `d` and one process:
      `[sudo -n] timeout -s KILL <limit> unshare ... sh -c '<driver> & exec <python> -u -c <payload> <script> <d> <delay>'`
      (build the `sh -c` string with `shlex.quote`; `<python>` is
      `sys.executable`; stdout and stderr to `DEVNULL`).
      - Payload: `import sys, time; open(sys.argv[2] + '/started', 'w').close(); time.sleep(float(sys.argv[3])); exec(open(sys.argv[1]).read())`.
        The marker proves PID 1 is Python; the sleep is the deterministic
        pre-handler window. `<script>` is the file the test already wrote
        (`path`).
      - Driver, a POSIX `sh` file written to `d`, arguments `d wait [hook argv...]`:
        wait until `d/started` exists (`sleep 0.05` loop); `sleep $wait`; write
        `open` or `caught` to `d/window` depending on whether
        `/proc/1/status` `SigCgt` has the SIGTERM bit; write `date +%s.%N` to
        `d/stop`; if hook argv was given, run it and write its exit status to
        `d/hookrc`; then `kill -TERM 1`.
      - The outer test waits for the process, notes `time.time()`, and reads
        the markers. Exit status 137 means `timeout` had to kill it.

   d. Cases, run in parallel threads:

      | # | delay | wait | hook | limit | pass when |
      |---|---|---|---|---|---|
      | 1 control | 3 | 0 | no | 8 | `window` is `open` and exit status is 137 (survived a lone SIGTERM) |
      | 2 | 3 | 0 | yes | 15 | `window` is `open`, `hookrc` is 0, exit 0, exit − stop < 8 s |
      | 3 | 0 | 0 | yes | 15 | `hookrc` is 0, exit 0, exit − stop < 5 s |
      | 4 | 0 | 30 | yes | 45 | `hookrc` is 0, exit 0, exit − stop < 5 s |

      Print one `ok  `/`FAIL` line per case in the style of the existing ones.

   → verify by `python3 .github/scripts/test_cred_sync.py` (all pass, about
   31 s), and by the two red checks under Tests.
   Traps: stdlib only. Under `sudo` the namespace runs as root: never signal it
   from the test process, let `timeout -s KILL` do it. `SIGKILL` sent to PID 1
   from inside its own namespace is ignored, so the driver cannot clean up.
   The driver dies with the namespace, so it can only report through files.
   On NixOS `sh` is bash and `sys.executable` may be a wrapper: do not test
   `/proc/1/comm`, use the `started` marker. Keep the file's existing style
   (top-level script, no test framework).

## Tests

- `python3 .github/scripts/test_cred_sync.py` → every line `ok`, ends with
  `all guards hold`, exit 0.
- Red check A (fails on today's manifests): `git stash` is banned, so run the
  new test file against `origin/main`'s manifests in a scratch copy:
  `git worktree` is not needed; copy the repo's `apps/` from
  `git show origin/main:apps/pfactory/manifests/manifests.yaml` etc. into a
  temporary tree next to the new test and run it → exits non-zero with the
  "no preStop" error.
- Red check B (the hook is what fixes it): case 1 is the permanent proof; it
  passes only when a lone SIGTERM in the window is lost.
- `python3 -c "import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" apps/{aifactory,pfactory,tfactory}/manifests/manifests.yaml`
  → parses (local sanity; CI's `manifest validation (blocking)` does the schema
  and Kyverno checks).
- CI on the PR: `cred-sync guards` and `manifest validation (blocking)` green.
  The first also proves the harness works on the GitHub runner.

## Rollback

Revert the PR's merge commit on `main`. Argo CD rolls the three Deployments back
to the template without the hook. No data or state is involved.
