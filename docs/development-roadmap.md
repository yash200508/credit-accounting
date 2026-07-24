# Development Roadmap

## Phase 0 — complete

Stabilize Java 17 build and encoding, preserve JavaFX/SQLite behavior, and establish 37 passing Maven tests and Maven CI.

## Phase 1 — this change

Create the local Supabase foundation: architecture/security documentation, multi-tenant schema, constrained authorization helpers, forced RLS, fake seed data, pgTAP coverage, local reset/lint validation, and separate CI. Do not connect clients or remote projects.

## Phase 2A — secure credit-posting core

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
separate-session concurrency validation. Client applications and the remaining
financial workflows stay deferred.

## Later slices

1. **Next recommended slice:** repayment posting with principal/interest
   allocation, receipts, append-only reversal semantics, and reconciliation.
2. Audited owner workflows for memberships, roles, stations, customers, drivers, limits, and QR rotation.
3. Interest calculation/posting with golden parity tests and idempotent scheduling.
4. Thin Flutter attendant/customer workflows built only on secure RPC/API boundaries.
5. Next.js owner/manager dashboard with server-only privileged operations.
6. Governed SQLite export, validation, dry-run import, reconciliation, and rollback.
7. Offline queue only after conflict, idempotency, clock, and reconciliation rules are complete.
8. Inventory and attendance as separate bounded domains.
9. Staging hardening, observability, backups, performance tests, professional security review, and production readiness.

## Cross-cutting gates

Every slice must preserve tenant isolation, use integer paise, avoid raw secrets, add RLS and negative tests, produce immutable audit evidence, remain reproducible from migrations, and keep legacy regression green until the desktop migration is explicitly approved.
