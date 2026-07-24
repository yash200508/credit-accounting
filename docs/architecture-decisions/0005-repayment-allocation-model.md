# ADR 0005: Explicit Repayment Allocation Model

- Status: Accepted
- Date: 2026-07-24

## Context

Phase 2A established an append-only ledger, organization-scoped idempotency,
server-derived authorization, and a credit-account row lock for fuel-credit
posting. Repayment must reduce existing posted obligations without introducing
a mutable balance, accepting overpayment, or silently choosing how money is
allocated.

The business requires the station employee to choose principal only, interest
only, or an exact split. A customer or driver may physically deliver the cash,
but only an authenticated station-side employee may post it.

## Decision

Add immutable `customer_repayments` and `repayment_allocations` business-detail
tables. A repayment records one cash receipt and one or two allocation rows:

- `PRINCIPAL_ONLY` has one positive principal allocation equal to the total;
- `INTEREST_ONLY` has one positive interest allocation equal to the total;
- `SPLIT` has positive principal and interest allocations whose sum equals the
  total.

A split with a zero component is rejected as ambiguous; callers use the
corresponding one-sided mode instead. No amount is redirected automatically.
Allocations above the corresponding authoritative obligation are rejected.
Unallocated credit and overpayment balances are not created.

Extend the ledger transaction and account-code enums for customer repayment,
test-only historical interest charges, cash on hand, interest receivable, and
interest income. Posted accounting is:

```text
Principal: Debit CASH_ON_HAND; Credit CUSTOMER_ACCOUNTS_RECEIVABLE
Interest:  Debit CASH_ON_HAND; Credit CUSTOMER_INTEREST_RECEIVABLE
Split:     Debit CASH_ON_HAND for total; credit each receivable by its allocation
```

Outstanding principal and interest remain ledger-derived. Available credit is
the configured limit minus principal only. Interest does not consume credit.
An additive obligations RPC returns principal, interest, total due, and
available credit while preserving the Phase 2A balance RPC.

`post_customer_repayment` is a narrowly scoped `SECURITY DEFINER` function. It
derives the actor and tenant, validates the station and optional driver, claims
an organization/operation/idempotency UUID, locks the credit account with
`FOR UPDATE`, recalculates both obligations, rejects excess allocation, and
writes the repayment, allocations, ledger, audit, and replay result in one
transaction.

When a driver is supplied, the driver must be active, belong to the account's
customer and organization, and have a currently valid permission period. The
driver is attribution only; the parent customer credit account remains the
sole financial account and the driver does not authorize the station actor.

Database constraint triggers verify both the allocation total and the exact
ledger shape. Update/delete triggers make repayments and allocations
append-only. Direct client and generated service-role writes are revoked.

## Consequences

- Explicit staff intent is preserved and auditable.
- Principal and interest can evolve independently without cached balances.
- Repayment and fuel posting serialize through the same account row.
- Same-payload retry returns the original receipt; changed material input
  conflicts; failed requests leave no consumed key.
- Cash is the only payment method in this slice, but the stored enum can be
  extended later.
- Historical interest fixtures can be balanced in tests without exposing an
  interest-charge RPC.

Automated interest calculation, grace execution, accrual scheduling,
compounding, refunds, reversals, and customer credit balances remain separate
reviewed capabilities.
