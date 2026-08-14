# Phase 2E Validation Results

## Scope and starting point

- Branch: `codex/phase-2e-hosted-validation-completion`
- Hardening starting commit: `cae774d2bad2ae34e7425edf94ecdd590931e5c7`
- Phase 2D PR: #12, present in merged history
- Environment boundary: linked project `pjjbjeqkktxnphavolvf`, development and
  fake data only
- Production, real data, Flutter, Next.js, and QR next slice: untouched
- Hosted migration head is migration 25,
  `20260727213829_phase_2e_privilege_default_acl_hardening.sql`. All 25
  migration versions match locally and remotely.

## Official behavior reviewed

Reviewed on 2026-07-27, with hosted connection behavior rechecked on
2026-08-14:

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
| Hosted functional + authorization smoke | PASS; run `03FAFE4C03CA` completed the full approved matrix with 8 balanced ledger transactions and zero failed-request partial rows |
| Four hosted concurrency races | PASS; run `E6C1546C6CCE`, four bounded two-session races, seven balanced run transactions, and zero partial state |
| Controlled interest cycle | PASS; approved private `TEST` path posted 8 paise for the successful run using two 365-day simple-interest components; private Data API access remained denied |
| Cron registration | PASS; exactly one unchanged hourly job owned by `postgres`; scheduler was not manually invoked |
| Actual wall-clock cron execution | Natural zero-work `SCHEDULER` runs observed; no wait or manual invocation was performed, so this is not treated as a formal wall-clock test |
| Logical backup and manifest checksum | Pending |
| Disposable local restore/reconciliation | PASS with synthetic fake-only local dump; hosted-origin backup remains pending |
| Final complete local suite | PASS after final repository changes |

The organization is `surya lakshmi fuels point`. Its earlier non-matching
Mumbai project remains excluded and untouched. A separately approved Free/Nano
project named `credit-accounting-development` was created in `ap-south-1`,
linked by exact reference, inspected while empty, and received only the first
25 committed migrations. A separately approved bootstrap then created only
seven fake Auth users and the deterministic development fixtures described
below. The later separately approved functional gate added only synthetic
test evidence. No local seed, manual scheduler invocation, configuration
change, real data, reset, restore, or paid feature was applied.

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

## Hosted functional and authorization smoke

The repository-controlled hosted harness is
`supabase/tests/remote/phase_2e_functional_smoke.py`. It binds the exact
project reference, organization, Mumbai region, healthy status, local link,
and matching 25-version migration history before any write. It obtains the
normal publishable client key only in process memory, signs in the exact seven
fake users from ignored local state, and uses each actor's normal JWT for
application behavior. The only database-owner mutation paths are the
committed idempotent second-tenant fixture and the explicitly approved
private interest-cycle call. No password, JWT, API key, refresh token,
connection string, or real-world data is logged or committed.

Successful run `03FAFE4C03CA` proved:

- Owner A and Manager customer/account creation succeeded with zero starting
  obligation; Attendant and the second-tenant actor were denied primary-tenant
  creation with `CCC_FORBIDDEN`.
- Attendant fuel credit posted 10,000 paise as receivable debit / sales
  revenue credit; principal became 10,000, available credit 20,000, and
  interest remained zero. Exact replay was stable and changed-payload reuse
  returned `FCP_IDEMPOTENCY_CONFLICT`.
- Customer, Driver, second-tenant, and anonymous fuel posting were denied.
  Principal repayment of 2,000 paise posted cash debit / receivable credit;
  overpayment and zero-due interest allocation were denied, and repayment
  replay/conflict behavior was deterministic.
- `app_private` returned `PGRST106` for every authenticated fake actor and
  anonymous access. The controlled private path then posted two daily
  simple-interest components, 8 paise total, on an 8,000-paise principal base
  using 18% / 365. Interest did not consume credit. The 8-paise interest-only
  repayment posted cash debit / interest-receivable credit without changing
  principal or available credit.
- Manager submitted one pending `REVERSAL_ONLY` request without changing its
  original. Owner A self-approval returned
  `COR_SELF_APPROVAL_FORBIDDEN`; Owner B approved a separate Owner A request.
  Its 4,000-paise positive reversal exactly swapped the original debit and
  credit entries, retained both immutable transactions, and preserved the
  permanent request/reversal link.
- Cross-tenant and role read policies were proven with positive same-scope
  counterparts. Anonymous access was denied. Direct ledger insert,
  update/reclassification, and delete, plus audit, correction-event, and
  interest-evidence mutations, all returned SQLSTATE `42501`.

The successful run created exactly 3 customers, 3 accounts, 3 fuel sales,
2 repayments, 2 allocations, 2 interest accruals with 2 components,
8 ledger transactions with 16 entries, 5 idempotency records, 2 correction
requests, 4 correction events, 1 reversal, and 14 audit events. Every ledger
transaction had exactly two entries and equal positive debit/credit totals.
Every intentionally denied request had zero count drift.

Nine earlier functional-harness attempts stopped on test-code assertions
after some already-successful synthetic RPCs had committed. Those rows were
not deleted or rewritten because the financial evidence is intentionally
immutable. They remain development-only evidence, not partial rows from a
failed database operation. The post-functional-smoke reconciliation at that
gate reported
31 fake customers/accounts (the original baseline plus ten three-customer
attempts), 18 fuel sales, 13 repayments/allocations, 26 interest
accruals/components, 61 ledger transactions with 122 entries, 31 completed
idempotency records, 8 correction requests, 16 correction events,
4 reversals, and 104 audit events. Four Manager requests remain deliberately
pending. Six interrupted Owner smoke accounts retain 50 paise of synthetic
interest due; all ten smoke Owner accounts total 82,000 paise synthetic
principal.

