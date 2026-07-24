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
| pgTAP | 439/439 pass (288 existing + 151 Phase 2C) |
| Phase 2A concurrency | Pending final consolidated rerun |
| Phase 2B concurrency | Pending final consolidated rerun |
| Phase 2C concurrency | Pass: duplicate, repayment, and fuel races |
| Scheduler registration | Pass; registration/privileges only, not elapsed-time execution |
| Database lint | Pending final consolidated rerun |
| Repository hygiene | Pending final consolidated rerun |
| Java/Maven | Baseline 37/37; pending final consolidated rerun |

The final consolidated validation and CI links are recorded before the draft
pull request is handed off.

## Security review boundary

The engine excludes interest-on-interest by selecting only posted fuel
principal lots. Clients cannot provide rate, grace snapshot, ledger code,
accrual date, actor, tenant, or global trigger authority. Functions use empty
search paths and fully qualified objects. New evidence is forced-RLS and
append-only. `service_role` receives no raw financial bypass in the repository's
hardened model.

This is an internal engineering review, not an independent professional
financial, tax, legal, or security audit.

## Deferred

Production deployment and cron observation, external alerting, operator UI,
manual client interest charges, compounding, penalties, alternative day-count
bases, overpayments, non-cash methods, reversals, refunds, QR flows, client
applications, and legacy-data migration remain deferred.
