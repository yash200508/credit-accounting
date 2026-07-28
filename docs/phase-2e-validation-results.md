# Phase 2E Validation Results

## Scope and starting point

- Branch: `codex/phase-2e-remote-dev-hardening`
- Hardening starting commit: `cae774d2bad2ae34e7425edf94ecdd590931e5c7`
- Phase 2D PR: #12, present in merged history
- Environment boundary: linked project `pjjbjeqkktxnphavolvf`, development and
  fake data only
- Production, real data, Flutter, Next.js, and QR next slice: untouched
- Hosted migration head is migration 25,
  `20260727213829_phase_2e_privilege_default_acl_hardening.sql`. All 25
  migration versions match locally and remotely.

## Official behavior reviewed

Reviewed on 2026-07-27:

- Supabase changelog breaking changes
- deployment and environment management
- CLI link, migration list/push/dump, config push, and advisors help
- GitHub Actions environment variables
- Auth general configuration and admin user creation
- Management API project/Auth/PostgREST inspection
- Data API security and exposed schemas
- PostgreSQL default-privilege semantics
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
| OAuth handoff | PASS; official CLI browser login completed without recording credentials |
| Existing-project read-only discovery | PASS; one non-matching Mumbai project excluded and untouched |
| Project creation / region / plan | PASS; `credit-accounting-development`, Mumbai `ap-south-1`, Free/Nano, US$0 upfront and US$0/month |
| Link and empty-state preflight | PASS; exact reference verified; zero Auth users and no application objects before deployment |
| GitHub `development` Environment and secrets | Pending explicit approval |
| Remote migration application/history | PASS; migration 25 deployed successfully and all 25 local and remote versions match |
| Hosted catalogs/RLS/grants/Data API | PASS after migration 25; privilege/default-ACL hardening and Data API exposure verified |
| Security Advisor codes/dispositions | Reviewed; 11 instances of `0029_authenticated_security_definer_function_executable` are intentional allowlisted RPCs |
| Performance Advisor codes/dispositions | Reviewed; 62 composite-FK and 115 fresh-project unused-index findings triaged separately |
| Closed Auth verification | PASS; seven expected fake users, seven identities, protected development markers, and zero unexpected users |
| Fake Auth/bootstrap | PASS; minimum deterministic fake application state created with all financial evidence tables empty |
| Functional smoke (23 checks) | Pending |
| Four hosted concurrency races | Pending |
| Controlled interest cycle | Pending explicit approval |
| Cron registration | PASS; exactly one unchanged hourly job owned by `postgres`; scheduler not manually invoked |
| Actual wall-clock cron execution | Unverified |
| Logical backup and manifest checksum | Pending |
| Disposable local restore/reconciliation | PASS with synthetic fake-only local dump; hosted-origin backup remains pending |
| Final complete local suite | PASS after final repository changes |

The organization is `surya lakshmi fuels point`. Its earlier non-matching
Mumbai project remains excluded and untouched. A separately approved Free/Nano
project named `credit-accounting-development` was created in `ap-south-1`,
linked by exact reference, inspected while empty, and received only the first
25 committed migrations. A separately approved bootstrap then created only
seven fake Auth users and the deterministic development fixtures described
below. No local seed, hosted test, scheduler invocation, configuration change,
real data, reset, restore, or paid feature was applied.

The same read-only check confirmed that Free permits two active projects, the
existing active project consumes one slot, and one slot remains. Mumbai's
exact identifier is `ap-south-1`; the live quote for a second Free project is
US$0/month with no upfront creation charge. Nano uses shared CPU and up to
0.5 GB RAM with a 500 MB recommended database maximum. Free projects can
pause after about seven days of low activity, do not include managed automatic
backups or PITR, and require an off-platform logical-backup procedure. No
charge, upgrade, add-on, or paid feature was accepted.

## Hosted catalog and advisor findings

The post-deployment read-only verification found:

- all 25 remote migration versions matched the committed 25-version history;
- 30 expected `public` application tables, no unexpected application table or
  view, forced RLS on every application table, and no broad `true` policy;
- `app_private` present as the internal schema but absent from the live Data
  API schema list; only `public` and `graphql_public` were exposed, `cron`
  remained unexposed, and automatic new-table exposure remained off;
