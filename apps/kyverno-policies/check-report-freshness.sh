#!/usr/bin/env bash
#
# Is the signature board green, or is it just STILL? Factory#522 / #501 / #444.
#
# THE PROBLEM THIS EXISTS FOR
# A PolicyReport holds only its most recent scan. It has no history. So a period
# during which scanning was broken leaves NO TRACE once scanning resumes -- the
# report is simply overwritten with a fresh verdict and reads green. Factory#501
# had reports frozen at 2026-07-26 for eleven days; today that gap is completely
# invisible in the reports themselves. "Every PolicyReport is passing" is
# therefore a statement about one instant of a self-erasing artifact, and it is
# NOT evidence that the gate has been working.
#
# WHAT MAKES IT EVIDENCE
# Freshness, measured across the WHOLE POPULATION against the scan cycle:
#
#   1. `results[].timestamp`, NOT `metadata.creationTimestamp`. The report
#      object is created once and updated in place; only the per-result
#      timestamp moves when a background scan actually runs. Factory#444.
#   2. Every result, not a sample. The rescan is a ~1h ROLLING cycle per
#      resource, not a synchronised sweep, so any single result standing still
#      for a while is normal and proves nothing. What cannot happen in a healthy
#      cluster is the OLDEST result in the population exceeding the cycle.
#   3. The population size. A resource that stops being scanned stops producing
#      a result at all -- it does not produce a stale one. A shrinking board
#      looks exactly as green as a working one.
#
# HOW TO USE IT
# One run bounds staleness. It does NOT prove the cycle is turning: for that,
# run it twice more than STALE_S apart and check the oldest timestamp ADVANCES.
# A frozen population passes a single run right up until it crosses the bound.
#
# CEILING, STATED SO IT IS NOT MISREAD (`ponytail:` deliberate simplification):
# a fresh timestamp is not a fresh REGISTRY verdict. Kyverno's image-verify
# cache is positive-only with a 60m TTL, so a `pass` written now may have been
# computed up to 60 minutes ago. Real detection latency for a revoked signature
# is therefore up to interval + TTL, roughly two hours, not the number below.
# This script bounds the SCAN, which is the thing that silently stopped in #501.
set -uo pipefail

CTX=${CTX:-factory}
POLICY=${POLICY:-verify-factory-image-signatures}
# Default bound: two background-scan intervals (1h each) plus slack. One
# interval would flap, because the cycle is rolling rather than synchronised.
STALE_S=${STALE_S:-9000}
MIN_RESULTS=${MIN_RESULTS:-40}

now=$(date +%s)
json=$(kubectl --context "$CTX" get policyreport,clusterpolicyreport -A -o json) || exit 2

read -r total fails oldest newest < <(jq -r --arg p "$POLICY" '
  [.items[].results[] | select(.policy==$p)] as $r
  | [ ($r|length),
      ([$r[]|select(.result=="fail")]|length),
      ([$r[].timestamp.seconds]|min // 0),
      ([$r[].timestamp.seconds]|max // 0) ] | @tsv' <<<"$json")

age_oldest=$(( now - oldest )); age_newest=$(( now - newest ))
echo "policy      : $POLICY"
echo "results     : $total  (fail=$fails)"
echo "oldest scan : ${age_oldest}s ago"
echo "newest scan : ${age_newest}s ago"
echo "bound       : ${STALE_S}s, min population ${MIN_RESULTS}"

rc=0
if [ "$total" -lt "$MIN_RESULTS" ]; then
  echo "FAIL: population collapsed to $total (< $MIN_RESULTS). Resources that stopped"
  echo "      being scanned produce NO result, not a stale one -- a shrinking board"
  echo "      reads as green. Check the reports controller is running."
  rc=1
fi
if [ "$oldest" -eq 0 ] || [ "$age_oldest" -gt "$STALE_S" ]; then
  echo "FAIL: oldest result is ${age_oldest}s old, past the ${STALE_S}s bound."
  echo "      Background scanning has stopped. THE PASSES ARE STALE, NOT GREEN."
  kubectl --context "$CTX" get policyreport -A -o json \
    | jq -r --arg p "$POLICY" --argjson n "$now" '[.items[] | . as $r | .results[]
        | select(.policy==$p) | {age: ($n - .timestamp.seconds), s: "\($r.scope.kind)/\($r.scope.name)"}]
        | sort_by(-.age) | .[0:5][] | "      stalest: \(.s) \(.age)s"'
  rc=1
fi
if [ "$fails" -gt 0 ]; then
  echo "FAIL: $fails failing result(s):"
  jq -r --arg p "$POLICY" '.items[] | . as $r | .results[]
    | select(.policy==$p and .result=="fail")
    | "      \($r.scope.kind)/\($r.scope.name): \(.message)"' <<<"$json"
  rc=1
fi
[ "$rc" -eq 0 ] && echo "OK: population fresh within bound, no failures."
exit "$rc"
