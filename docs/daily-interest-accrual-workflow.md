# Daily Interest Accrual Workflow

## Purpose

Phase 2C turns posted fuel principal into exact, auditable daily simple
interest without exposing a client-facing interest-charge capability.

```text
hourly pg_cron entry
→ active stations
→ station-local last completed day
→ missing account dates in chronological order
→ account row lock
→ effective policy + FIFO fuel lots
→ exact components + fractional carry
→ optional balanced interest ledger charge
→ immutable calculation and audit evidence
```

## Policy resolution

`app_private.resolve_effective_interest_policy` selects a non-overlapping
customer override first and otherwise the organization default. Policy dates
use `[effective_from, effective_to)`. The default seed is 18%, enabled,
`AFTER_GRACE_ONLY`, and day-count 365.

The source-date policy snapshots a fuel lot's grace days and grace kind. Each
interest component resolves the rate and enabled switch effective on the date
being priced. This keeps later changes forward-only while allowing a
retroactive-threshold component to use the historically correct daily rate.

## Closing principal and FIFO

`ledger_transactions.business_date` is derived at posting from trusted
`occurred_at` and the station's validated IANA timezone. Interest never
recomputes a historical date from the server timezone.

`app_private.principal_lots_as_of` orders `FUEL_CREDIT` rows by business date,
timestamp, and UUID. Posted credits to
`CUSTOMER_ACCOUNTS_RECEIVABLE` consume the oldest amount first. The result is a
derived view of ledger truth:

- principal-only repayment reduces lots;
- split repayment reduces them by its principal credit only;
- interest-only repayment has no effect;
- same-day principal events are all included in closing principal;
- interest-receivable entries never become lots.

## Grace calculation

For source date `D`, threshold is `D + grace_days`.

With `AFTER_GRACE_ONLY`, dates before threshold have zero components. Threshold
and later dates get normal daily components.

With `RETROACTIVE_AFTER_GRACE`, dates before threshold initially have zero.
If the lot remains open at threshold, that date receives:

- one `RETROACTIVE_CATCH_UP` component per source date from `D` through
  threshold minus one, using that historical day's closing lot balance; and
- one `DAILY` component for the threshold's closing balance.

A rerun finds the existing account/date/version and returns `was_created =
false`, so catch-up cannot repeat.

## Exact calculation and posting

Raw component interest is:

```text
remaining principal paise × annual decimal rate ÷ 365
```

All operands are cast to exact `NUMERIC(38,18)` before division. The account
day sums components and derives a monotonic cumulative target:

```text
cumulative exact = prior cumulative exact + raw day total
cumulative target = round(cumulative exact)
posted paise = cumulative target - prior cumulative paise posted
closing carry = cumulative exact - cumulative target
```

PostgreSQL numeric rounding is half away from zero. A zero posted result still
creates `interest_accruals` and component evidence, but no ledger or success
audit.

A positive result atomically creates `INTEREST_CHARGE`:

```text
Dr CUSTOMER_INTEREST_RECEIVABLE
Cr INTEREST_INCOME
```

The existing deferred ledger trigger verifies two equal entries. The audit
records safe identifiers, business date, policy snapshot, exact raw text,
posted amount, run, trigger source, correlation request, and version. It
contains no customer PII or secret.

## Locking and idempotency

The posting function validates run, tenant, station, account, date, and
sequence, then locks the credit-account row `FOR UPDATE`. Fuel and repayment
posting use the same lock. A worker therefore calculates from one complete
serialization rather than a torn ledger state.

Uniqueness on `(credit_account_id, business_date, calculation_version)`
provides the durable replay boundary. Run request IDs are also unique within a
station and organization.

## Scheduling and catch-up

Migration registration creates one named pg_cron job:

```text
credit-accounting-hourly-interest-accrual
7 * * * *
select app_private.run_hourly_interest_accrual();
```

The SQL contains no URL, key, or secret. The entry point, cycle, station
runner, calculator, and posting functions are revoked from `PUBLIC`, `anon`,
`authenticated`, and `service_role`. Those roles also lack `cron` schema use.

Each station computes:

```text
station local date = requested_at AT TIME ZONE station.time_zone_name
latest completed date = station local date - 1
```

The runner holds a transaction advisory lock per station, then processes
accounts in UUID order and dates chronologically. The default hourly limit is
31 missing days per account. Reaching it records
`COMPLETED_WITH_REMAINING`, `IAC_CATCHUP_LIMIT`, and
`more_dates_pending=true`; the next run resumes at the next date.

An exception rolls back all account/day effects from that station invocation
and finalizes its run as `FAILED` with a stable code and generic message. SQL,
PII, and secrets are not copied into run evidence.

## Read boundary

Owners can read runs, accruals, and components in owned organizations.
Managers can read only assigned stations. Attendants continue using the
existing exact-obligation interface but cannot browse raw runs or components.
Customers, drivers, anonymous users, and `service_role` have no raw access.

## Operational checks

Local validation:

```powershell
npx --yes supabase@2.109.1 db reset --local
npx --yes supabase@2.109.1 test db
python supabase/tests/concurrency/phase_2c_interest_accrual_concurrency.py
python supabase/tests/scheduler/phase_2c_scheduler_registration.py
```

The scheduler script validates registration and privilege shape only. Local CI
does not wait for or claim a real wall-clock cron execution. Production
deployment, monitoring, and operator catch-up tooling remain outside Phase 2C.
