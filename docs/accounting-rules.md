# Accounting Rules

## Exact amounts

All INR monetary fields use signed PostgreSQL `BIGINT` integer paise. Domain constraints restrict fields such as credit limits and driver limits to non-negative values. Client code may format paise as rupees for display, but decimal/floating-point UI values are never authoritative.

The maximum supported amount is bounded by `BIGINT`; later posting functions must use checked arithmetic and reject overflow.

## Authoritative balances

`credit_accounts` establishes account identity and currency but stores no mutable
balance. Outstanding principal is derived from posted
`CUSTOMER_ACCOUNTS_RECEIVABLE` ledger entries:

```text
outstanding principal = AR debits - AR credits
available credit      = credit limit - outstanding principal
```

Phase 2A writes only AR debits, so principal cannot become negative through the
implemented workflow. A later repayment slice can credit AR without changing
the balance formula. Interest remains separate and is not posted in Phase 2A.

Cached balances may be added later only if:

- ledger entries remain the source of truth;
- the cache updates in the same database transaction;
- reconciliation can recompute it;
- tests prove cache/ledger equality.

## Ledger invariants

- Posted financial entries are append-only.
- Corrections use explicit reversal or compensating entries, never update/delete.
- Each posted business transaction has equal debit and credit totals.
- A fuel-credit sale has exactly two equal legs: debit customer accounts
  receivable and credit fuel-sales revenue.
- Available credit is checked after locking the target credit-account row with
  `FOR UPDATE`; the sale, transaction header, entries, idempotency result, and
  audit event commit or roll back together.
- A high-entropy UUID idempotency key is unique within the organization and
  operation. Same-key/same-payload replay returns the original receipt;
  same-key/different-payload fails.
- The authenticated actor, tenant, station, and account are derived and verified server-side.
- A successful posting writes an immutable audit event in the same transaction.
- Money parameters are validated as integral paise before a checked cast to
  `BIGINT`; arithmetic uses `NUMERIC` intermediates where overflow is possible.

## Existing Java behavior to preserve or resolve

- Existing SQLite transaction types are DEBIT (fuel credit extended) and CREDIT (payment received).
- Payments use FIFO allocation against oldest debits in reporting calculations.
- Voided SQLite transactions remain present and are excluded from posted sums.

Before migration, define how those concepts map to balanced ledger accounts, how overpayments are represented, and how legacy VOID records become reversals without rewriting history.

## Phase 2A exclusions

No repayment, interest accrual/posting, reversal command, price/litre/pump/nozzle
capture, mutable balance cache, inventory movement, cash reconciliation, or
legacy-data migration is implemented. Reversal remains a required append-only
future workflow.
