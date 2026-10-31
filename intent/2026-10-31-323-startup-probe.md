---
status: approved
issue: 323
repo-issue: olafkfreund/factory-gitops#323
author: olafkfreund
---

# Intent: a startupProbe so liveness doesn't cut the boot migration lock wait

## Problem

The PFactory web Deployment has no startupProbe. Its livenessProbe
(`/api/health`, `initialDelaySeconds: 30`, `periodSeconds: 20`,
`failureThreshold: 6`) kills a pod that hasn't answered within about 150 s.
The boot migration runs before the app serves, so a pod waiting on the
advisory migration lock (PFactory #981/#982, 300 s `lock_timeout`) is
restarted before the wait ends and crash-loops, and the lock holder's own
migration is killed if it runs past about 150 s. AIFactory (#1998) and
TFactory (#1488) are getting the same lock and have the same liveness shape
(default `failureThreshold: 3`, so about 90 s).

## Proposed outcome

All three web pods get up to 360 s to start before liveness applies.
Liveness and readiness behave as today once the pod has started.

## Affected users and systems

`apps/{pfactory,aifactory,tfactory}/manifests/manifests.yaml`, the web-server
Deployment only. Each Deployment rolls once.

## Constraints

Don't loosen liveness for a running pod. Touch nothing else.

## Open questions

None.
