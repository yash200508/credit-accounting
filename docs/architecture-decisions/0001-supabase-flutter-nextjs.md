# ADR 0001: Supabase Backend with Flutter and Next.js Clients

- Status: Accepted
- Date: 2026-07-24

## Context

The repository currently contains a JavaFX desktop application backed by a local SQLite database. It has no shared identity, multi-tenant isolation, mobile client, web dashboard, or central transaction boundary. An earlier README proposed Spring Boot and Android, but no such implementation exists.

The target needs authenticated multi-organization access, database-enforced tenant isolation, future mobile station workflows, and a management dashboard without creating a bespoke authentication system.

## Decision

Use Supabase as the backend platform:

- PostgreSQL migrations and constraints for durable domain state;
- Supabase Auth UUIDs for identity;
- grants plus forced Row Level Security for tenant/role enforcement;
- carefully scoped database or server functions for atomic privileged operations;
- Flutter for future mobile/client workflows;
- Next.js for the future management dashboard.

The JavaFX/SQLite application remains unchanged during the foundation phase. Migration will be incremental and reconciled.

## Consequences

Positive:

- authorization can be tested at the data boundary;
- local Docker development and migrations are reproducible;
- Auth and PostgreSQL primitives reduce bespoke infrastructure;
- Flutter and Next.js can share backend contracts.

Costs and risks:

- RLS and privileged functions become security-critical code;
- offline behavior requires deliberate conflict/idempotency design;
- service-role credentials require strict server-only handling;
- SQLite/Java calculation parity must be proven;
- platform upgrades and generated local images require controlled versioning.

## Rejected alternatives

- Keep SQLite as the shared backend: it does not provide the required multi-user tenant/security boundary.
- Build custom passwords/authorization: unnecessary risk and maintenance.
- Adopt Spring Boot/Android immediately: it was only a proposal, expands Phase 1 substantially, and duplicates platform capabilities before core authorization and ledger invariants are proven.
