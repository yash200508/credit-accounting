# ADR 0003: Trusted Financial Posting Functions

- Status: Accepted
- Date: 2026-07-24

## Context

Customer/account creation and fuel-credit posting span protected tables and
must validate authorization, credit, idempotency, ledger shape, and audit
evidence atomically. Direct table grants cannot safely express that workflow.

## Decision

Expose narrowly scoped `SECURITY DEFINER` database functions to
`authenticated`, with empty `search_path`, fully qualified objects, actor
identity from `auth.uid()`, server-derived ownership fields, explicit
validation, stable application errors, and minimal return projections.
Execution is revoked from `PUBLIC` and `anon`; direct client writes remain
revoked.

Fuel posting claims idempotency before locking the target credit-account row,
then recalculates available credit under that lock. All records and the audit
event share the caller's database transaction.

## Consequences

Database functions are the security and consistency boundary and therefore
require negative authorization, rollback, replay, and concurrency tests.
Clients cannot compose partial writes. The functions do not replace RLS:
tables still have enabled and forced policies plus least-privilege grants.

The functions are intentionally operation-specific. New repayment, reversal,
interest, or administration behavior requires a separate reviewed capability,
not expansion of these inputs.
