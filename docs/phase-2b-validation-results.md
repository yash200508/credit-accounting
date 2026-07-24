# Phase 2B Validation Results

Validation date: 2026-07-24

Branch: `codex/phase-2b-repayment-allocation`

Starting commit: `bceab8841e1028d9864876eb7a9aee02542294a9`
(merged Phase 2A PR #9)

## Scope and safety boundary

Phase 2B implements one local-only financial path: an authenticated owner,
assigned manager, or assigned attendant receives cash from a customer or
active linked driver, explicitly allocates it to principal, interest, or both,
and atomically posts immutable business detail, balanced ledger entries, a safe
idempotent result, and an audit event.

No remote Supabase project, production configuration, real credential, real
customer record, or SQLite customer data was read or changed. Automated
interest calculation/accrual, grace execution, compounding, a production
interest-charge API, overpayment balances, unallocated credit, non-cash
methods, refunds, reversals, QR resolution, client applications, inventory,
pumps/nozzles, attendance, and cash reconciliation remain deferred.

## Skills and review methods

| Skill or method | Contribution |
|---|---|
| Supabase development | Guided ordered migrations, local reset, forced RLS, function security, pgTAP, and lint. |
| Supabase PostgreSQL best practices | Guided tenant-safe foreign keys, indexes, integer money, constraints, lock ordering, fixed search paths, and least privilege. |
| CSO security-review checklist | Applied host-compatible read-only checks for actor/customer/driver/station spoofing, allocation tampering, races, secrets, CI, OWASP, and STRIDE. Its optional interactive wrapper could not run because this host exposes no required AskUserQuestion control. |
| Pre-landing review checklist | Reviewed the full branch diff for SQL/data safety, concurrency, enum completeness, field contracts, test gaps, CI, scope, and documentation consistency. The same optional wrapper limitation applied. |
| Repository accounting ADRs and pgTAP tests | Supplied double-entry and financial-state review because no dedicated installed financial-ledger skill was available. |

This is an internal engineering review, not an independent professional
financial or security audit.

## Ordered migrations

The Phase 1 and Phase 2A migrations were not rewritten. Five later migrations
add:

1. `20260724193158_repayment_ledger_schema.sql`
2. `20260724193201_repayment_business_schema.sql`
3. `20260724193204_account_obligations_balance.sql`
4. `20260724193207_post_customer_repayment.sql`
5. `20260724193255_repayment_rls_and_grants.sql`

They add `CUSTOMER_REPAYMENT` and `INTEREST_CHARGE` transaction types;
`CASH_ON_HAND`, `CUSTOMER_INTEREST_RECEIVABLE`, and `INTEREST_INCOME` account
codes; a distinct repayment idempotency operation; allocation, component,
payment-method, and payer types; immutable `customer_repayments` and
`repayment_allocations`; additive idempotency receipt fields; obligation
calculation; trusted posting; and RLS/grants.

## Allocation and accounting

All monetary values are positive integral `BIGINT` paise after checked
`NUMERIC` validation.

| Mode | Required allocation | Posted entries |
|---|---|---|
| `PRINCIPAL_ONLY` | principal = total; interest = 0 | Dr cash / Cr principal receivable |
| `INTEREST_ONLY` | principal = 0; interest = total | Dr cash / Cr interest receivable |
| `SPLIT` | both explicit positive components sum exactly to total | Dr cash total / Cr each receivable |

The server never applies interest first, redirects excess between components,
discards cash, or creates an unallocated balance. A one-sided split is rejected
as ambiguous and must use its one-sided mode. Each component must fit its
authoritative posted obligation. Any overpayment is rejected.

Deferred constraint triggers require allocation totals and exact
transaction-type ledger shapes at commit. Hard triggers reject update/delete
of repayment, allocation, posted transaction, ledger-entry, and audit rows.

Historical interest fixtures use the balanced shape below only in privileged
test setup:

```text
Debit  CUSTOMER_INTEREST_RECEIVABLE
Credit INTEREST_INCOME
```

There is no production interest-charge function.

## Derived obligations

`app_private.calculate_credit_account_obligations(account_id)` derives:

```text
outstanding principal = principal-receivable debits - credits
outstanding interest  = interest-receivable debits - credits
total due             = principal + interest
available credit      = credit limit - principal
```

`public.get_credit_account_obligations(account_id)` exposes a safe authorized
projection to an owner, assigned manager, assigned attendant with the exact
account ID, or the linked customer. The older Phase 2A balance interface
remains unchanged. Interest does not consume available credit under the current
policy.

## Trusted repayment operation

`public.post_customer_repayment(...)`:

1. derives the employee from `auth.uid()` and active role assignments;
2. validates organization, station, account, customer, integer amount, explicit
   allocation, cash method, safe reference, and optional driver;
3. fingerprints all material canonical non-secret inputs, including
   organization and payer identity;
4. claims an organization/operation/UUID idempotency key;
5. locks the same credit-account row used by fuel posting;
6. revalidates the account, customer, driver, and permission state;
7. holds `FOR SHARE` locks on driver/permission rows through commit;
8. recalculates principal and interest after the account lock;
9. rejects any excessive component or nothing-due payment;
10. writes transaction, repayment, allocations, entries, audit, and replay
    result in one transaction; and
11. returns identifiers, payer attribution, exact allocations, method,
    currency, derived obligations, replay flag, and server timestamp.

No caller can supply actor, role, tenant, customer, ledger code, posted state,
audit identity, balance, or timestamp.

## Driver attribution

No driver ID records the customer as physical payer. A supplied driver must be
in the same tenant, belong to the account customer, be `ACTIVE`, and have a
permission effective on the server date and not expired. Revoked, expired,
wrong-customer, and cross-tenant drivers fail with stable `RPP_*` errors.

The authenticated station employee remains `received_by` and the audit actor.
Driver attribution grants no authority and creates no driver credit account,
principal, interest, or balance.

## Idempotency and audit

The first valid request posts once. Same-key/same-canonical-payload replay
returns the original safe receipt without another repayment, allocation,
transaction, entry, or audit event. Same-key/changed amount, allocation,
driver, method, account, station, reference, or other material input returns
`RPP_IDEMPOTENCY_CONFLICT`. A failed request rolls back its key and remains
retryable.

The success audit records derived actor/role and safe organization, station,
customer, account, repayment, transaction, allocation, payer, method, currency,
and UUID correlation data. It excludes names, phones, source-reference text,
request fingerprints, passwords, tokens, QR secrets, and service credentials.

## Authorization, RLS, and grants

- Owner: posts only in owned organizations.
- Manager and attendant: post/read exact obligations only at active assigned
  stations.
- Customer, driver, unrelated user, revoked actor, cross-tenant actor, and
  anonymous caller: cannot post.
- RLS is enabled and forced on both new tables.
- Owners and assigned managers may select in financial station scope;
  attendants receive receipts but have no broad financial browse.
- Normal authenticated clients have no direct financial insert/update/delete.
- `PUBLIC`, `anon`, and `service_role` cannot execute the repayment or
  obligations RPCs; only `authenticated` can.
- `service_role` has no raw access to repayment, allocation, ledger, or
  idempotency rows.
- All privileged Phase 2B functions use an empty fixed `search_path`.

## Stable errors

The function deliberately returns stable codes for authentication,
authorization, station/account/customer state, invalid amount/mode/allocation,
principal/interest excess, nothing due, invalid/revoked driver, idempotency
required/conflict/retry, cash method/reference validation, arithmetic overflow,
and post-lock account changes. Internal SQL text, stack traces, and secrets are
not deliberately exposed.

## Local validation

| Check | Result |
|---|---|
| Starting baseline | PASS: 37 Java tests, 185 pgTAP assertions, Phase 2A race, lint, and hygiene |
| Supabase CLI | Pinned `2.109.1` |
| Clean database rebuild | PASS: every committed migration plus deterministic fake seed applied |
| pgTAP | PASS: 3 files, 288 assertions, 0 failures; all prior 185 preserved plus 103 Phase 2B assertions |
| Phase 2A concurrency | PASS: one INR 700 purchase committed, one `FCP_INSUFFICIENT_CREDIT`, final INR 700 principal / INR 300 available, no loser rows |
| Phase 2B repayment concurrency | PASS: one of two INR 700 principal repayments committed against INR 1,000 due, one `RPP_PRINCIPAL_EXCEEDS_DUE`, final INR 300 principal / INR 1,700 available, no loser rows |
| Mixed fuel/repayment concurrency | PASS: repayment serialized before waiting fuel post; final INR 900 principal / INR 100 available |
| Driver-revocation concurrency | PASS: non-key revocation waited on shared driver/permission locks until attributed repayment committed |
| Database lint | PASS: `public` and `app_private`, no schema errors |
| Repository hygiene | PASS; no runtime artifacts, token-shaped secrets, disabled RLS, broad-true policies, or mutable Action refs |
| Maven regression | PASS with Eclipse Adoptium JDK 17.0.17; 37 tests, 0 failures/errors/skips |
| Diff whitespace check | PASS |

## Security and pre-landing findings

Three actionable issues were fixed before final validation:

1. The idempotency fingerprint omitted organization even though the database
   key was organization-scoped. Organization is now explicitly included in the
   canonical fingerprint.
2. The obligations RPC initially omitted attendants, preventing the required
   pre-payment server-authoritative view. It now permits exact-account reads
   only at the caller's assigned station and still denies broad table access or
   cross-station lookup.
3. Driver revalidation used `FOR KEY SHARE`, which allows concurrent non-key
   updates. It now uses `FOR SHARE` on driver and permission rows, and a
   separate-session regression proves status revocation waits through commit.

The review also verified account-row serialization, post-lock balance
calculation, explicit component bounds, checked integer arithmetic, deterministic
idempotency conflicts, actor/customer/station/driver derivation, fixed
privileged search paths, forced RLS, least-privilege ACLs including
`service_role`, exact accounting constraints, hard financial/audit
immutability, safe receipts/audit JSON, argument-array subprocess execution,
fake-only fixtures, immutable Action references, and absence of tracked
token-shaped secrets.

## CI and publication

Supabase CI uses CLI 2.109.1 and Python 3.12, starts a clean local stack,
rebuilds from migrations and fake seed, runs all 288 pgTAP assertions, both
named concurrency harnesses (including all three Phase 2B scenarios), lints
`public` and `app_private`, checks repository hygiene, captures failure logs,
and always stops containers. It uses no remote Supabase credential or project.
Maven CI remains separate.

Draft PR and current-head CI run links are recorded after publication.

## Remaining risks and next slice

- The local Supabase stack uses development keys and binds services beyond
  loopback; it must be stopped after validation and used only on a trusted,
  firewalled workstation.
- Production secret management, MFA/session policy, rate/abuse controls,
  monitoring, backup/restore drills, cash-custody reconciliation, deployment
  hardening, and an independent professional review remain required.
- Future driver, customer, station, membership, limit, and interest workflows
  must preserve the account-first lock order where they interact with posting.

The recommended next slice is **automated daily simple-interest accrual with a
configurable grace policy**. Phase 2B now supplies the separate
interest-receivable balance and exact interest-settlement path that accrual
needs. The next slice must add golden interest calculations, idempotent
scheduling, and the same append-only/lock/audit controls. It was not started.
