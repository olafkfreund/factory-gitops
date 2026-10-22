---
status: draft
issue: AIFactory#1737
author: olafkfreund
---

# Intent: keep the gate and build images on the node before a gate Job starts

## Problem

A gate Job's `activeDeadlineSeconds` (600s) starts counting when the Job
starts, so it also pays for pulling the gate image. The gate image
(`AIFACTORY_SANDBOX_IMAGE`, `factory-runner-nix`, ~2.25 GB compressed) and the
build image (`AIFACTORY_BUILD_IMAGE`, `aifactory:sha-...-nix`) are only on the
single node while something has used them recently. After image GC, or after
a pin bump, the next Swift gate pulls cold and can hit the deadline before
`swift test` runs (AIFactory#1737).

## Proposed outcome

Both images stay pulled on every node, ahead of any Job that needs them, and
stay pulled across a pin bump without anyone remembering a second place to edit.

## Affected users and systems

`apps/aifactory/manifests` (namespace `factory`), the k3d node(s), gate and
build Jobs started by AIFactory.

## Constraints

- Same image refs/digests as the two env values, so the cached bytes are the
  bytes the Jobs run.
- Pass Kyverno `verify-factory-image-signatures` (both images are already
  covered and signed), the immutability gate, kubeconform.
- Non-root, read-only, no capabilities; near-zero standing resources.

## Open questions

None. The operator chose option 1 of the issue (pre-pull DaemonSet).
