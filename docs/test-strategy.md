# Test Strategy

## Test layers

1. **Migration/reset:** `supabase db reset --local` proves a clean database can be recreated from committed migrations and fake seed data.
2. **Structure:** pgTAP verifies required tables, RLS enabled/forced flags, constraints, and policy shape.
3. **Authorization:** tests impersonate deterministic Auth users by setting the request JWT subject and database role to `authenticated`; anonymous tests use `anon`.
4. **Business invariants:** pgTAP verifies exact driver ownership, tenant/station consistency, non-negative limits, QR ownership/hash rules, and audit immutability.
5. **Static database lint:** `supabase db lint --local` identifies function, schema, and policy issues.
6. **Legacy regression:** Maven `clean verify` must continue to pass all 37 Java tests.
7. **Concurrency:** a separate-session Python harness forces two ₹700 postings
   to race against a fresh ₹1,000 account and proves exactly one commits.

## Deterministic contexts

Fixtures contain two organizations, multiple stations, Owner A and Owner B, one manager, one attendant, one customer, one active driver, one revoked driver, and one unrelated user. UUIDs and fake contact values are fixed. Tests run in transactions and do not depend on clock-sensitive access except where explicit fixed dates are used.

Phase 2A adds organization- and station-scoped Petrol/Diesel products plus
inactive, low-limit, and cross-tenant fixtures. All names, phone numbers, UUIDs,
and references remain deterministic and fictional.

## Phase 2A posting coverage

pgTAP covers authorized owner/manager/attendant posting; every denied role and
scope; inactive customer/account/product; checked amount boundaries; exact and
insufficient credit; atomic rollback; double-entry shape and balance; hard
immutability; client raw-write denial; balance derivation and isolation; and
same/different-payload idempotency behavior. The original 64 Phase 1 tests
remain unchanged and must continue to pass.

The concurrency harness uses two independent `psql` processes. One session
holds the account row lock while the other starts a competing post, then both
are released. It asserts one success, one stable insufficient-credit failure,
principal at or below the limit, and no partial losing rows.

## Minimum RLS cases

- Every protected table has RLS enabled and forced.
- Anonymous access returns no business rows.
- Owner A cannot see Organization B.
- A manager sees only an assigned station.
- An attendant cannot browse customers or change credit limits.
- A customer sees only their own customer/account/settings.
- A driver reads only their own driver/permissions and the minimal parent-account RPC.
- An authenticated user cannot change their role.
- A client cannot spoof organization/station ownership.
- Normal clients cannot update/delete audit events.
- Revoked memberships lose access.
- A revoked driver loses driver access.
- No protected-table policy has an unconditional true expression.

## Test integrity

Tests must fail closed. Schema, fixtures, helpers, or policies are fixed when a test exposes a defect; a policy is never broadened merely to satisfy a test. Security tests assert both allowed and denied behavior so an accidental deny-all configuration is also visible.

## CI

Maven and Supabase validations run as separate workflows. Supabase CI pins CLI
2.109.1, starts the local stack, performs a clean reset, runs pgTAP, the
concurrency harness, lint, and a repository-hygiene check, captures local
service logs after failure, and always stops containers. It uses no remote
Supabase token or project reference.
