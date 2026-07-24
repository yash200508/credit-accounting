# ADR 0008: Station-Local Accrual Scheduling

- Status: Accepted
- Date: 2026-07-24

## Context

One UTC midnight cannot safely represent completed business days for stations
in different timezones. Missed executions must recover without duplicate
financial effects or secrets in an external trigger.

## Decision

Store a validated canonical IANA timezone on each station and capture every
principal-affecting transaction's immutable local business date. Register one
named hourly pg_cron job that calls a fixed private PostgreSQL function.

For each active station, accrue only through local date minus one. Process
missing account dates chronologically, lock each account using the same row
lock as fuel and repayment, and bound work to 31 days per account per hourly
cycle. Persist run status and remaining-work evidence. Use station advisory
locking and account/date/version uniqueness for duplicate invocation safety.

## Consequences

Stations cross local midnight independently and no partially completed current
day is charged. Missed hours recover through catch-up. The schedule contains no
HTTP endpoint or credential, and normal roles cannot invoke the global engine
or use the cron schema. Local validation checks registration and the underlying
cycle, not real elapsed-time firing. Hosted deployment, monitoring, and
operator runbooks require separate production work.
