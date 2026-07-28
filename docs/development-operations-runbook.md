# Development Operations Runbook

## Safe operating rules

Operate only against the verified `credit-accounting-development` alias.
Never paste full connection strings or log JWTs, Auth headers, passwords,
secret/service keys, access tokens, or full customer data. Use fake data only.
Remote reset, hosted restore, project deletion, fake Auth creation, and
controlled interest execution retain separate explicit approval gates.

The sanitized query pack is
`supabase/validation/phase_2e_operations.sql`. It reports failed interest
runs, catch-up work, pending corrections, lock waits, migration versions, cron
status, recent audit action metadata, database size, table growth, and
fingerprinted slow-query aggregates without SQL text or audit JSON.

## Migration deployment failure

Allow only one deployer through the GitHub concurrency lock. Capture the
migration identifier and sanitized error. Inspect `migration list`, blocking
sessions, and catalog state read-only. Do not rerun blindly if commit state is
uncertain. Use the forward-fix decision tree in the deployment runbook.

## Lock contention

The financial functions intentionally lock idempotency keys, correction
requests/original transactions, and credit accounts in documented order.
Inspect blocker/waiter IDs and durations without query text. Cancel only after
identifying the owner and business impact. A timeout or known domain error is
safer than bypassing a lock. Do not load/stress test the Free project.

## Interest and cron

Inspect `interest_accrual_runs` for `FAILED`, `result_code`, and remaining
catch-up work. Check exactly one active cron job and recent
`cron.job_run_details`. Do not edit `cron.job` directly; change registration
through a migration using supported cron functions.

A controlled TEST cycle requires explicit user approval and
`PHASE_2E_INTEREST_CYCLE_APPROVED=YES`. It is not a substitute for observing a
real wall-clock run. If no hourly run occurs during Phase 2E, record wall-clock
execution as unverified.

## Correction failures

Inspect pending request ID, type, version, station, and dependency result
without exposing explanation text. Never mutate request/event/reversal tables
or the original transaction. Correct a function or grant through a migration;
resolve a business correction through the maker-checker RPCs.

## Auth and RLS denial

First distinguish expected denial from target/config drift. Verify closed Auth,
Data API schemas, active memberships, role scope, and server-side derivation of
`auth.uid()`. Never add a broad policy, put roles in editable metadata, expose
`app_private`, or grant raw financial mutation to make a smoke test pass.

## Advisors and slow queries

Run Security and Performance Advisors independently. Record code, severity,
applicability, evidence, and disposition. Treat findings as review input.
Investigate `pg_stat_statements` by query ID/fingerprint, calls, and timing;
retrieve raw SQL only in a controlled session after checking for literals.

## Backup and restore

Follow the dedicated runbook. Backups remain outside Git, checksummed, scanned,
and access-controlled. Restore only into the disposable local rehearsal.

## Incident containment

1. Stop the deployment or fake-data writer.
2. For exposure, disable the affected path and rotate credentials before
   ordinary debugging.
3. Preserve sanitized run IDs, migration IDs, timestamps, audit action
   metadata, and advisor codes.
4. Confirm production was not touched.
5. Decide on a reviewed forward-fix migration, fake-data repair, or project
   shutdown.
6. Project deletion, hosted restore/reset, and secret changes require their
   own explicit approvals.

## Secret rotation

Rotate through Supabase/GitHub secure UIs. Replace the `development`
Environment secret without printing it, invalidate the old token/key/password,
and rerun target verification and the manual workflow. Never put the old or
new value in an issue, PR, artifact, or command transcript.

## Development shutdown

Disable scheduled work and deployments, revoke credentials, preserve any
approved logical backup, and confirm no dependent app exists. Deleting the
hosted project requires an exact target display and explicit approval; this
runbook does not authorize deletion.
