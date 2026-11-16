"""The pager Alert in docs/security-alerts.md must match every failing job_health status."""
import os
import re

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")


def read(p):
    with open(os.path.join(root, p)) as f:
        return f.read()


m = re.search(r"status NOT IN \(([^)]*)\)", read("docs/security-alerts.md"))
assert m, "the documented Alert must be a NOT IN (healthy statuses) filter"
healthy = set(re.findall(r"'([a-z_]+)'", m.group(1)))

crit = re.search(r"CRITICAL_CODES = \{([^}]*)\}", read("apps/job-watchdog/manifests/manifests.yaml"))
failing = set(re.findall(r'"([a-z_]+)"', crit.group(1)))
failing |= {"failing", "stale", "never_succeeded", "not_scheduled", "suspended", "firing", "error",
            "overdue", "orphans_unreaped", "restore_failed", "missing"}
assert {"reconcile_stalled", "job_failed", "job_wedged"} <= failing  # the parse found the real set
assert not failing & healthy, failing & healthy
print("ok")
