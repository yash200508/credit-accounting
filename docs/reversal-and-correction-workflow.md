# Reversal and Correction Workflow

## Purpose

Phase 2D corrects posted financial errors without editing or deleting history:

```text
posted original
  -> typed correction request with mandatory reason
  -> trusted impact preview
  -> independent owner approval
  -> exact current-date reversal
  -> optional typed replacement
  -> immutable links, events, and audit evidence
```

## State and authorization

Requests start at `PENDING_REVIEW` and end at exactly one of `APPROVED_AND_EXECUTED`, `REJECTED`, or `CANCELLED`. Terminal requests never reopen.

- An active owner may submit within the owned organization.
- An active assigned manager may submit only for the assigned station.
- Only an active owner may approve and execute.
- The requester cannot approve their own request.
- Attendants, customers, drivers, anonymous users, revoked actors, and unrelated tenants cannot submit or execute.

Reasons use one of `WRONG_AMOUNT`, `WRONG_FUEL_PRODUCT`, `WRONG_CUSTOMER_SELECTION`, `DUPLICATE_ENTRY`, `WRONG_REPAYMENT_ALLOCATION`, `WRONG_PAYER_ATTRIBUTION`, `OPERATIONAL_ERROR`, or `OTHER`. Explanations are trimmed, 20–500 characters, reject control characters, token-like strings, and email-like PII. `WRONG_CUSTOMER_SELECTION` is reversal-only.

## Exact reversal accounting

The client never supplies ledger entries. The approval function reads the original posted entries and inserts their exact inverse:

| Original | Reversal |
|---|---|
| Debit customer accounts receivable | Credit customer accounts receivable |
| Credit fuel sales revenue | Debit fuel sales revenue |
| Debit cash on hand | Credit cash on hand |
| Credit principal or interest receivable | Debit the same receivable |

Every amount stays positive. A deferred constraint compares both entry multisets with `EXCEPT ALL`, checks the header identity and amount, and requires immutable reversal evidence.

The original date remains unchanged. The reversal and optional replacement receive the station-local execution date.

## Fuel-sale rules

An eligible fuel sale may be reversed or reversed and replaced. Full reversal is blocked when FIFO shows any principal from that lot was consumed (`COR_PRINCIPAL_ALREADY_REPAID`) or an interest component references the source (`COR_DEPENDENT_INTEREST_EXISTS`).

A fuel replacement is typed by product, amount, and safe reference. Organization, station, customer, and credit account are copied from the request. Approval rechecks active product, currency, available credit, and normal Phase 2A validation. Replacement failure rolls back the reversal.

## Repayment rules

Repayment reversal restores the original principal and interest allocations. It is blocked when principal restoration would exceed the account credit limit (`COR_REVERSAL_EXCEEDS_CREDIT_LIMIT`) or a later interest accrual used the reduced principal (`COR_DEPENDENT_INTEREST_EXISTS`).

A typed replacement supplies amount, allocation mode, principal amount, interest amount, optional valid payer driver, payment method, and safe reference. The existing Phase 2B function enforces allocation sums, due limits, driver attribution, balanced entries, idempotency, and audit.

FIFO interest inputs recognize a repayment reversal as a negative principal repayment on the current correction date. Earlier as-of dates retain the original historical result.

## Interest-charge limitation

Interest correction requests may be reviewed and previewed, but execution returns `COR_INTEREST_REVERSAL_UNSUPPORTED`. Paid interest and later accrual dependencies are also reported. No manual replacement interest charge is exposed.

The blocker remains until a reviewed append-only adjustment model can preserve cumulative exact interest, cumulative posted paise, fractional carry, scheduler idempotency, and catch-up equivalence.

## Atomic execution and concurrency

Execution locks in this order:

1. Correction request.
2. Original transaction.
3. Credit account.

It rechecks expected version, owner scope, independent approval, original fingerprint, current dependencies, balances, credit, product or allocation validity, and driver status. It then inserts the reversal, invokes the normal typed replacement workflow when requested, links immutable evidence, transitions the request, and appends events and audit rows in one database transaction.

Fuel posting, repayment posting, interest accrual, and corrections all serialize through the credit-account row lock. Unique original/request links prevent duplicates. A repeated successful approval returns the existing terminal result; lock/deadlock retry conditions use `COR_LOCK_RETRY`.

## Trusted RPCs

- `submit_financial_correction_request(...)`
- `get_financial_correction_impact(uuid)`
- `approve_and_execute_financial_correction(uuid, integer)`
- `reject_financial_correction_request(uuid, integer, text)`
- `cancel_financial_correction_request(uuid, integer, text)`

All use fixed empty `search_path`, fully qualified objects, server-derived actors, and revoked default execution. Authenticated callers receive only explicit execute grants. New tables use forced RLS and have no client mutation policies.

## Stable errors

The workflow returns safe `COR_` messages, including authorization, invalid request or reason, idempotency conflict, self approval, version conflict, terminal state, original change, already reversed, dependency, credit-limit, replacement, driver, overflow, retry, and unsupported-interest failures. Internal SQL, stack traces, tokens, and customer PII are not returned.

## Deferred behavior

This phase does not implement historical restatement, automatic correction cascades, refund disbursement, unallocated credit, overpayments, chargebacks, write-offs, credit overrides, or manual interest creation.
