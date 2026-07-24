# ADR 0004: Ledger and Idempotency Model

- Status: Accepted
- Date: 2026-07-24

## Context

Credit must be authoritative, auditable, replay-safe, and correct under
concurrency. A mutable balance or single signed transaction row would make
accounting shape and partial failure harder to verify.

## Decision

Use immutable posted transaction headers and positive-amount double-entry
details. A fuel-credit transaction debits customer accounts receivable and
credits fuel-sales revenue for the same integer paise amount. A deferred
constraint trigger verifies the complete posted shape at transaction end.
Hard triggers reject update/delete of transaction, entry, and sale rows.

Outstanding principal is posted AR debits minus posted AR credits. Available
credit is the configured limit minus that principal. No mutable balance cache
is introduced.

Idempotency uses an organization/operation/client-UUID unique key, a canonical
SHA-256 request fingerprint, state, and the completed safe receipt fields. The
claim participates in the posting transaction: failures leave no key, while a
committed same-payload replay returns the original result.

## Consequences

The model can accept future repayment credits and append-only reversals without
rewriting the balance formula. Phase 2A deliberately defines only fuel-credit
posting; repayment, interest, and reversal commands are not implied.

Row locking is required even with the ledger constraint: balance correctness is
an account-level concurrency invariant, while balanced entries are a
transaction-level accounting invariant. A separate-session harness validates
the former.
