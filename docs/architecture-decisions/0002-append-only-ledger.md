# ADR 0002: Append-Only Authoritative Ledger

- Status: Accepted for future implementation
- Date: 2026-07-24

## Context

The SQLite application stores DEBIT/CREDIT transactions that can be marked VOID and derives balances by summing posted rows. A centralized multi-user system must withstand concurrent posting, retries, corrections, and audit requirements. Mutable balance fields or client-side calculations cannot provide adequate integrity.

## Decision

The authoritative financial record will be an append-only, balanced ledger. Posted entries will not be updated or deleted. Corrections will use linked reversal or compensating entries. One trusted atomic operation will validate actor, tenant, station, customer/account, driver/QR authorization, limits, available credit, and idempotency before writing ledger entries and an immutable audit event in the same database transaction.

All amounts are `BIGINT` paise. An idempotency key will be unique in a defined tenant/account/request scope. Any future cached balance is a transactionally maintained derivative that can be reconciled from the ledger.

## Consequences

- Histories remain explainable and auditable.
- Retries and concurrency can be made safe.
- Corrections increase record count rather than rewriting history.
- Reporting must understand reversals and accounting periods.
- The account chart, balanced-entry rules, lock/isolation strategy, and legacy conversion require explicit design and tests.

## Phase 1 implication

Phase 1 creates account identity and policy configuration but intentionally omits ledger tables, posting functions, balances, and real transaction imports. This avoids prematurely freezing unsafe accounting semantics.
