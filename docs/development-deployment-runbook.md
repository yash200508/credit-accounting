# Development Deployment Runbook

## Preconditions

1. Work only from a clean reviewed commit on `main`.
2. Run Maven, local reset, all 567 pgTAP assertions, four concurrency
   harnesses, scheduler check, lint, hygiene, and Phase 2E preflight.
3. Confirm the safe target name, organization, region, Free/Nano plan, empty
   migration history, empty application schema/data, extensions, cron jobs,
   and Auth users.
4. Obtain explicit user approval before project creation, region selection,
   linking, migration application, GitHub secrets, fake Auth users, or a
   controlled interest cycle.
5. Stop on unexpected data, schema, migration history, user, cost, or project
   identity.

## GitHub Environment

Create only `development`. Require a reviewer where the repository plan
supports it. Configure:

Secrets:

- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_PROJECT_ID`
- `SUPABASE_DB_PASSWORD`

Variables:

- `SUPABASE_EXPECTED_PROJECT_NAME=credit-accounting-development`
- `SUPABASE_EXPECTED_REGION=us-east-2` after region approval
- `SUPABASE_DB_HOST`
- `SUPABASE_DB_PORT`
- `SUPABASE_DB_NAME`
- `SUPABASE_DB_USER`

Enter values through GitHub's secure UI or API only. Never echo, output,
artifact, screenshot, document, or commit a value. The workflow does not use a
secret/service key. Environment protection is the remote-change approval.

## Remote preflight

Read-only checks may run before deployment:

```powershell
npx --yes supabase@2.109.1 projects list --output json
npx --yes supabase@2.109.1 migration list --linked
npx --yes supabase@2.109.1 db push --linked --dry-run
python scripts/phase_2e_preflight.py
python scripts/verify_development_target.py
```

Do not run `db pull`, remote `db reset`, restore, repair, squash, or migration
row updates. Do not use the Dashboard SQL editor for permanent schema.

The preflight scans every migration for local hosts, JWT/key/token shapes,
credentialed database URLs, and HTTP/credentials near the cron definition. It
proves prior migration files are unchanged from Phase 2D, required extensions
and schemas are declared, and exactly one cron registration is committed.
Target verification also proves the TLS PostgreSQL host/user identifies the
same project reference that passed the exact name and region checks. Hosted
bootstrap, functional smoke, concurrency, and backup commands separately
recheck that binding and the ignored local CLI link before any write or dump.

## First approved deployment

The exact mutation sequence is:

```text
link the approved development project
-> push the committed closed Auth/config.toml configuration
-> display db push --dry-run migration identifiers
-> apply db push --linked without seed
-> compare remote migration history to Git
-> run catalog/RLS/grant/cron checks
-> run both hosted advisors
```

`supabase/seed.sql` is local-only and is never included. No JavaFX/SQLite data
is imported.

For later deployments, dispatch
`.github/workflows/supabase-development-deploy.yml` from `main`, enter a full
40-character commit SHA reachable from `main`, and approve the `development`
Environment. The fixed concurrency group prevents overlap.

## Post-deploy validation

Run:

```powershell
psql -X --no-psqlrc -v ON_ERROR_STOP=1 `
  -f supabase/validation/phase_2e_catalog_security.sql

npx --yes supabase@2.109.1 db advisors --linked `
  --type security --level info --fail-on none
npx --yes supabase@2.109.1 db advisors --linked `
  --type performance --level info --fail-on none
```

Record every advisor code and disposition. Fix an applicable finding only in a
new migration, add a regression check, rerun the complete local suite, deploy,
and rerun hosted checks.

After separate approval, run fake Auth/bootstrap, functional smoke, four
hosted races, and the controlled interest cycle as described in the validation
results. Successful append-only fake smoke records remain labeled development.

## Failure and forward fix

- Before a migration commits: inspect sanitized CLI error and locks; correct
  locally; no history was applied.
- Partial/uncertain application: stop all deployers, inspect remote history and
  catalogs read-only, compare to Git, and escalate. Do not repair history
  without a separately reviewed decision.
- Function/grant/RLS/cron mistake: contain exposure first if applicable, then
  create a forward-fix migration.
- Credential exposure: cancel the run, revoke/rotate the credential, audit
  access, then debug.
- Data corruption: stop writers and scheduler, preserve evidence, assess a
  reviewed repair. Do not restore or reset hosted development without a new
  explicit approval.

Applied migrations are never edited, renamed, deleted, or “rolled back” by
removing history.
