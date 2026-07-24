# Deployment

## Phase 1: local only

The only supported Phase 1 environment is the local Supabase Docker stack started from this repository with CLI 2.109.1. No project is linked and no remote database command is part of development or CI.

```powershell
npx --yes supabase@2.109.1 start
npx --yes supabase@2.109.1 db reset --local
npx --yes supabase@2.109.1 test db
npx --yes supabase@2.109.1 db lint --local
```

Committed migrations and `supabase/seed.sql` are the reproducible source. `supabase/.temp`, local volumes, `.env`, generated keys, database files, and backups are not committed.

## Environment configuration

`.env.example` documents names only. Local public URL and anon key may be obtained from `supabase status` for development. The service-role key bypasses RLS and must never appear in Flutter, a Next.js client bundle, desktop client code, logs, screenshots, issue text, or source control.

## Future environment promotion

Production deployment is deferred. Before it is authorized:

- create separate development, staging, and production Supabase projects;
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
