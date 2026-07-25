# Audit-chain SIEM forwarding (Factory#313)

The Factory suite keeps a tamper-evident audit trail — CFactory's HMAC hash
chain over every security-relevant action (HITL approvals, gate rejections,
auth failures, authz denials; `cfactory/audit.py`). Those rows previously lived
only in per-service Postgres. There was no central, cross-service place to
search them, which is the last open gap in the audit-logging control (#313).

`apps/audit-siem-forward` closes it: a hardened CronJob periodically copies new
audit rows into the deployed OpenObserve (`apps/observe`), the fleet's telemetry
backend, so an assessor or analyst has one searchable security view.

## What is forwarded

The job reads the read-only `GET /api/audit` surface on CFactory — the exact
same endpoint the `apps/audit-anchor-alert` integrity check consumes — and
forwards each audit entry **verbatim**, so the chain is fully reconstructable in
OpenObserve. Every original field is preserved, including:

- `id` — monotonic row id (also the incremental cursor; see below)
- `prev_hash` / `entry_hash` — the HMAC chain links (tamper evidence survives)
- `ts` — when the action happened
- the action detail (actor, action type, target, decision, etc.)

One field is added: `_timestamp`, set to the entry's own `ts` in microseconds,
so OpenObserve indexes each record by **when the action occurred**, not when it
was shipped.

Nothing is transformed or redacted — this is a faithful mirror of the source of
truth, which is what an audit control requires.

## The stream

All records land in a dedicated OpenObserve stream:

- **Organization:** `default`
- **Stream:** `audit_chain` (type: logs)

Keeping it in its own stream isolates the security trail from the operational
telemetry (per-worker spans/metrics) already in OpenObserve.

## Schedule and delivery semantics

- **Schedule:** every 15 minutes (`*/15 * * * *`), `concurrencyPolicy: Forbid`.
- **Incremental:** each run asks OpenObserve for the maximum `id` already in
  `audit_chain` (the high-water mark) and forwards only entries with a greater
  id. The **sink itself is the cursor** — there is no separate state store to
  drift out of sync. On the very first run (empty/absent stream) the mark is 0
  and the whole chain is backfilled.
- **Idempotent:** because the mark is re-read from what actually landed, a
  re-run after a partial failure simply resumes; it does not duplicate rows.
- **Fail-loud:** if CFactory or OpenObserve is unreachable, or OpenObserve
  rejects the ingest, the job exits non-zero. A failed Job is the alert — the
  same convention as `apps/audit-anchor-alert` (the cluster has no
  Alertmanager). Check with `kubectl -n factory get jobs -l app=audit-siem-forward`.

## Credentials (all reused, nothing new to create)

No new operator secret is required. The job reuses:

- `observe-root` (`email`, `password`) — OpenObserve HTTP Basic login, the same
  secret `apps/observe` already needs. Used for both the high-water-mark search
  and the ingest.
- `cfactory-api-keys` (`api-key`, **optional**) — sent as a bearer to `/api/*`
  if/when the CFactory keystore is enforced, exactly as `apps/audit-anchor-alert`
  does. Absent secret means no header, which is correct while the keystore is
  open.

If either OpenObserve credential is missing the job fails fast with a clear
`FATAL` message rather than shipping nothing silently.

## How an assessor / analyst queries it in OpenObserve

1. Open OpenObserve at `https://observe.freundcloud.org.uk` (Keycloak SSO), then
   log in to OpenObserve itself with the `observe-root` credentials.
2. **Logs -> select stream `audit_chain` -> org `default`.** Pick a time range;
   records are indexed by the action's own timestamp (`_timestamp`).
3. Search with SQL, for example:

   ```sql
   -- everything in the last 24h, newest first
   SELECT * FROM "audit_chain" ORDER BY id DESC

   -- only authentication failures
   SELECT ts, id, actor, action, target
   FROM "audit_chain"
   WHERE action = 'auth.failure'
   ORDER BY id DESC

   -- gate rejections and authz denials across all services
   SELECT * FROM "audit_chain"
   WHERE action IN ('gate.reject', 'authz.deny')

   -- confirm the forwarder is current (max id present centrally)
   SELECT max(id) AS max_id FROM "audit_chain"
   ```

   (Field names other than `id`/`ts`/`prev_hash`/`entry_hash` mirror whatever
   `/api/audit` returns; browse one record to see the exact keys.)

## Verifying tamper-evidence centrally

The `prev_hash`/`entry_hash` links travel with each row, so a broken chain is
visible in OpenObserve — a row whose `prev_hash` does not equal the previous
row's `entry_hash` indicates deletion, reorder, or tamper. Full HMAC
recomputation remains CFactory's job (`AuditStore.verify`); OpenObserve gives
the central, searchable, retained copy that an assessor reviews, and
`apps/audit-anchor-alert` remains the active integrity alarm.

## Scope / follow-ups

- **Retention** of the `audit_chain` stream is governed by OpenObserve's own
  retention (see `apps/observe`), separate from the Postgres retention set in
  factory-gitops#67. For a formal evidence-retention window, set an explicit
  stream retention in OpenObserve.
- **Source seam.** Today CFactory's `/api/audit` is the one HTTP-exposed audit
  surface, and its chain is the canonical fleet audit trail. If other services
  grow their own independently-exposed audit endpoints, add them as extra source
  URLs here (the forwarder logic is source-agnostic apart from the base URL).