- required `btree_gist` in `extensions` and managed `pg_cron` installed;
- fixed empty `search_path` on reviewed `public` and `app_private` functions;
- only RLS-scoped authenticated `SELECT` on the three interest-evidence
  tables, zero `service_role` public application-table privileges, zero
  `service_role` application-RPC grants, and no service-role
  mutation/maintenance privilege on `audit_events`;
- active safe default ACLs for future `postgres`-owned public tables,
  sequences, and functions;
- one active job named `credit-accounting-hourly-interest-accrual`, scheduled
  at `7 * * * *`, executing only
  `select app_private.run_hourly_interest_accrual();` as `postgres`;
- 11 intentional authenticated `SECURITY DEFINER` RPC findings under Security
  Advisor code `0029_authenticated_security_definer_function_executable`;
- 62 Performance Advisor composite-foreign-key findings and 115
  fresh-project `unused_index` findings.

No unexpected schema, migration, trigger, business function, policy, or cron
job drift was found. The committed hosted catalog/security verifier passed.
Migration 25 resolved the privilege drift caused by legacy automatic Data API
grants and incomplete earlier revocations.

## Hosted fake bootstrap evidence

The approved bootstrap created exactly seven synthetic `.example.test` Auth
users: Owner A, Owner B, Manager, Attendant, Customer, Driver, and an
authenticated unauthorized actor. Owner A and Owner B are active organization
owners; Manager and Attendant have active station membership and their
respective station-scoped roles; Customer and Driver are active organization
members with their protected roles; the unauthorized actor has no
organization membership, station membership, role, customer, or driver row.
Authorization remains in protected database tables rather than editable Auth
metadata.

The application fixture contains exactly one
`DEVELOPMENT DEMO ORGANIZATION - NOT REAL DATA` organization and one
`DEVELOPMENT MUMBAI STATION - NOT REAL` station in `Asia/Kolkata`, with no
real address. It has seven profiles, six organization memberships, two
station memberships, six role assignments, one fake customer, one INR credit
account with a 1,000,000-paise limit, one linked driver with 50,000-paise
transaction and 100,000-paise daily limits, Petrol and Diesel products, and
one enabled 18% `AFTER_GRACE_ONLY` policy using a 365-day basis. Principal,
interest, and total due are zero; available credit is the full 1,000,000
paise.

All ledger, fuel-sale, repayment, allocation, interest-accrual, correction,
reversal, proposal, and idempotency evidence tables remained empty. No QR
credential was created. Passwords were generated randomly and persisted only
in ignored, untracked `.local-state/phase-2e-auth.json`; no value was printed,
documented, or committed. Admin user creation sent no invitations or SMS.
Post-bootstrap verification again found forced RLS on all 30 application
tables, no broad true policy, zero service-role application-table or public
RPC privileges, zero raw financial mutation grants, the exact 11 authenticated
public `SECURITY DEFINER` RPCs, safe default ACLs, the unchanged one cron job,
and only `public` plus `graphql_public` exposed through the Data API.

## Privilege root causes and decisions

The original foundation migration revoked generated table privileges from
`PUBLIC`, `anon`, and `authenticated`, but omitted `service_role`. Later
financial migrations revoked `service_role` correctly, which explains why
only the 15 earliest foundation tables retained the hosted generated grants.
The interest-evidence migration granted `authenticated` `SELECT` without first
revoking every generated privilege from that role. The earlier schema-scoped
function default revoke also did not cancel PostgreSQL's global built-in
`PUBLIC EXECUTE` default.

The new migration first revokes all `authenticated` privileges on
`interest_accrual_components`, `interest_accrual_runs`, and
`interest_accruals`, removing the generated `TRUNCATE`, `REFERENCES`,
`TRIGGER`, and `MAINTAIN` capabilities while granting back only the intended
`SELECT`. Existing forced RLS and the three scoped read policies remain
unchanged.

No trusted application workflow uses a service key for SQL table or RPC
access. The hosted bootstrap script uses the key only with the Auth Admin API,
while database fixtures use an owner connection. “All hosted table
privileges” below is the catalog-reported set `SELECT`, `INSERT`, `UPDATE`,
`DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER`, and `MAINTAIN`. The final
`service_role` table allowlist is therefore empty:

