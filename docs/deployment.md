# Deployment

## Local validation

Pull-request validation uses the local Supabase Docker stack with CLI 2.109.1.
It never receives a remote token or project reference.

```powershell
npx --yes supabase@2.109.1 start
npx --yes supabase@2.109.1 db reset --local
npx --yes supabase@2.109.1 test db
npx --yes supabase@2.109.1 db lint --local
```

Committed migrations and `supabase/seed.sql` are the reproducible source. `supabase/.temp`, local volumes, `.env`, generated keys, database files, and backups are not committed.

## Environment configuration

`.env.example` documents names only. Local public URL and anon key may be obtained from `supabase status` for development. The service-role key bypasses RLS and must never appear in Flutter, a Next.js client bundle, desktop client code, logs, screenshots, issue text, or source control.

## Phase 2E hosted development

Exactly one fake-data project named `credit-accounting-development` is
permitted after explicit project/region/plan approval. The separate
`supabase-development-deploy.yml` workflow is manual only, main-only,
exact-SHA, locked, and attached to the `development` GitHub Environment. It
does not run for pull requests or every push.

The workflow requires the official current secret names
`SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`, and
`SUPABASE_DB_PASSWORD`. It verifies project name, approved region, closed Auth,
and Data API schemas without printing values. It dry-runs and applies only
committed migrations, never seed/reset/restore, then runs migration, catalog,
RLS/grant/cron, and advisor checks. See the development deployment runbook.

## Future production promotion

Production deployment is deferred. Before it is authorized:

- create separately reviewed staging and production Supabase projects;
- store credentials in environment-scoped secret managers;
- run migrations through reviewed CI/CD with backups and a rollback/forward-fix plan;
- disable production seed execution;
- configure custom domains, TLS, Auth redirect allowlists, SMTP, rate limits, and MFA policy;
- enable monitoring for Auth abuse, database saturation, policy failures, and privileged operations;
- define encrypted backups, retention, restore objectives, and tested restore drills;
- deploy trusted server-side operations separately from public clients;
- perform privacy, security, and operational readiness reviews.

## Rollback posture

Financial schema migrations should be forward-fix oriented once real records exist. Destructive down migrations are not assumed safe. Each production migration must document compatibility, backup requirements, lock/runtime expectations, and reconciliation.
