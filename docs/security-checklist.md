# Security Checklist

## Target and workflow

- [ ] Exact project name is `credit-accounting-development`.
- [ ] Organization, region, Free/Nano/no-cost status, and empty initial state
      were confirmed before linking.
- [ ] Production, shared projects, real data, and existing important users were
      not touched.
- [ ] `development` is the only remote GitHub Environment.
- [ ] Workflow is manual, main-only, exact-SHA, ancestor-checked, and locked.
- [ ] CODEOWNERS review covers workflows, migrations, and hosted configuration;
      branch/environment protection enforces review where the plan supports it.
- [ ] Management project identity, ignored CLI link, and TLS PostgreSQL
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

- [ ] Remote history exactly matches all 24 committed migrations.
- [ ] `app_private` is absent from Data API schemas.
- [ ] All expected exposed tables have enabled and forced RLS.
- [ ] No broad true policy or view bypass exists.
- [ ] Definer functions have fixed empty search paths.
- [ ] `PUBLIC` and `anon` cannot execute privileged functions.
- [ ] Authenticated execution matches the RPC allowlist.
- [ ] Clients and `service_role` cannot mutate raw financial, audit, interest,
      correction, or reversal evidence.
- [ ] Exactly one credential-free, non-HTTP cron job exists.
- [ ] Hosted Security and Performance Advisor codes were reviewed and
      dispositioned.

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