| Table reviewed | Hosted privilege before hardening | Required | Reason | Final privilege |
|---|---|---:|---|---|
| `app_settings` | all hosted table privileges | No | no server-side SQL workflow | none |
| `audit_events` | all hosted table privileges | No | immutable evidence; no operational reader requires it | none |
| `credit_accounts` | all hosted table privileges | No | trusted mutations use database functions | none |
| `customer_account_settings` | all hosted table privileges | No | no server-side SQL workflow | none |
| `customer_drivers` | all hosted table privileges | No | no server-side SQL workflow | none |
| `customers` | all hosted table privileges | No | no server-side SQL workflow | none |
| `driver_permissions` | all hosted table privileges | No | authorization data has no service bypass | none |
| `interest_policies` | all hosted table privileges | No | policy changes require reviewed workflows | none |
| `organization_memberships` | all hosted table privileges | No | authorization data has no service bypass | none |
| `organizations` | all hosted table privileges | No | no server-side SQL workflow | none |
| `profiles` | all hosted table privileges | No | Auth administration does not require table access | none |
| `qr_credentials` | all hosted table privileges | No | credential metadata has no service bypass | none |
| `role_assignments` | all hosted table privileges | No | authorization data has no service bypass | none |
| `station_memberships` | all hosted table privileges | No | authorization data has no service bypass | none |
| `stations` | all hosted table privileges | No | no server-side SQL workflow | none |

The local migration-24 reconstruction showed the same affected 15-table set
with residual `TRUNCATE`, `REFERENCES`, `TRIGGER`, and `MAINTAIN` grants,
confirming that a DML-only check would be insufficient. The hardening
migration uses `REVOKE ALL`, covering those privileges and any hosted
`SELECT`, `INSERT`, `UPDATE`, or `DELETE` grant, including all access to
`audit_events`.

The four hosted `service_role` RPC grants were also unnecessary:

| RPC reviewed | Hosted privilege | Required | Reason | Final privilege |
|---|---|---:|---|---|
| `create_customer_with_credit_account` | `EXECUTE` | No | normal authenticated workflow derives and authorizes the actor | none |
| `get_credit_account_balance` | `EXECUTE` | No | authenticated scoped read only | none |
| `get_my_driver_parent_account` | `EXECUTE` | No | self-scoped authenticated lookup | none |
| `post_fuel_credit_transaction` | `EXECUTE` | No | normal authenticated posting boundary | none |

The migration revokes every current public table, sequence, and function
privilege from `service_role`; its public table and RPC allowlists are empty.

The authenticated public `SECURITY DEFINER` allowlist contains exactly these
11 RPCs:

1. `approve_and_execute_financial_correction`
2. `cancel_financial_correction_request`
3. `create_customer_with_credit_account`
4. `get_credit_account_balance`
5. `get_credit_account_obligations`
6. `get_financial_correction_impact`
7. `get_my_driver_parent_account`
8. `post_customer_repayment`
9. `post_fuel_credit_transaction`
10. `reject_financial_correction_request`
11. `submit_financial_correction_request`

The verifier resolves these by exact signature and requires fixed empty
`search_path`, `auth.uid()` actor derivation, server-side tenant/role
authorization (or the self-scoped driver-parent lookup), no dynamic SQL, no
caller-supplied actor or organization argument, an explicit `authenticated`
execution ACL, and no `PUBLIC` or `anon` execution.

## Default ACL and cron decisions

For future `postgres`-owned objects in `public`, table and sequence privileges
are revoked from `PUBLIC`, `anon`, `authenticated`, and `service_role`.
Function execution is revoked globally from `PUBLIC` and in `public` from all
three Data API roles. All future application access must be granted explicitly
by a reviewed migration. Application objects must continue to be created by
the `postgres` migration owner; managed extension objects created by
`supabase_admin` remain platform-owned.

The managed `pg_cron` extension owns dormant PUBLIC ACLs on `cron.job`,
`cron.job_run_details`, and five scheduling functions. The migration owner
cannot safely alter those `supabase_admin`-owned extension ACLs. The supported
boundary is therefore a complete schema-usage revoke from `PUBLIC`, `anon`,
`authenticated`, and `service_role`, preserving the unchanged owner-run job.
Tests and the catalog verifier pin the exact dormant extension ACL set and
fail on direct API-role grants, schema access, job drift, or loss of owner
execution.

