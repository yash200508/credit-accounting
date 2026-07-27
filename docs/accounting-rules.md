# Accounting Rules

## Exact amounts

All INR monetary fields use signed PostgreSQL `BIGINT` integer paise. Domain constraints restrict fields such as credit limits and driver limits to non-negative values. Client code may format paise as rupees for display, but decimal/floating-point UI values are never authoritative.

The maximum supported amount is bounded by `BIGINT`. Trusted posting functions
validate integral `NUMERIC` inputs before casting and use checked arithmetic to
reject overflow.

## Authoritative balances

`credit_accounts` establishes account identity and currency but stores no
mutable balance. Principal and interest are distinct obligations derived from
posted ledger entries:

```text
outstanding principal = CUSTOMER_ACCOUNTS_RECEIVABLE debits
                        - CUSTOMER_ACCOUNTS_RECEIVABLE credits
outstanding interest  = CUSTOMER_INTEREST_RECEIVABLE debits
                        - CUSTOMER_INTEREST_RECEIVABLE credits
total due             = outstanding principal + outstanding interest
available credit      = credit limit - outstanding principal
```

Interest does not consume available credit under the approved Phase 2B policy.
The trusted repayment function rejects any component above its corresponding
obligation, so neither derived balance can become negative. There is no
authoritative cached balance.

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
- An engine-created interest charge has exactly two equal legs: debit customer
  interest receivable and credit interest income. The private Phase 2C engine
  is the only production path; no normal client can choose codes, rate, policy,
  amount, or accrual date.
- A principal-only repayment debits cash on hand and credits customer accounts
  receivable by the same amount.
- An interest-only repayment debits cash on hand and credits customer interest
  receivable by the same amount.
- A split repayment has one cash debit for the total and one credit to each
  receivable for the exact positive component.
- Repayment allocation rows must sum exactly to the cash total. Split mode
  requires both components; one-sided payments use the one-sided mode.
- Available credit is checked after locking the target credit-account row with
  `FOR UPDATE`; the sale, transaction header, entries, idempotency result, and
  audit event commit or roll back together.
- Repayment uses the same account-row lock and commits or rolls back its
  repayment detail, allocations, transaction, entries, audit event, and
  idempotency result together.
- A high-entropy UUID idempotency key is unique within the organization and
  operation. Same-key/same-payload replay returns the original receipt;
  same-key/different-payload fails.
- The authenticated actor, tenant, station, and account are derived and verified server-side.
- A successful posting writes an immutable audit event in the same transaction.
- Money parameters are validated as integral paise before a checked cast to
  `BIGINT`; arithmetic uses `NUMERIC` intermediates where overflow is possible.
- Daily interest is simple interest on FIFO-derived remaining fuel principal
  only. Exact fractional paise carry forward; `round(NUMERIC)` applies half
  away from zero only at the account/day posting boundary.
- Positive daily interest debits `CUSTOMER_INTEREST_RECEIVABLE` and credits
  `INTEREST_INCOME`. Zero-whole-paise days retain calculation evidence without
  creating financial entries or a success audit.

## Existing Java behavior to preserve or resolve

- Existing SQLite transaction types are DEBIT (fuel credit extended) and CREDIT
  (payment received).
- SQLite reporting uses FIFO allocation against oldest debits. Phase 2B instead
  records the employee's explicit principal/interest choice. A governed legacy
  migration must reconcile this semantic difference rather than silently
  importing FIFO results.
- Voided SQLite transactions remain present and are excluded from posted sums.

Before migration, define how legacy VOID records become append-only reversals
without rewriting history. Overpayments are rejected in Phase 2B; unallocated
customer credit is not represented.

## Phase 2D correction rules and exclusions

Posted financial rows remain immutable. A correction creates an exact
`FINANCIAL_REVERSAL` with positive paise and swapped debit/credit directions,
then optionally invokes a typed fuel or repayment replacement in the same
transaction. Both new transactions use the station-local execution date.

Fuel reversal is blocked after FIFO principal consumption or source-linked
interest. Repayment reversal is blocked when restored principal exceeds the
credit limit or later accrual used the reduced principal. Interest-charge
reversal is blocked until an append-only cumulative-interest/carry adjustment
model is proven.

Compounding, client-created interest, alternative day-count bases, historical
restatement, correction cascades, overpayment balances, unallocated credit,
non-cash methods, refunds, price/litre/pump/nozzle capture, inventory movement,
cash reconciliation, and legacy-data migration remain excluded.
