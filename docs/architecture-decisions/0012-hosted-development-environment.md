# ADR 0012: One isolated hosted development environment

## Status

Accepted for Phase 2E implementation; hosted creation remains subject to the
explicit approval gate.

## Context

The accounting backend has been proven only in local Supabase. Client work
must not begin until the same immutable migrations, RLS, grants, functions,
locks, and scheduler registration are reproduced on hosted PostgreSQL. A
shared, production, or real-data project would make that proof unsafe.

## Decision

Use exactly one hosted project named `credit-accounting-development`, referred
to in logs and documentation by the safe alias of the same name. Label all
fixtures `DEVELOPMENT - FAKE DATA ONLY`. Use a Free-plan Nano project when the
user's organization can create it with no charge. Select `ap-south-1` only
after approval: Mumbai is the closest supported region to the application's
users and gas-station operations in India and minimizes development
round-trip time.

Do not enable PITR, paid compute, high availability, read replicas, custom
domains, network add-ons, paid logs, or any other paid feature. Free projects
can pause after inactivity and do not include managed backups; Phase 2E uses a
development-only logical dump and local restore rehearsal instead.

The Data API exposes `public` and `graphql_public` only. `app_private` remains
unexposed. Auth rejects anonymous sign-in and public signup. No social
provider, production redirect, production SMTP, client, real identity, or real
business record is configured.

## Consequences

- The environment is disposable development infrastructure, not a recovery or
  availability guarantee.
- Free-plan pausing may delay manual validation.
- The project may not be created if the organization has no no-cost project
  slot; no charge may be accepted automatically.
- Production architecture, billing, backups, domains, Auth, monitoring, and
  capacity remain undecided.

## Rejected alternatives

- Reusing any existing application or production project.
- Loading the JavaFX SQLite records or applying `supabase/seed.sql` remotely.
- Using hosted branching, PITR, or paid compute for this phase.
- Treating a hosted project as production-ready because migrations apply.
