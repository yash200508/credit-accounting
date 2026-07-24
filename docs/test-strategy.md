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
7. **Concurrency:** separate-session Python harnesses race credit posting and
   repayment calls against the same locked account rows and verify both final
   balances and absence of losing partial effects.

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
2.109.1, starts the local stack, performs a clean reset, runs all pgTAP tests,
both concurrency harnesses, lint, and repository hygiene, captures local
service logs after failure, and always stops containers. It uses no remote
Supabase token or project reference.
