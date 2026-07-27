# Incident Response

## Development containment

1. Stop the active deployment, bootstrap, smoke harness, or controlled
   scheduler invocation.
2. Confirm the target is the development project and that production was not
   touched.
3. If any credential or RLS/API exposure is suspected, contain access and
   rotate the affected credential before ordinary debugging.
4. Preserve sanitized timestamps, workflow/run IDs, commit and migration IDs,
   advisor codes, cron status, and audit action metadata. Do not collect JWTs,
   Auth headers, passwords, keys, full connection strings, audit JSON, or PII.
5. Inspect migration history, catalogs, grants, Auth, Data API schemas, locks,
   and immutable evidence read-only.
6. Choose a reviewed forward-fix migration or fake-data repair. Remote
   reset/restore, project deletion, and secret changes retain explicit approval
   gates.

## Decision tree

- **Migration failed before commit:** correct and validate locally; rerun after
  confirming no history row was added.
- **Migration state uncertain or partial:** stop deployers and scheduler;
  compare Git, history, and catalogs; escalate rather than repairing history.
- **Function or grant mistake:** remove reachability with a forward-fix
  migration and add a negative regression check.
- **RLS/Data API exposure:** disable the exposed path, rotate affected
  credentials/tokens, assess access, then forward-fix and rerun security checks.
- **Cron mistake:** unschedule through a reviewed migration using cron
  functions; do not update `cron.job` directly.
- **Fake-data corruption:** stop writers, preserve immutable evidence, reconcile
  ledger/interest/corrections, and apply an audited repair.
- **Credential exposure:** revoke/rotate immediately, review logs and Git
  history, replace only through secure Supabase/GitHub UIs, and rerun target
  validation.

Contacts, severity policy, notification obligations, forensics, legal/privacy
assessment, and production continuity are not defined by Phase 2E. This is an
internal development procedure, not a professional incident-response program.
