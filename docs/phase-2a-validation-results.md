# Phase 2A Validation Results

Validation date: 2026-07-24

Branch: `codex/phase-2-credit-posting-core`

Starting commit: `5e9bf5ef016a386627b6549b0510ea9c12c616e5` (merged Phase 1 PR #8)

## Scope and safety boundary

Phase 2A implements one local-only financial path: an authorized owner or
assigned manager atomically creates a customer and INR credit account, and an
authorized station actor atomically posts a fuel-credit sale as balanced,
append-only ledger data with an immutable audit event and an idempotent result.

No remote Supabase project, production configuration, real credential, real
customer record, or SQLite customer data was read or changed. Flutter, Next.js,
QR login, repayments, interest posting, reversals, attendance, pump/nozzle
readings, inventory, and cash reconciliation remain deferred.

## Skills and review methods

| Skill or method | Contribution |
|---|---|
| Supabase development | Guided local migration, RLS, function-security, reset, pgTAP, and lint practices. |
| Supabase PostgreSQL best practices | Guided indexes, constraints, integer money, locking, safe function boundaries, and query design. |
| CSO security review | Applied a STRIDE-oriented review to authorization, tenant/station spoofing, raw writes, secrets, CI, and local exposure. |
| Pre-landing review | Reviewed the complete `origin/main...HEAD` diff, database/API contracts, test coverage, CI, and documentation consistency. |
| Repository-specific accounting ADRs and tests | Supplied the financial-data review because no dedicated installed financial-ledger skill was available. |

The security work was an internal engineering review, not an independent
professional security or financial audit.

## Implemented database boundary

The Phase 1 migrations were not rewritten. Five ordered migrations add:

1. A `FINANCIAL` audit category.
2. Configurable `fuel_products`.
3. Append-only `ledger_transactions` and `ledger_entries`.
4. One-to-one posting detail in `fuel_credit_sales`.
5. Scoped request fingerprints and replay results in `idempotency_keys`.
6. Trusted customer creation, authoritative balance lookup, and fuel-credit
   posting functions.
7. Forced RLS, least-privilege policies, explicit table/function grants, and
   raw-write revocations.

All authoritative monetary values are `BIGINT` paise in INR. The credit account
has no mutable authoritative outstanding-balance column. For this slice:

```text
outstanding principal = posted customer-accounts-receivable debits
                        - posted customer-accounts-receivable credits
available credit      = credit limit - outstanding principal
```

A fuel-credit purchase creates exactly:

```text
Debit  CUSTOMER_ACCOUNTS_RECEIVABLE
Credit FUEL_SALES_REVENUE
```

Both entries use the same positive amount. A deferred constraint trigger
rejects an unbalanced or incorrectly shaped posted transaction, while immutable
triggers reject later financial mutation or deletion.

## Trusted operations

`public.create_customer_with_credit_account(...)` derives the actor from
`auth.uid()`, accepts only validated business inputs, and creates the customer,
settings, active INR account, station relationship, and audit event in one
transaction. Owners are limited to owned organizations; managers are limited to
active assigned stations. Attendants, customers, drivers, anonymous callers,
revoked actors, and unrelated managers are denied.

`public.post_fuel_credit_transaction(...)` derives the actor, organization,
role, ledger identities, posted state, timestamps, and audit identity
server-side. An owner, assigned manager, or assigned attendant may post only at
an active station they are authorized to use, for an active customer, active
credit account, and applicable active product in the same tenant.

Both mutation functions are `SECURITY DEFINER` with an empty fixed
`search_path`. Execution is revoked from `PUBLIC` and `anon` and granted only
to `authenticated`. Normal clients have no raw write privileges on the new
financial tables, and the generated `service_role` privileges are explicitly
revoked as well. Read policies expose only the minimum owner/manager scope;
attendants use the posting boundary rather than broad financial-table reads.

## Credit-limit concurrency

The posting function claims the idempotency request, locks the target credit
account with `FOR UPDATE`, then derives principal and available credit after
the lock. Competing postings for one account therefore serialize until the
first transaction commits or rolls back.

The executable two-session harness used a fresh INR 1,000 account and raced two
INR 700 posts. Exactly one committed; the other returned
`FCP_INSUFFICIENT_CREDIT`. Final principal was INR 700, available credit was
INR 300, and the losing request left no transaction, entries, sale, audit event,
or idempotency result.

## Idempotency and audit

An idempotency key is unique within its organization and operation type. The
credit account and other material inputs are bound into a SHA-256 fingerprint
of the canonical non-secret request payload. The first successful request
stores a safe receipt. The same key and payload returns that receipt without
another financial effect or audit-success event. The same key with a changed
account or other changed payload returns a deterministic conflict. Failed
requests roll back the key and may be retried safely.

Successful customer creation and successful fuel posting each create an
immutable audit event in the same transaction. Financial audit metadata records
derived actor/role and scoped business identifiers, amount, product, and safe
correlation/idempotency references. It excludes authentication tokens,
passwords, raw QR material, service keys, and unnecessary customer PII.

## Final local validation

| Check | Command/result |
|---|---|
| Supabase CLI | Pinned `2.109.1` |
| Clean database rebuild | PASS; all Phase 1 and Phase 2A migrations plus deterministic fake seed applied |
| pgTAP | PASS; 2 files, 185 tests, 0 failures (64 preserved Phase 1 + 121 Phase 2A) |
| Concurrency harness | PASS; one INR 700 success, one insufficient-credit failure, final INR 700 principal / INR 300 available, no partial loser rows |
| Database lint | PASS; `public` and `app_private`, no results and no schema errors |
| Repository hygiene | PASS; 109 tracked files, no runtime artifacts, key material, token-shaped secrets, disabled RLS, broad true policies, or mutable Actions refs |
| Maven regression | PASS with Eclipse Adoptium JDK 17.0.17; 37 tests, 0 failures/errors/skips, JAR built |
| Dependency inventory | PASS; Maven dependency tree resolved successfully |
| OWASP Dependency-Check 12.2.2 | Inconclusive; the initial public vulnerability-feed scan produced no report before a 10-minute timeout. No vulnerability conclusion is claimed. |

The existing non-blocking Log4j2 SimpleLogger fallback warning remains in the
legacy Java build. Phase 2A did not change Java production sources or
dependencies.

## Security review findings

Two actionable findings were fixed before final validation:

1. Supabase's generated `service_role` retained default raw table privileges
   despite the authenticated-client revocations. Explicit revocations now
   remove all raw reads and writes for the five financial tables, and pgTAP
   locks that boundary in.
2. GitHub Actions used mutable major-version tags. Both workflows now pin each
   action to an immutable commit SHA, and repository hygiene rejects future
   mutable action references.

The review also verified fixed privileged-function search paths, narrow execute
grants, forced RLS, absence of unconditional-true policies, actor/tenant/station
derivation, checked integer arithmetic, post-lock balance calculation,
idempotency conflict behavior, ledger/audit immutability, cross-tenant balance
denial, argument-array subprocess execution, and absence of tracked
token-shaped secrets.

## CI and publication

The Maven and Supabase workflows remain separate. Supabase CI uses CLI 2.109.1,
Python 3.12, a clean local start/reset, all pgTAP tests, the concurrency harness,
database lint, repository hygiene, failure logs, and unconditional container
cleanup. It requires no remote Supabase credentials.

Draft PR: [#9, Phase 2A: add secure credit posting core](https://github.com/yash200508/credit-accounting/pull/9).

The published code-and-validation head `7c943d1` completed both independent
pull-request workflows successfully:

- Maven CI run 15: PASS.
- Supabase CI run 4: PASS, including clean start/reset, 185 pgTAP tests,
  concurrency, lint, hygiene, failure-log wiring, and container cleanup.

The documentation-only commit that records these results must also have green
current-head checks before Phase 2A is declared complete.

## Remaining risks and next slice

- The local Supabase stack uses public development defaults and warns that
  services bind beyond loopback. Use it only on a trusted, firewalled
  workstation; do not expose an unauthenticated Docker API.
- The external dependency vulnerability scan remains incomplete because its
  first public-feed run timed out. A maintained scanner with an NVD API key
  should run before production release.
- Production secret management, MFA/session policy, abuse controls,
  monitoring, backup/restore drills, deployment hardening, and an independent
  professional review remain required.
- Future trusted workflows that mutate limits, memberships, station
  assignments, or products must preserve the documented lock ordering and
  authorization model.

The recommended next slice is **repayment posting and principal/interest
allocation**. It should extend the ledger with repayment effects without
rewriting the authoritative balance model. It was not started in Phase 2A.
