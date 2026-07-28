# Development Roadmap

## Phase 0 — complete

Stabilize the Java 17 build and encoding, preserve JavaFX/SQLite behavior, and
establish 37 passing Maven tests and Maven CI.

## Phase 1 — complete

Create the local Supabase foundation: architecture/security documentation,
multi-tenant schema, constrained authorization helpers, forced RLS, fake seed
data, pgTAP coverage, local reset/lint validation, and separate CI. Do not
connect clients or remote projects.

## Phase 2A — complete: secure credit-posting core

```text
Create customer
→ create credit account
→ post one fuel-credit transaction atomically
→ enforce available credit
→ create append-only ledger entries
→ create immutable audit event
→ reject duplicate idempotency keys
```

This slice implements balanced append-only ledger semantics, checked integer
arithmetic, strict actor/station/account authorization, idempotency, and
separate-session concurrency validation.

## Phase 2B — complete: repayment and explicit allocation

```text
Receive cash from customer or active linked driver
→ explicitly allocate principal, interest, or both
→ reject any overpayment
→ post balanced append-only repayment entries
→ derive updated obligations
→ audit and make retries idempotent
```

This slice adds immutable repayment/allocation details, separate posted
interest receivable, an additive obligations interface, and a trusted repayment
function for owners, assigned managers, and assigned attendants. Repayment and
fuel posting serialize on the same credit-account row. Interest remains outside
the credit-limit calculation.

Cash is the only accepted method. Automated interest calculation/accrual,
unallocated customer credit, overpayment balances, refunds, reversals, client
applications, and remote deployment remain deferred.

## Phase 2C — complete: automated daily simple interest

```text
Resolve effective policy
→ derive FIFO closing principal lots
→ apply grace semantics
→ preserve exact fractional-paise carry
→ post balanced interest when at least one paise is payable
→ record immutable evidence
→ catch up station-local missed dates safely
```

This slice implements 18% default and customer overrides, fixed Actual/365
simple interest, no compounding, both approved grace variants, immutable
business dates and evidence, account-locked idempotency, and a committed
hourly pg_cron registration. It remains local-only; production scheduling is
not deployed or claimed.

## Phase 2D — complete: governed reversals and corrections

```text
Submit typed correction with mandatory reason
→ preview dependencies and balance impact
→ require a different active owner
→ append an exact current-date compensating transaction
→ optionally post a typed corrected replacement atomically
→ preserve immutable links, events, and audit evidence
```

Fuel sales and repayments can be reversed when their later dependencies remain
unambiguous. Replacement posting reuses the trusted Phase 2A and 2B functions.
Interest-charge reversal is deliberately blocked because Phase 2C has no
append-only adjustment accumulator for cumulative posted interest and
fractional carry. The slice remains local-only.

## Phase 2E — in progress: hosted development and operations

```text
Verify local baseline
→ reproduce immutable migrations in one fake-data hosted development project
→ verify RLS, grants, Auth, API exposure, cron, and advisors
→ run functional and concurrency smoke
→ create logical backup and disposable local restore evidence
```

Project creation, region selection, linking, remote migration, fake Auth users,
controlled interest execution, and GitHub secrets retain explicit approval
gates. Production and real data remain out of scope.

## Later slices

1. **Next recommended slice after Phase 2E:** customer and driver QR
   credential issuance, rotation, revocation, and minimum account lookup.
2. Refund and reconciliation workflows built on governed corrections.
3. Audited owner workflows for memberships, roles, stations, customers,
   drivers, limits, products, and QR rotation.
4. Thin Flutter attendant/customer workflows built only on secure RPC/API
   boundaries.
5. Next.js owner/manager dashboard with server-only privileged operations.
6. Governed SQLite export, validation, dry-run import, reconciliation, and
   rollback.
7. Offline queue only after conflict, idempotency, clock, and reconciliation
   rules are complete.
8. Inventory and attendance as separate bounded domains.
9. Staging hardening, observability, backups, performance tests, professional
    financial/security review, and production readiness.

## Cross-cutting gates

Every slice must preserve tenant isolation, use integer paise, avoid raw
secrets, add RLS and negative tests, produce immutable audit evidence, remain
reproducible from migrations, and keep legacy regression green until the
desktop migration is explicitly approved.
