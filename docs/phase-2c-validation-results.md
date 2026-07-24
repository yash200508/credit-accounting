# Phase 2C Validation Results

## Scope

Phase 2C implements exact daily simple-interest accrual locally. No remote
Supabase project, production secret, real SQLite database, or real customer
data was used.

## Implemented evidence

- Six ordered migrations add IANA station timezones, immutable ledger business
  dates, non-overlapping policy history, run/accrual/component evidence,
  effective policy/FIFO lot helpers, exact posting, bounded station cycles,
  pg_cron registration, and RLS/grants.
- The 18% organization default, customer override precedence, fixed 365 basis,
  both grace variants, disabled periods, inactive debt, leap day, fractional
  carry, balanced interest accounting, and no-compounding basis are exercised.
- Positive postings create one immutable financial audit event; zero-post
  days retain calculation evidence without a misleading financial event.

## Local results

| Check | Result |
|---|---|
| Clean migration reset | Pass |
| pgTAP | 447/447 pass (288 existing + 159 Phase 2C) |
| Phase 2A concurrency | Pass |
| Phase 2B concurrency | Pass: all three scenarios |
| Phase 2C concurrency | Pass: duplicate, repayment, and fuel races |
| Scheduler registration | Pass; registration/privileges only, not elapsed-time execution |
| Database lint | Pass: no `public` or `app_private` errors |
| Repository hygiene | Pass: 134 tracked files |
| Java/Maven | Pass: 37/37 |

The final consolidated local run used Supabase CLI 2.109.1 and Java 17.0.17.
CI status and links are recorded on the draft pull request.

## Security review boundary

The engine excludes interest-on-interest by selecting only posted fuel
principal lots. Clients cannot provide rate, grace snapshot, ledger code,
accrual date, actor, tenant, or global trigger authority. Functions use empty
search paths and fully qualified objects. New evidence is forced-RLS and
append-only. `service_role` receives no raw financial bypass in the repository's
hardened model.

The pre-landing review found and fixed two accounting edge cases before the
final run:

- posting now derives the incremental amount from the rounded cumulative exact
  target, so a prior `-0.5` residual can never create a negative reversal on a
  later zero-raw day;
- a deferred invariant now requires every system-authored interest ledger
  charge to match immutable accrual detail by tenant, station, account,
  customer, date, currency, and amount.

After those fixes, the security and pre-landing reviews reported no remaining
actionable findings.

This is an internal engineering review, not an independent professional
financial, tax, legal, or security audit.

## Deferred

Production deployment and cron observation, external alerting, operator UI,
manual client interest charges, compounding, penalties, alternative day-count
bases, overpayments, non-cash methods, reversals, refunds, QR flows, client
applications, and legacy-data migration remain deferred.
