# ADR 0014: Logical backup and disposable local restore rehearsal

## Status

Accepted.

## Context

The selected Free development plan has no managed backup or PITR guarantee.
Phase 2E needs evidence that fake application state can be recovered without
restoring over the hosted project or storing login credentials in a dump.

## Decision

Create a logical schema dump and application data dump with pinned Supabase
CLI 2.109.1 in ignored `.local-backups/`. Export only sanitized Auth stubs
containing fake user IDs and `.example.test` emails; omit password hashes,
identities, sessions, tokens, and API keys.

Each backup directory records UTC time, safe project alias, migration head,
CLI version, byte sizes, and SHA-256 checksums in `manifest.json`. A scanner
rejects JWTs, Supabase secret/access keys, credentialed PostgreSQL URIs,
non-fake email domains, and unexpected phone-shaped values.

Rehearse recovery only in a newly named, port-isolated local Supabase stack.
Rebuild platform and migration history, replace the application schemas from
the schema dump, add non-login fake Auth stubs, restore application data, then
reconcile migration head, balanced ledger, repayment allocations, interest
components, correction/reversal evidence, forced RLS, required functions, and
cron registration. Stop and remove the disposable stack afterward.

## Consequences

- The backup remains sensitive development data even though it is fake.
- Git plus the logical backup are both required for the rehearsal.
- Auth sessions and usable credentials are intentionally unrecoverable.
- This demonstrates a local logical restore, not hosted disaster recovery,
  PITR, retention, RPO, or RTO.
