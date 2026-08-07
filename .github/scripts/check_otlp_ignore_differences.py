"""Every otel-otlp-auth consumer must be reconciler-rollable. Factory#606.

Three things have to agree or the rotation silently stops reaching pods again:

  1. the Deployments that mount `otel-otlp-auth` via secretKeyRef,
  2. the `CONSUMERS` list in observe's sync.py and the `resourceNames` on its
     Role, which decide what actually gets rolled,
  3. each of those Deployments' ArgoCD Application ignoring the annotation the
     reconciler stamps -- otherwise selfHeal strips it and rolls a second time.

A new service that starts exporting traces and is not added to all three gets
the #606 behaviour back, quietly. This is the check that says so.

Stdlib only, so it needs no PyYAML in CI: the manifests are hand-written and
regular, and the two facts here are single tokens on a line.
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
ANNOTATION = "otlp-auth-resourceversion"
POINTER = f"/spec/template/metadata/annotations/{ANNOTATION}"

# Deployments that read the header from the Secret.
mounts = set()
for manifest in sorted((REPO / "apps").glob("*/manifests/manifests.yaml")):
    if re.search(r"secretKeyRef:\s*\{\s*name:\s*otel-otlp-auth", manifest.read_text()):
        # The consumer Deployment is the one named after the app directory.
        mounts.add(manifest.parts[-3])

if not mounts:
    # Rule 4.7: a gate that cannot find its subject fails, it does not pass.
    raise SystemExit("::error::found no otel-otlp-auth consumers at all; this check is broken")

script = (REPO / "apps/observe/manifests/manifests.yaml").read_text()
declared = set(re.search(r"CONSUMERS = \(([^)]*)\)", script).group(1).replace('"', "").split(", "))
declared = {d.strip() for d in declared if d.strip()}
role = set(re.search(r'resourceNames: \["aifactory[^\]]*\]', script).group(0)
           .split("[")[1].rstrip("]").replace('"', "").split(", "))

failures = []
if declared != mounts:
    failures.append(f"sync.py CONSUMERS {sorted(declared)} != actual consumers {sorted(mounts)}")
if role != mounts:
    failures.append(f"Role resourceNames {sorted(role)} != actual consumers {sorted(mounts)}")

for app in sorted(mounts):
    application = REPO / "apps" / app / "application.yaml"
    if POINTER not in application.read_text():
        failures.append(f"{app}/application.yaml does not ignore {POINTER}; "
                        "selfHeal will strip the annotation and roll it twice")

for line in sorted(mounts):
    print(f"ok   {line}: mounts the Secret, is rolled, and ignores the annotation")

if failures:
    print("::error::" + "; ".join(failures))
    sys.exit(1)
print(f"all {len(mounts)} consumers wired end to end")
