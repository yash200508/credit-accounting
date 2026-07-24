# Interest Rules

## Authoritative backend rule

Phase 2C calculates daily simple interest in PostgreSQL:

```text
raw interest in paise =
closing eligible principal in paise × annual rate ÷ 365
```

The organization default is `0.18000000` (18%). A non-overlapping,
effective-dated customer policy overrides the organization default. Policy
rows also snapshot grace days, grace type, the enabled switch, and the fixed
`365` day-count basis. Effective-from is inclusive and effective-to is
exclusive.

Calculations use exact `NUMERIC(38,18)` paise. No authoritative binary
floating point is used. The denominator remains 365 on February 29.

## Principal basis and business date

Only posted `FUEL_CREDIT` principal lots are eligible. Existing interest,
interest-income entries, fees, total due, and earlier interest charges are
never principal inputs. Consequently interest does not compound.

Every principal-affecting ledger transaction stores an immutable
`business_date`, derived from `occurred_at` in the posting station's validated
IANA timezone. Daily interest uses closing principal after all events carrying
that stored date:

- same-day principal repayments reduce the day's basis;
- same-day fuel can accrue when its grace is zero;
- repayments reduce the oldest fuel lots first for interest aging;
- an interest-only repayment never changes a principal lot;
- a split repayment changes lots only by its principal component.

The FIFO lot view is derived from ledger entries. It is evidence for interest
eligibility and legacy reconciliation, not a second stored principal balance.

## Grace semantics

For source date `D` and `G` grace days, the threshold is `D + G`.

`AFTER_GRACE_ONLY` records zero through `D + G - 1`. Interest begins on the
threshold and never catches up the free days.

`RETROACTIVE_AFTER_GRACE` also records zero before the threshold. If principal
from the lot is still outstanding when the threshold is reached, that
threshold calculation catches up each still-outstanding closing balance from
`D` through `D + G - 1`, then includes the threshold day normally. Immutable
components identify every caught-up date, source lot, remaining principal, and
effective rate. A fully repaid lot before threshold has no catch-up.

The source-date policy snapshots the lot's grace rules. The policy effective
on each interest date supplies that date's rate and enabled state. Later policy
changes never rewrite posted evidence.

## Disabled and inactive states

An effective disabled policy records a zero-raw calculation for the date and
does not remove historical interest due. Inactive customers and accounts
cannot receive normal new fuel postings, but existing unpaid principal keeps
accruing when policy permits.

## Fractional paise and posting

Each account/date records raw interest, cumulative exact interest, and
opening/closing fractional carry:

```text
cumulative target = round(cumulative exact interest)
whole paise to post = cumulative target - cumulative paise already posted
closing carry = cumulative exact interest - cumulative target
```

PostgreSQL `round(NUMERIC)` is half away from zero. Interest is non-negative,
so this is ordinary half-up behavior. A zero-whole-paise day keeps evidence
and carry but creates no ledger transaction or financial-success audit event.

A positive amount posts:

```text
Debit  CUSTOMER_INTEREST_RECEIVABLE
Credit INTEREST_INCOME
```

The amount never touches principal receivable, so available credit remains
`credit limit - outstanding principal`.

## Scheduling, catch-up, and replay

The named pg_cron job invokes a fixed private function hourly. For each active
station the engine converts the trusted timestamp into the station timezone
and stops at local date minus one. Missing dates run chronologically with an
account-level catch-up bound. `COMPLETED_WITH_REMAINING` and
`IAC_CATCHUP_LIMIT` report unfinished work; the next cycle continues.

Account/date/calculation-version uniqueness plus the shared credit-account row
lock makes reruns safe. A processed date returns a successful no-op. Catch-up
and uninterrupted processing preserve the same exact raw total and posted
paise.

## Java compatibility

The legacy `InterestCalculator` remains non-authoritative. It uses `double`,
rounds each date segment independently, and has no persisted policy,
fractional-carry, scheduler, or audit model. Its event segmentation applies
transactions before the following interval, which is directionally consistent
with closing-principal daily treatment, but its rounding and policy semantics
are intentionally not copied. Migration reconciliation must use approved
PostgreSQL evidence and a governed golden corpus rather than silently treating
the Java result as authoritative.
