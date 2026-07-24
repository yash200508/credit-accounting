# Current-State Audit

Audit date: 2026-07-24

## Verified repository state

The repository is a Java 17/JavaFX desktop application. Maven builds a desktop JAR and the verified baseline is 37 passing tests under `mvn --batch-mode --no-transfer-progress clean verify`. The application entry point is `com.gasstation.app.App`.

The current production-shaped data path is local SQLite, created by `com.gasstation.app.db.Db` at `${user.home}/.credit-accounting/credit.db`. There is no implemented backend server, Supabase integration, Flutter client, Next.js dashboard, remote authentication, or production deployment in the repository at the start of Phase 1.

## Existing persistence boundary

`Db` owns connection creation and in-place SQLite schema upgrades. The persistence boundary consists of:

- `CustomerDao`: customer CRUD, normalized phone uniqueness, and phone history.
- `TransactionDao`: DEBIT/CREDIT posting, POSTED/VOID status handling, customer history, and sums.
- `SettingsDao`: untyped key/value application settings.
- `ReminderDao`: reminder records.
- `AuditDao`: best-effort audit inserts.

Existing SQLite tables include customers, customer phone history, transactions, settings, reminders, audit log, and backups. Existing transaction rows are not deleted during ordinary use; voiding changes their status and downstream queries exclude voided rows.

## Reusable business logic

The following logic can inform later server-side implementation, but must be ported and independently tested rather than copied blindly:

- Money parsing and formatting uses integer paise and `BigDecimal` for decimal input conversion.
- Customer and transaction imports normalize phone numbers and reject malformed amounts.
- Payments are allocated FIFO to the oldest debit buckets.
- Statement interest is simple annual interest over date segments.
- Customer KPI logic calculates principal, overdue amounts, payment recency, and an explainable risk tag.
- Per-customer due days and grace days affect overdue classification.
- Reminder rendering and report aggregation are isolated from JavaFX screens.

## Gaps and migration risks

- SQLite is single-device and has no tenant or station isolation.
- The desktop application has no authenticated identity, authorization, or RLS boundary.
- The Java interest calculator accepts a `double` rate and rounds each time segment. The target database uses exact `NUMERIC` rates; parity and rounding rules need golden tests before financial posting moves server-side.
- The SQLite `app_settings` table is untyped and globally scoped.
- Audit inserts currently ignore SQL failures. The target system requires durable, immutable audit records for security- and accounting-sensitive actions.
- SQLite schema changes happen procedurally inside application startup rather than through an ordered migration history.
- Existing customer phone and address data is sensitive. No existing records are copied into Phase 1 seed data or migrations.
- Existing balance reports derive from mutable transaction rows and status filters. The future authoritative financial model must use an append-only ledger and atomic posting functions.
- The repository's earlier README described Spring Boot and Android as the target. Architecture Decision Record 0001 supersedes that proposal with Supabase, Flutter, and Next.js.

## Phase 1 boundary

Phase 1 adds only a local, reproducible Supabase foundation: tenant/station identity, role assignments, customer/account/driver/QR/interest/audit/settings foundations, restrictive RLS, fake seed data, database tests, and local CI.

It deliberately excludes client applications, remote project linking, production credentials, real-data migration, fuel or repayment posting, the final ledger, interest jobs, inventory, and attendance.
