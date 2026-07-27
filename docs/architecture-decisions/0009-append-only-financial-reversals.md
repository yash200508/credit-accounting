# ADR 0009: Append-Only Financial Reversals

- Status: Accepted
- Date: 2026-07-27

## Context

Posted fuel sales, repayments, allocations, interest evidence, transactions, and entries are immutable. Correcting an error by editing or deleting a posted row would erase the original evidence and could detach business records from the ledger.

## Decision

An approved correction creates a new `FINANCIAL_REVERSAL` transaction. The database copies every original entry, preserves account, amount, and currency, and swaps `DEBIT` with `CREDIT`. Amounts remain positive integer paise.

`financial_reversals` permanently links the request, original, reversal, and optional typed replacement. Unique constraints allow one executed reversal per original and one financial effect per request. Deferred guards compare the entry multisets and reject any non-exact compensation.

The reversal and replacement use the station-local execution date. The original business date remains immutable evidence; this phase does not backpost or restate a historical period.

## Consequences

- Ledger-derived obligations include the compensating entries without rewriting history.
- A reversal transaction cannot itself be reversed in Phase 2D.
- Fuel and repayment replacements use their existing trusted posting functions.
- Historical restatement, cascaded corrections, refunds, unallocated credit, and manual interest are deferred.
