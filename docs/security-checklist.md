# Security Checklist

## Target and workflow

- [x] Exact project name is `credit-accounting-development`.
- [x] Organization, region, Free/Nano/no-cost status, and empty initial state
      were confirmed before linking.
- [x] Production, shared projects, real data, and existing important users were
      not touched.
- [ ] `development` is the only remote GitHub Environment.
- [ ] Workflow is manual, main-only, exact-SHA, ancestor-checked, and locked.
- [ ] CODEOWNERS review covers workflows, migrations, and hosted configuration;
      branch/environment protection enforces review where the plan supports it.
- [x] Management project identity, ignored CLI link, and TLS PostgreSQL
      host/user all resolve to the same approved project before a write or dump.
- [ ] No `pull_request_target`, PR secrets, mutable action tag, remote reset,
      hosted restore, or production workflow exists.

## Secrets and Auth

- [ ] Token, project reference, and database password are secure Environment
      secrets; values never appear in Git, logs, outputs, artifacts, docs, or
      screenshots.
- [ ] No service/secret key is stored in GitHub or a client variable.
- [ ] Public signup and anonymous sign-in are disabled.
- [ ] No social provider, production SMTP, wildcard/production redirect, or
      real identity is configured.
- [ ] Fake passwords exist only in ignored local state.
- [ ] Authorization uses protected database roles/memberships, not editable
      Auth metadata.

## Database and API

- [x] Remote history exactly matches all 25 committed local migrations.
- [x] Data API exposure is limited to `public` and `graphql_public`;
      `app_private` and `cron` are absent and automatic new-table exposure is
      off.
- [x] All expected exposed tables have enabled and forced RLS.
- [x] No broad true policy or view bypass exists.
- [x] Definer functions have fixed empty search paths.
- [x] `PUBLIC` and `anon` cannot execute privileged application functions.
- [x] Authenticated execution matches the 11-public-RPC and private-helper
      allowlists.
- [x] The hosted project has applied migration 25 so clients and
      `service_role` cannot mutate raw financial, audit, interest,
      correction, or reversal evidence.
- [x] Hosted migration 25 removes every current `service_role` public
      application-table, sequence, and application-RPC grant; both hosted
      allowlists are intentionally empty.
- [x] `authenticated` has only RLS-scoped `SELECT` on the three interest
      evidence tables.
- [x] `audit_events` has no service-role mutation or maintenance privilege.
- [x] `postgres` default ACLs keep future public tables, sequences, and
      functions private until explicitly granted.
- [x] Exactly one credential-free, non-HTTP cron job exists.
- [x] API roles have no `cron` schema usage; the verifier pins the exact
      unreachable, extension-owned PUBLIC object ACLs.
- [x] Hosted Security and Performance Advisor codes were reviewed and
      dispositioned.
- [x] Hosted catalogs and both Advisors were rerun read-only after migration
      25; the catalog verifier passed, Security Advisor retained exactly 11
      allowlisted rule-0029 warnings, and Performance Advisor retained 62
      unindexed-FK plus 115 unused-index informational findings.

## Validation, backup, and operations

- [ ] Functional smoke uses only fake reserved identities/data and normal APIs.
- [ ] Four independent-session hosted races pass without load testing.
- [ ] Controlled interest execution has separate approval.
- [ ] Wall-clock scheduler status is reported truthfully.
- [ ] Logical backup is outside Git, scanned, checksummed, and access-controlled.
- [ ] Disposable local restore reconciles schema, migration head, RLS,
      functions, ledger, interest, correction evidence, and cron.
- [ ] Operations queries omit query text, audit JSON, full PII, and credentials.
- [ ] Forward-fix and exposure-containment procedures are documented.

This checklist supports internal engineering review only; it is not an
independent professional security, financial, legal, tax, or compliance audit.
