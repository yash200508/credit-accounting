# ADR 0011: Dependency-Aware Correction Blocking

- Status: Accepted
- Date: 2026-07-27

## Context

Reversing an earlier transaction can invalidate FIFO repayment attribution, credit-limit safety, or later interest evidence. Automatically cascading changes across many immutable rows would require a separate reviewed adjustment model.

## Decision

Execution recalculates impact while holding the credit-account lock. A fuel reversal is blocked after any principal from its lot was consumed or when an interest component references it. A repayment reversal is blocked if restored principal exceeds the credit limit or a later accrual used the reduced principal.

Interest-charge reversal is explicitly unsupported. The Phase 2C engine persists cumulative raw interest, posted paise, fractional carry, and account/date idempotency without an append-only correction accumulator. Partially compensating the ledger would make catch-up and uninterrupted schedules diverge.

The public preview is informative only. Approval repeats the original fingerprint, dependency, proposal, balance, and credit checks after locking.

## Consequences

- Unsafe cases fail with stable `COR_` errors and create no partial financial rows.
- Replacement failure rolls back the reversal in the same transaction.
- Correction-aware FIFO treats repayment reversals as negative repayments from their execution date and removes reversed fuel lots only from the reversal date forward.
- Automatic cascades and interest correction evidence are deferred.