The pinned unreachable PUBLIC ACLs are `SELECT` on `cron.job`, `SELECT` and
`DELETE` on `cron.job_run_details`, and `EXECUTE` on
`job_cache_invalidate()`, both `schedule(...)` overloads, and both
`unschedule(...)` overloads. These are recorded as a managed extension
boundary, not as application permission.

The 62 foreign-key findings are individually dispositioned in
`phase-2e-performance-advisor-triage.md`. All have a valid left-prefix index
for the current workload; no composite index is added without realistic
query-plan evidence. The 115 unused-index findings are not actionable on an
empty fresh project and no index is removed.

**Deployment status:** the privilege/default-ACL migration was applied
successfully to the isolated hosted development project. Hosted and local
state both contain the same 25 committed migrations.

## Local repository-control validation

- Phase 2E migration preflight: PASS for 25 committed migrations; the original
  24 are immutable and migration 25 is the only addition.
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
- Repository hygiene: PASS across 177 tracked/untracked non-ignored files.
- `git diff --check`: PASS.

## Final local regression

| Check | Result |
|---|---|
| Maven clean verify | PASS, 37/37 |
| Local reset with normal seed | PASS, all 25 migrations |
| pgTAP | PASS, 586/586 (existing 567 plus 19 hardening assertions) |
| Phase 2A concurrency | PASS |
| Phase 2B concurrency | PASS |
| Phase 2C concurrency | PASS |
| Phase 2D concurrency | PASS |
| Scheduler registration | PASS |
| Wall-clock scheduler | Not exercised |
| Database lint | PASS, no schema errors |
| Catalog/RLS/grant/function/cron validation | PASS |
| Sanitized operations queries | PASS |
| Phase 2E migration preflight | PASS, 25 committed migrations; head `20260727213829` |
| Repository hygiene | PASS, 177 files inspected |
| `git diff --check` | PASS |

## Internal review result

The pre-landing and security fallback review found and fixed:

1. Hosted scripts now bind the exact Management/CLI project, ignored local
   link, and TLS PostgreSQL host/user before any write or dump.
2. Python scripts resolve the platform-specific `npx` executable, including
   Windows `npx.cmd`.
3. Closed-Auth verification rejects every enabled external provider except
   email instead of relying on a fixed provider list.
4. CODEOWNERS covers workflows, migrations, and hosted configuration.
5. The privilege hardening now removes complete privilege sets rather than
   checking only DML, including `TRUNCATE`, `TRIGGER`, `REFERENCES`, and
   `MAINTAIN`.
6. PostgreSQL's built-in future-function `PUBLIC EXECUTE` is revoked at the
   required global default-ACL scope; schema-local default ACLs cover the Data
   API roles.
7. Managed `pg_cron` PUBLIC object ACLs are treated as unreachable,
   extension-owned state: schema access is denied and their exact set is
   pinned for drift detection instead of attempting an unauthorized owner
   mutation.

No unresolved critical or high-confidence security finding remains in the
Phase 2E migration or its verified hosted catalog state. The separately
approved deployment and read-only post-deployment catalog, Data API, Security
Advisor, and Performance Advisor reruns are complete. Security Advisor still
reports exactly the 11 intentional allowlisted rule-0029 warnings. Performance
Advisor still reports 62 unindexed-foreign-key and 115 unused-index
informational findings; neither advisor result was altered or overstated.

An OWASP Dependency-Check 12.2.2 Maven scan was also attempted. Its
vulnerability-feed update did not finish within the 20-minute bound and
produced no report, so dependency-vulnerability status is **unverified**, not a
pass. The timed-out scanner process was stopped; normal Maven compilation and
all 37 tests remain green. Maven also emitted the existing Log4j2
SimpleLogger fallback warning; it did not affect compilation or tests.

## Known limitations

No client, real-data migration, production project, production workflow,
managed backup, PITR, recovery objective, manual scheduler invocation,
wall-clock scheduler proof, hosted functional/concurrency test, load test,
completed software-composition vulnerability report, GitHub development
secrets/environment configuration, or independent professional
security/financial review is part of the completed work to date. No real
customer data exists in the development project; its only application data is
the approved synthetic bootstrap. The excluded pre-existing Supabase project
remains untouched.
