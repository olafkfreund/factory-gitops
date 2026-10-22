---
status: draft
issue: 3602
spec: spec/2026-10-22-3602-fleet-match-version-gate.md
---

# Plan: fleet-match calls a version-gated deploy run a build

Approved decisions (from the spec): a Deploy run counts as built only if its
`build-push` job concluded `success`. A run without a `build-push` job
counts as built, as today. A failed jobs call also counts as built, as today,
and prints a warning. A HEAD whose only successful run is gated gets the note
`version_gated` and no problem, like `docs_only`. All edits are in one file,
`apps/fleet-match/manifests/manifests.yaml` (Python embedded in a ConfigMap,
indented 4 spaces).

## Steps

1. `repo_state()` (~line 992–1025): keep `r["id"]` on each run dict. After
   building `runs`, walk the runs that concluded `success`, newest first.
   Call `gh(token, "GET", f"/repos/{repo}/actions/runs/{id}/jobs?per_page=100")`
   and set `run["built"] = not any(j["name"] == "build-push" and
   j.get("conclusion") != "success" for j in jobs)`. Break after the first
   built run. On an exception, print a warning with `eprint` and leave
   `built` unset.
   → verify with the selftest (step 4).
   Traps: keep the 4-space YAML block indent. Never let a jobs error make the
   run list `None`.
2. `latest_success()` (~line 342): add `and r.get("built") is not False`,
   and extend the docstring with one sentence about the version gate.
3. `assess()` signal B (~line 435): before the `elif for_head:`
   build_failed branch, add
   `elif any(r.get("conclusion") == "success" and r.get("built") is False for r in for_head): notes.append("version_gated")`.
4. Selftest (~line 1305, next to `littered`): a gated run
   (`built=False`) for HEAD plus a built PREV makes `latest_success` return
   PREV. The #3602 case, `assess(T, HEAD, 9000, [gated HEAD, PREV], [dep(spec="sha-0bfadd9", running=("sha-0bfadd9",))], "relevant", ...)`,
   gives status `version_gated` and `codes == []`.

## Tests

`python3 .github/scripts/extract_embedded_script.py apps/fleet-match/manifests/manifests.yaml match.py /tmp/fm.py && python3 /tmp/fm.py selftest`
passes. With step 2 reverted, it fails.

## Rollback

Revert the commit. ArgoCD resyncs the ConfigMap, and the CronJob goes back to
counting every successful run.
