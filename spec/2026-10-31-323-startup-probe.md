---
status: draft
issue: 323
repo-issue: olafkfreund/factory-gitops#323
intent: intent/2026-10-31-323-startup-probe.md
---

# Spec: a startupProbe so liveness doesn't cut the boot migration lock wait

## Design

User's decision: on the PFactory, AIFactory and TFactory web-server
containers, add

    startupProbe: { httpGet: { path: /api/health, port: <same as liveness> }, periodSeconds: 10, timeoutSeconds: 5, failureThreshold: 36 }

on the same path and port as each livenessProbe (PFactory 3114, AIFactory
3101, TFactory 3103). That gives 360 s, which covers the 300 s lock wait plus
migration time. Kubernetes holds liveness and readiness until the startup
probe succeeds once.

Liveness and readiness stay unchanged. Liveness `initialDelaySeconds` stays
at 30: nothing else in the repo sets it to 0 behind a startupProbe, and after
startup it only delays the first liveness check by 30 s, which is harmless.

Neither AIFactory nor TFactory had a startupProbe before this change.

## Alternatives rejected

- Raise liveness `initialDelaySeconds`/`failureThreshold`: that also slows
  detection of a wedged pod that is already running.
- Move the migration into an init container: that is an app change, out of
  scope for a manifest fix.
- PFactory only: AIFactory and TFactory are getting the same lock.

## Risks

A pod that never comes up now takes up to 360 s to restart, not about
90–150 s. Each Deployment rolls once.

## Verification

CI manifest-validate passes. `kubectl apply --dry-run=server` of the three
manifests in the factory namespace passes. After sync each rollout completes
and the pods show the startupProbe.
