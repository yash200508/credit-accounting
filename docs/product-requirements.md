# Product Requirements

## Product intent

Provide a secure multi-organization, multi-station foundation for gas-station customer credit accounting while the existing JavaFX/SQLite application remains operational and unchanged.

## Actors

- **Owner:** administers only owned organizations and their stations.
- **Manager:** operates only assigned stations and cannot grant roles or change ownership.
- **Attendant:** will perform narrowly authorized station operations through dedicated server-side functions; Phase 1 denies broad customer browsing and all financial writes.
- **Customer:** reads only their own customer profile, account settings, and credit account.
- **Driver:** belongs to exactly one customer, has no independent credit account, reads their own driver/permission records, and obtains only a minimal projection of the parent account.
- **Anonymous:** has no protected business-data access.

## Phase 1 functional requirements

- Represent multiple organizations and stations with explicit tenant relationships.
- Link Supabase Auth users to profiles, memberships, and scoped role assignments without custom password storage.
- Represent customer identity, credit configuration, and a credit-account identity without treating a mutable balance column as authoritative.
- Represent a driver attached to exactly one customer, optional transaction/daily limits, and expiration.
- Store only a hash of a high-entropy QR token and lifecycle metadata.
- Store default and customer-specific simple-interest policies using exact numeric rates.
- Store immutable audit events with safe metadata and no secrets.
- Store typed JSON settings at organization or station scope without cross-tenant access.
- Enforce least privilege with RLS and privileged helpers that always derive the actor from `auth.uid()`.
- Rebuild and test the local database deterministically from committed migrations and fake seeds.

## Financial invariants

- INR amounts use `BIGINT` integer paise.
- Rates use exact PostgreSQL `NUMERIC`.
- Credit limits and optional driver limits cannot be negative.
- A driver never owns a credit account.
- No client-calculated balance is authoritative.
- The future ledger will be append-only; ordinary correction uses compensating entries.
- Financial posting, balance enforcement, and idempotency are deferred to the next vertical slice.

## Non-functional requirements

- Local-only development in Phase 1; no `login`, `link`, `db push`, `db pull`, or remote credentials.
- Every protected business table has enabled RLS and an explicit access design.
- Normal client roles cannot write role assignments or update/delete audit events.
- Migration, seed, RLS, and pgTAP tests are reproducible on the pinned Supabase CLI.
- Existing Maven CI and all 37 Java tests continue to pass.
- No real customer data, raw QR secret, JWT, password, or service-role key is committed or logged.

## Out of scope

Flutter, Next.js screens, remote deployment, production linking, real-data migration, final ledger entries, fuel-credit posting, repayments, receipts, recurring interest posting, offline sync, inventory, and attendance are not Phase 1 deliverables.

## Acceptance criteria

Phase 1 is accepted when the local stack starts, a clean reset applies every migration and fake seed, pgTAP proves tenant/role isolation, lint has no unresolved failure, Java regression remains green, separate CI workflows exist, the branch is pushed, and a draft pull request is open.
