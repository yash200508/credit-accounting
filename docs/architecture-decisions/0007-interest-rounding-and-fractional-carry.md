# ADR 0007: Interest Rounding and Fractional Carry

- Status: Accepted
- Date: 2026-07-24

## Context

Rounding each small daily result independently can silently discard value or
overcharge. Binary floating point cannot be the financial authority.

## Decision

Calculate components with PostgreSQL `NUMERIC(38,18)` and persist exact raw
paise. Each account/day advances a cumulative exact target:

```text
cumulative exact = prior cumulative exact + raw total
cumulative target = round(cumulative exact)
posted = cumulative target - prior cumulative posted
closing carry = cumulative exact - cumulative target
```

Use PostgreSQL numeric round half away from zero. A zero whole-paise result
creates immutable calculation evidence but no ledger transaction or
financial-success audit event.

## Consequences

Tiny balances eventually post when accumulated raw interest reaches the
rounding boundary. Catch-up and uninterrupted processing produce identical
raw totals and whole paise. Closing carry can be negative at an exact
half-boundary after rounding upward, but posted interest is never negative.
The legacy Java `double`/segment rounding remains non-authoritative and may
differ intentionally.
