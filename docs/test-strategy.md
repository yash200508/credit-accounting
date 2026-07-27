# Test Strategy

## Test layers

1. **Migration/reset:** `supabase db reset --local` proves a clean database can
   be recreated from committed migrations and fake seed data.
2. **Structure:** pgTAP verifies required tables, RLS enabled/forced flags,
   constraints, and policy shape.
3. **Authorization:** tests impersonate deterministic Auth users by setting the
   request JWT subject and database role to `authenticated`; anonymous tests use
   `anon`.
4. **Business invariants:** pgTAP verifies tenant/station/driver ownership,
   amount and allocation rules, exact accounting shapes, idempotency, and hard
   immutability.
5. **Static database lint:** `supabase db lint --local` identifies function,
   schema, and policy issues.
6. **Legacy regression:** Maven `clean verify` must continue to pass all 37 Java
   tests.
7. **Concurrency:** separate-session Python harnesses race credit posting,
   repayment, and interest calls against the same locked account rows and
   verify final balances and absence of losing partial effects.
8. **Scheduler registration:** a dedicated local check verifies the extension,
   single named job, hourly expression, fixed command, lack of secrets, and
   privilege revocations. It does not claim wall-clock cron execution.
9. **Hosted development:** after approvals, a target verifier checks exact
   project identity, Auth, and Data API schemas; catalog SQL checks all expected
   tables, forced RLS, grants, search paths, and cron; normal Auth/PostgREST
   smoke covers 23 business/denial cases; the four existing race harnesses run
   through TLS PostgreSQL environment variables.
10. **Logical recovery:** schema/fake-data dumps are scanned and restored into
    a disposable local stack, then ledger, interest, correction, RLS, function,
    migration, and cron evidence is reconciled.

## Deterministic contexts

The shared fake seed contains two organizations, multiple stations, Owner A and
Owner B, one manager, one attendant, one customer, an active driver, a revoked
driver, a cross-tenant driver, and an unrelated user. Phase 2A adds
organization- and station-scoped Petrol/Diesel products plus inactive,
low-limit, and cross-tenant fixtures. UUIDs, names, phone numbers, emails, and
references are deterministic and fictional.

The Phase 2B pgTAP transaction creates isolated customers/accounts for
principal-only, interest-only, split, nothing-due, low-balance, inactive-entity,
driver, manager, and attendant scenarios. Historical interest is inserted only
by privileged test setup as a balanced receivable/income charge; no client
interest-charge RPC exists. An expired linked driver is created inside the test
transaction so the original Phase 1 seed cardinality remains stable.

Phase 2C extends the seed with canonical station timezones and effective policy
examples. `004_daily_interest_accrual_test.sql` creates its financial fixtures
inside a rolled-back transaction to preserve the pre-existing empty-ledger
baseline.

## Phase 2A posting coverage

pgTAP covers authorized owner/manager/attendant posting; every denied role and
scope; inactive customer/account/product; checked amount boundaries; exact and
insufficient credit; atomic rollback; double-entry shape and balance; hard
immutability; client raw-write denial; balance derivation and isolation; and
same/different-payload idempotency behavior. The original 64 Phase 1 tests
remain unchanged and must continue to pass.

The Phase 2A concurrency harness uses two independent `psql` processes. One
session holds the account row lock while the other starts a competing post. It
asserts one success, one stable insufficient-credit failure, principal at or
below the limit, and no partial losing rows.

## Phase 2B repayment coverage

`003_repayment_allocation_test.sql` adds 103 assertions, bringing the suite to
288. It covers schema and grants, forced RLS, every station-side and denied
role/scope, principal-only/interest-only/split accounting, derived obligations,
overpayment and input rejection, optional driver attribution, replay and
changed-payload idempotency, atomic rollback, hard immutability, exact deferred
allocation/ledger shapes, audit minimization, and tenant isolation. The
existing 185 assertions remain passing.

`phase_2b_repayment_concurrency.py` uses independent `psql` processes. Its
required race starts with INR 1,000 principal and concurrently submits two
INR 700 principal-only repayments. The account-row lock yields exactly one
success, one `RPP_PRINCIPAL_EXCEEDS_DUE`, INR 300 principal, INR 1,700
available against the INR 2,000 limit, and no losing repayment, allocation,
ledger, audit, or completed-idempotency rows.

