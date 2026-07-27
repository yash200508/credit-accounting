# Phase 2D Validation Results

## Scope

Phase 2D adds governed, append-only reversal and typed correction workflows
for posted fuel-credit sales and customer repayments. Interest-charge reversal
remains explicitly blocked because reversing a charge without rewriting its
cumulative accrual and fractional-carry history is not yet mathematically safe.
No remote Supabase project, production secret, real SQLite database, or real
customer data was used.

## Local results

The final consolidated local run on 2026-07-27 used Supabase CLI 2.109.1,
PostgreSQL in the local Supabase stack, Java 17.0.17, and Maven 3.9.12.

| Check | Result |
|---|---|
| Clean migration reset | Pass; all migrations and fake seed rebuilt from zero |
| pgTAP | 567/567 pass: 447 existing plus 120 Phase 2D |
| Phase 2A concurrency | Pass: one safe winner at the credit limit |
| Phase 2B concurrency | Pass: repayment, fuel-posting, and driver-revocation races |
| Phase 2C concurrency | Pass: duplicate, repayment, and fuel/accrual races |
| Phase 2D concurrency | Pass: approval, fuel, accrual, and cancellation races |
| Scheduler registration | Pass; registration and privileges checked without waiting for wall clock |
| Database lint | Pass; no `public` or `app_private` warnings or errors |
| Repository hygiene | Pass before staging; repeated after the final staged file set |
| `git diff --check` | Pass |
| Java/Maven | Pass: 37/37 tests |
| Draft-PR CI | Authoritative exact-head status is recorded on the draft PR |

## Phase 2D evidence

The 120 Phase 2D assertions cover schema, leading foreign-key indexes, forced
RLS, narrow grants, direct-write denial, requester and approver scope,
self-approval denial, mandatory safe reasons, idempotency conflicts, optimistic
versions, exact entry inversion, current station-local dates, fuel and
repayment dependencies, fuel replacement credit limits, repayment allocation
and driver validation, atomic rollback, terminal states, immutable events and
reversal evidence, audit privacy, correction-aware FIFO, stale-preview
recalculation, and explicit interest-reversal blocking.

The independent-session Phase 2D harness proves:

1. Two owners approving one request create one reversal, at most one
   replacement, and one approval-success event.
2. Repayment reversal and a new fuel purchase serialize through the account
   lock without exceeding the credit limit or leaving partial rows.
3. Fuel reversal and interest accrual serialize without a torn principal basis
   or duplicate accrual.
4. Approval and cancellation produce exactly one terminal outcome.

## Catalog and security checks

Direct catalog inspection after the clean reset confirmed that all five new
protected tables have RLS enabled and forced, authenticated clients hold only
RLS-filtered `SELECT`, and `anon` and `service_role` hold no table privilege.
Only authenticated callers may execute the five public correction RPCs. All
new `SECURITY DEFINER` functions use an empty fixed `search_path`; private
helpers have no client execution grant. Every public foreign key has a usable
leading-column index. Immutable triggers reject client updates/deletes to
events, proposals, reversals, and terminal request evidence.

Static review found no credential-shaped secret, untrusted workflow expression,
mutable GitHub Action reference, `pull_request_target`, or interpolated
shell-command path in the Phase 2D change. This is an internal engineering
review, not an independent professional financial, legal, tax, or security
audit.