Whole-project checks found zero unbalanced ledger transactions, zero
incomplete idempotency records, zero failed interest runs, zero isolation
tenant financial transactions, and zero unexpected Auth/customer/organization
markers. At that gate, the Auth population remained exactly seven fake
identities. The post-smoke hosted catalog verifier passed again; migration history remains
25/25, forced RLS remains 30/30, service-role table and public-RPC grants
remain zero, the authenticated definer allowlist remains exactly 11, default
ACL hardening remains intact, and the one cron registration is unchanged.
The live Data API remains `public` plus `graphql_public`, with `app_private`
unexposed and automatic new-table exposure off.

## Hosted concurrency smoke

The repository-controlled hosted harness is
`supabase/tests/remote/phase_2e_concurrency_smoke.py`. It uses two independent
TLS database sessions per race through the Mumbai Supavisor session-mode
endpoint on port 5432. It obtains an official short-lived CLI login role into
process memory, assumes the same `postgres` role used by the CLI for database
operations, and never prints or persists the credential or connection string.
It binds the exact project reference, project name, region, local link, and
25-version migration history before any write.

Successful run `E6C1546C6CCE` was low-volume deterministic smoke testing, not
load or stress testing:

- Fuel overspending: racer A committed 70,000 paise and racer B waited, then
  rolled back with `FCP_INSUFFICIENT_CREDIT`. The 100,000-paise limit ended at
  70,000 paise principal and 30,000 paise available credit, with one sale, one
  transaction, two balanced entries, one success audit, one completed
  idempotency record, and no loser partial state.
- Competing repayment: racer A committed a 70,000-paise principal repayment;
  racer B waited, then rolled back with `RPP_PRINCIPAL_EXCEEDS_DUE`. The
  100,000-paise starting principal ended at 30,000 paise with 170,000 paise
  available credit, one repayment/allocation, one balanced transaction with
  two entries, one success audit, and no loser partial state.
- Duplicate interest: the two sessions targeted 2026-08-13 on a dedicated
  36,501-paise principal fixture. Racer A created the logical accrual and racer
  B waited, then committed the idempotent replay. Exactly one accrual, one
  component, one 18-paise interest transaction, two balanced entries, and one
  audit exist. Raw interest was 18.000493150684931507 paise and the closing
  fractional carry is 0.000493150684931507 paise.
- Correction approval: a Manager-created `REVERSAL_ONLY` request started
  `PENDING_REVIEW` at version 1. Owner A executed it; Owner B waited and then
  committed the terminal idempotent replay. The final request is
  `APPROVED_AND_EXECUTED` at version 2 with exactly one approval event, one
  reversal, one balanced two-entry reversal transaction, no replacement, and
  an unchanged original-transaction fingerprint.

The seven run-scoped transactions contain 14 entries and reconcile to
476,519 paise of debits and 476,519 paise of credits. There were zero
unbalanced transactions, incomplete idempotency records, unfinished interest
runs, unknown commit states, deadlocks, lock timeouts, statement timeouts, or
infrastructure failures. Four delayed racers showed material waits and then
reached deterministic outcomes. Network retry count was zero, all successful
append-only records remain, and no cleanup `DELETE` was performed.

One natural zero-work wall-clock scheduler invocation completed successfully
at 18:07 UTC immediately before the run window. It was not manually invoked
and did not overlap the smoke run; the harness observed zero incidental cron
runs between its own before/after snapshots. The one registered job, schedule,
command, owner, and active state remained unchanged.

Post-run verification found 35 synthetic customers/accounts, 21 fuel sales,
14 repayments/allocations, 239 interest accruals/components, 280 ledger
transactions with 560 entries, 35 completed and zero incomplete idempotency
records, 9 correction requests, 19 correction events, 5 reversals, and 328
audit events. The larger interest/audit totals include normal historical
scheduled processing of synthetic fixtures. Whole-project checks still found
zero unbalanced transactions and zero unfinished interest runs.

The committed catalog/security verifier passed both before and after the
races: migration history is 25/25, forced RLS is 30/30, raw financial mutation
grants are zero, service-role application-table and RPC grants are zero, the
authenticated definer allowlist remains exactly 11, default ACL hardening is
unchanged, and the live Data API remains only `public` plus `graphql_public`.
`app_private` and `cron` remain unexposed, with no schema, function, grant, or
cron drift.

No network or unknown-commit retry occurred. During harness shakeout, early
attempts stopped before a race because of temporary-role/catalog result
handling, a planner-time reference to non-returned RPC columns, and an
authenticated call to a private verifier. Each attempt was reconciled before
continuing; the planner failures made no application mutation, and the one
transactional attempt rolled back completely. Immediately before the
successful run there were zero hosted-concurrency fixtures, incomplete
idempotency records, unfinished interest runs, or unbalanced transactions.

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
- Hosted functional harness syntax and wrong-target fail-closed check: PASS.
- Hosted concurrency harness: PASS against the exact development target; run
  `E6C1546C6CCE`, four bounded races, sanitized ignored evidence, and zero
  network retries or partial state.
- Repository hygiene: PASS across 179 tracked/untracked non-ignored files.
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
| Hosted functional harness | PASS; syntax, exact target binding, ordinary-JWT actor matrix, sanitized evidence |
| Hosted concurrency harness | PASS; run `E6C1546C6CCE`, four two-session races, exact reconciliation, sanitized ignored evidence |
| Repository hygiene | PASS, 179 files inspected |
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
controlled hosted scheduler/interest-cycle validation, load test,
completed software-composition vulnerability report, GitHub development
secrets/environment configuration, or independent professional
security/financial review is part of the completed work to date. No real
customer data exists in the development project; its application data is only
the approved synthetic bootstrap, isolation fixture, and functional-smoke
history. The excluded pre-existing Supabase project remains untouched.