A second scenario holds the same account lock for an INR 400 repayment while
an INR 500 fuel-credit post waits. Starting from INR 800 principal against an
INR 1,000 limit, both commit in serial order and finish at INR 900 principal
and INR 100 available.

A third scenario posts with an active linked driver, holds the posting
transaction open, and concurrently revokes the driver. The repayment's
post-lock `FOR SHARE` locks make the revocation wait; the posting transaction
still observes `ACTIVE` through commit, after which revocation succeeds.

## Phase 2C interest coverage

`004_daily_interest_accrual_test.sql` adds 159 assertions, bringing the suite
to 447. It covers schema and forced RLS, client denial, cron registration,
default/override/effective policy resolution, both grace variants, FIFO
partial and multi-lot repayments, same-day closing principal, exact `NUMERIC`
arithmetic, fractional carry, half-away rounding, zero-post evidence,
overflow, rate changes, disabled periods, inactive debt, leap day, balanced
interest accounting, derived balances, replay, immutable evidence,
station-local boundaries, bounded catch-up, catch-up equivalence, safe failed
runs, role-scoped reads, and regression interfaces.

`phase_2c_interest_accrual_concurrency.py` uses independent PostgreSQL
sessions. It proves one of two same-account/date workers creates the
calculation while the other returns a no-op; accrual waiting behind a same-day
INR 700 principal repayment uses the INR 300 closing balance; and accrual
waiting behind a fuel purchase sees the complete ledger state while respecting
the new lot's independent grace threshold.

## Minimum RLS cases

- Every protected table has RLS enabled and forced.
- Anonymous access returns no business rows.
- Owner A cannot see or post in Organization B.
- A manager sees and posts only in an assigned station.
- An attendant can use posting capabilities but cannot browse financial rows.
- A customer sees only their own foundation records and cannot post.
- A driver reads only their own driver/permissions and cannot post.
- A client cannot spoof actor, customer, organization, station, or driver scope.
- Direct financial writes and audit mutation are denied.
- Revoked memberships and revoked/expired drivers fail closed.
- No protected-table policy has an unconditional true expression.

## Test integrity

Tests fail closed. Schema, fixtures, helpers, or policies are fixed when a test
exposes a defect; a policy is never broadened merely to satisfy a test.
Security tests assert both allowed and denied behavior so an accidental
deny-all configuration is also visible.

## CI

Maven and Supabase validations run as separate workflows. Supabase CI pins CLI
2.109.1, starts the local stack, performs a clean reset, runs all 567 pgTAP
assertions, all four concurrency harnesses, the scheduler registration check,
lint, and repository hygiene, captures local service logs after failure, and
always stops containers. It uses no remote Supabase token or project reference.

## Phase 2D correction coverage

The 120 Phase 2D assertions cover schema, forced RLS, grants, requester and
approver authorization, reason safety, submission replay/conflict, expected
versions, exact reversal entries, current dates, fuel and repayment dependency
blocks, principal/interest/split replacements, rollback, terminal transitions,
hard immutability, audit privacy, correction-aware FIFO, and explicit interest
reversal blocking.

The Phase 2D independent-session harness races two approvals, repayment
reversal against fuel posting, fuel reversal against interest accrual, and
approval against cancellation. It validates final ledger, obligation, event,
replacement, idempotency, and partial-row counts.

## Phase 2E hosted coverage

The hosted functional harness signs in only generated `.example.test`
identities and calls normal public RPCs wherever possible. It verifies
owner/manager creation, attendant denial and posting, balance movement,
same/changed-payload idempotency, principal and interest repayment, private
interest denial, separately approved internal cycle behavior, maker-checker
correction, self-approval denial, exact reversal, immutable original,
cross-tenant/anonymous denial, and direct mutation denial.

Remote mode preserves each existing independent `psql` process and expected
domain errors while replacing the local Docker target with TLS `PG*`
environment values. It is a four-scenario smoke, not a load test. Successful
append-only records remain labeled development. Wall-clock scheduler execution
is reported only if a real hosted cron run is observed.
