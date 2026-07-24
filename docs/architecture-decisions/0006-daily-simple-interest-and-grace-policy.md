# ADR 0006: Daily Simple Interest and Grace Policy

- Status: Accepted
- Date: 2026-07-24

## Context

The backend needs configurable interest without compounding, mutable balances,
or ambiguous grace dates. Repayments are not linked to fuel purchases, yet
grace eligibility depends on principal age.

## Decision

Use exact daily simple interest on remaining posted fuel principal:

```text
principal paise × annual decimal rate ÷ 365
```

The denominator is always 365, including leap years. An organization default
(18% in the seed) can be overridden by non-overlapping effective-dated
customer policy history.

Every fuel debit is a derived principal lot. Principal repayments consume the
oldest lots first; source transactions remain immutable and the ledger remains
the only authoritative balance.

For source date `D` and grace `G`, threshold is `D + G`.
`AFTER_GRACE_ONLY` begins only on threshold.
`RETROACTIVE_AFTER_GRACE` catches up `D` through threshold minus one when an
open lot reaches threshold, then accrues normally.

## Consequences

Policy changes are forward-only and evidence retains source and rate-policy
snapshots. Interest receivable is never a principal lot, so compounding is
structurally prohibited. FIFO is an interest-aging and migration-reconciliation
rule, not a new stored balance. Alternative day-count bases, penalties, and
fees require a future ADR.
