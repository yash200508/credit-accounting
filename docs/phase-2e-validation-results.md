# Phase 2E Validation Results

## Scope and starting point

- Branch: `codex/phase-2e-remote-dev-hardening`
- Reviewed starting merge: `0bae407cfda8a973393d306d313006e083596e81`
- Phase 2D PR: #12, present in merged history
- Environment boundary: one development project, deterministic fake data only
- Production, real data, Flutter, Next.js, and QR next slice: untouched

## Official behavior reviewed

Reviewed on 2026-07-27:

- Supabase changelog breaking changes
- deployment and environment management
- CLI link, migration list/push/dump, config push, and advisors help
- GitHub Actions environment variables
- Auth general configuration and admin user creation
- Management API project/Auth/PostgREST inspection
- Data API security and exposed schemas
- pg_cron installation/debugging
- database backups and local restore
- Free-plan pricing, pausing, compute, and regions

CLI 2.109.1 remains pinned; no documented critical incompatibility required an
upgrade.

## Initial local baseline

| Check | Result |
|---|---|
| Java | 17.0.17 |
| Maven | 3.9.12 |
| Maven tests | PASS, 37/37 |
| Local reset | PASS |
| pgTAP | PASS, 567/567 |
| Database lint | PASS |
| Phase 2A concurrency | PASS |
| Phase 2B concurrency | PASS |
| Phase 2C concurrency | PASS |
| Phase 2D concurrency | PASS |
| Scheduler registration | PASS |
| Wall-clock scheduler | Not exercised |
| Repository hygiene | PASS, 147 tracked files at baseline |

## Approval and hosted evidence

The following entries must be filled only from observed results. A pending or
skipped result is never a pass.

| Evidence | Status |
|---|---|
| OAuth handoff | Pending user completion |
| Existing-project read-only discovery | Pending authentication |
| Project creation / region / plan | Pending explicit approval |
| Link and empty-state preflight | Pending explicit approval |
| GitHub `development` Environment and secrets | Pending explicit approval |
| Remote migration application/history | Pending explicit approval |
| Hosted catalogs/RLS/grants/Data API | Pending |
| Security Advisor codes/dispositions | Pending |
| Performance Advisor codes/dispositions | Pending |
| Closed Auth verification | Pending |
| Fake Auth/bootstrap | Pending explicit approval |
| Functional smoke (23 checks) | Pending |
| Four hosted concurrency races | Pending |
| Controlled interest cycle | Pending explicit approval |
| Cron registration | Pending hosted verification |
| Actual wall-clock cron execution | Unverified |
| Logical backup and manifest checksum | Pending |
| Disposable local restore/reconciliation | PASS with synthetic fake-only local dump; hosted-origin backup remains pending |
| Final complete local suite | PASS after final repository changes |

## Local repository-control validation

- Phase 2E migration preflight: PASS for all 24 immutable migrations.
- Hosted catalog SQL: PASS against the current local migrated schema.
- Remote-capable Phase 2A concurrency harness: PASS in local mode.
- Python syntax compilation: PASS.
- Target-binding helper: PASS for direct and pooler forms; mismatched
  PostgreSQL and local-link targets fail closed.
- Logical backup format: PASS using a fake-only local schema/data dump,
  sanitized Auth stubs, manifest checksums, and disposable restore.
- Restore reconciliation: PASS for migration head, schema, RLS, grants,
  functions, triggers, ledger, interest, correction evidence, and cron.
- Cross-platform CLI execution: PASS after resolving `npx`/`npx.cmd`
  explicitly.
- Workflow YAML parse: PASS.
- Repository hygiene: PASS across 174 tracked/untracked non-ignored files.
- `git diff --check`: PASS.

## Final local regression

| Check | Result |
|---|---|
| Maven clean verify | PASS, 37/37 |
| Local reset with normal seed | PASS |
| pgTAP | PASS, 567/567 |
| Phase 2A concurrency | PASS |
| Phase 2B concurrency | PASS |
| Phase 2C concurrency | PASS |
| Phase 2D concurrency | PASS |
| Scheduler registration | PASS |
| Wall-clock scheduler | Not exercised |
| Database lint | PASS, no schema errors |
| Catalog/RLS/grant/function/cron validation | PASS |
| Sanitized operations queries | PASS |
| Phase 2E migration preflight | PASS, 24 immutable migrations |

## Internal review result

The pre-landing and security fallback review found and fixed:

1. Hosted scripts now bind the exact Management/CLI project, ignored local
   link, and TLS PostgreSQL host/user before any write or dump.
2. Python scripts resolve the platform-specific `npx` executable, including
   Windows `npx.cmd`.
3. Closed-Auth verification rejects every enabled external provider except
   email instead of relying on a fixed provider list.
4. CODEOWNERS covers workflows, migrations, and hosted configuration.

No unresolved critical or high-confidence security finding remains in the
Phase 2E diff. Hosted advisors, live configuration, and external-state checks
remain pending and cannot be inferred from local evidence.

An OWASP Dependency-Check 12.2.2 Maven scan was also attempted. Its
vulnerability-feed update did not finish within the 20-minute bound and
produced no report, so dependency-vulnerability status is **unverified**, not a
pass. The timed-out scanner process was stopped; normal Maven compilation and
all 37 tests remain green.

## Known limitations

No client, real-data migration, production project, production workflow,
managed backup, PITR, recovery objective, wall-clock scheduler proof, load
test, completed software-composition vulnerability report, or independent
professional security/financial review is part of this phase.
