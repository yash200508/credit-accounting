# Accounting Rules

## Exact amounts

All INR monetary fields use signed PostgreSQL `BIGINT` integer paise. Domain constraints restrict fields such as credit limits and driver limits to non-negative values. Client code may format paise as rupees for display, but decimal/floating-point UI values are never authoritative.

The maximum supported amount is bounded by `BIGINT`; later posting functions must use checked arithmetic and reject overflow.

## Authoritative balances

Phase 1 intentionally stores no outstanding-principal or outstanding-interest aggregate. `credit_accounts` establishes account identity and currency only. The future authoritative balance will be derived from immutable ledger entries written by an atomic posting function.

Cached balances may be added later only if:

- ledger entries remain the source of truth;
- the cache updates in the same database transaction;
- reconciliation can recompute it;
- tests prove cache/ledger equality.

## Future ledger invariants

- Posted financial entries are append-only.
- Corrections use explicit reversal or compensating entries, never update/delete.
- Each business transaction balances its debit and credit legs.
- Available credit is checked and posting is completed in one serializable or otherwise concurrency-safe database operation.
- A client-provided idempotency key is unique within an appropriate tenant/account scope.
- The authenticated actor, tenant, station, and account are derived and verified server-side.
- A successful posting writes an immutable audit event in the same transaction.

## Existing Java behavior to preserve or resolve

- Existing SQLite transaction types are DEBIT (fuel credit extended) and CREDIT (payment received).
- Payments use FIFO allocation against oldest debits in reporting calculations.
- Voided SQLite transactions remain present and are excluded from posted sums.

Before migration, define how those concepts map to balanced ledger accounts, how overpayments are represented, and how legacy VOID records become reversals without rewriting history.

## Phase 1 exclusions

No financial transaction, repayment, ledger entry, balance cache, receipt, reconciliation process, or idempotent posting function is created in this phase.
