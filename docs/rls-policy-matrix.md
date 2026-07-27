# RLS Policy Matrix

Every table below has RLS enabled and forced. `anon` receives no table or function access. Table grants and policies are both required; a policy never substitutes for least-privilege grants.

| Table | Owner | Manager | Attendant | Customer | Driver | Client writes |
|---|---|---|---|---|---|---|
| `organizations` | Read owned | Read organization containing assignment | Read organization containing assignment | Read linked organization | No direct read | None |
| `stations` | Read tenant stations | Read assigned | Read assigned | Read own home station | No direct read | None |
| `profiles` | Own profile | Own profile | Own profile | Own profile | Own profile | Own display fields only |
| `organization_memberships` | Read owned tenant | Read own | Read own | Read own | Read own | None |
| `station_memberships` | Read owned tenant | Read assigned station | Read own | None | None | None |
| `role_assignments` | Read owned tenant | Read own/assigned non-owner | Own only | Own only | Own only | None |
| `customers` | Read owned tenant | Read assigned station | Denied broad browse | Own only | Denied; use minimal RPC | None |
| `customer_account_settings` | Read owned tenant | Read assigned station | Denied | Own only | Denied; use minimal RPC | None |
| `credit_accounts` | Read owned tenant | Read assigned station | Denied | Own only | Denied; use minimal RPC | None |
| `customer_drivers` | Read owned tenant | Read assigned station | Denied | Read own drivers | Own active row | None |
| `driver_permissions` | Read owned tenant | Read assigned station | Denied | Read own drivers' permissions | Own active permission | None |
| `qr_credentials` | Read owned tenant | Denied | Denied | Denied | Denied | None |
| `interest_policies` | Read owned tenant | Read assigned-station applicable policies | Denied | Read applicable default/override | Denied | None |
| `audit_events` | Read owned tenant | Read assigned-station events | Denied | Denied | Denied | Insert only inside trusted functions; update/delete never |
| `app_settings` | Read/update owned tenant | Read/update non-protected assigned-station settings | Denied | Denied | Denied | Restricted update columns and row checks |
| `fuel_products` | Read owned tenant | Read applicable assigned-station products | Read applicable assigned-station products | Denied | Denied | None |
| `ledger_transactions` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; trusted function only |
| `ledger_entries` | Read owned tenant | Read entries for assigned-station transactions | Denied | Denied | Denied | None; trusted function only |
| `fuel_credit_sales` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; trusted function only |
| `idempotency_keys` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; trusted function only |
| `customer_repayments` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; trusted function only |
| `repayment_allocations` | Read allocations for readable repayments | Read allocations for assigned-station repayments | Denied | Denied | Denied | None; trusted function only |
| `interest_accrual_runs` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; internal engine only |
| `interest_accruals` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; internal engine only |
| `interest_accrual_components` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; internal engine only |
| `financial_correction_requests` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; trusted RPC only |
| `fuel_credit_correction_proposals` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; trusted RPC only |
| `repayment_correction_proposals` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; trusted RPC only |
| `financial_correction_events` | Read owned tenant | Read events for assigned-station requests | Denied | Denied | Denied | None; immutable trusted evidence |
| `financial_reversals` | Read owned tenant | Read assigned-station rows | Denied | Denied | Denied | None; immutable trusted evidence |

## Privileged helpers

Helpers live in `app_private`, set an empty `search_path`, obtain the actor from `(select auth.uid())`, and use `SECURITY DEFINER` only to read RLS-protected authorization rows without recursive policy evaluation. Their owner retains no application login. `PUBLIC` and `anon` execution are revoked.

Data-returning privileged functions are deliberately narrow:

- `get_my_driver_parent_account()` returns the existing driver projection.
- `get_credit_account_balance(account_id)` returns an authorized account's
  limit, principal, and available credit.
- `get_credit_account_obligations(account_id)` additively returns authorized
  principal, interest, total due, and available credit without breaking the
  Phase 2A interface.
- `create_customer_with_credit_account(...)` returns identifiers and safe
  account configuration after an atomic create.
- `post_fuel_credit_transaction(...)` returns the original or newly committed
  safe receipt.
- `post_customer_repayment(...)` returns the original or newly committed safe
  repayment receipt after explicit allocation and optional driver validation.

Only the two posting functions and customer/account creation mutate data.
`PUBLIC` and `anon` execution are revoked. The application-facing functions are
granted only to `authenticated`; private calculators and authorization helpers
are not client-callable. Phase 2B also explicitly revokes generated
`service_role` table access and function execution for its financial objects,
matching the Phase 2A raw-write boundary.

Phase 2C private functions resolve policies, derive FIFO lots, calculate exact
components, post one account/date, run bounded station cycles, and expose the
fixed cron entry point. `PUBLIC`, `anon`, `authenticated`, and `service_role`
execution is revoked. `cron` schema usage is also revoked from those roles.
Only PostgreSQL's controlled internal job owner invokes the scheduled entry
point.

## Policy rules

- No protected-table policy contains an unrestricted `USING (true)` or `WITH CHECK (true)`.
- Revoked membership, inactive organization/station, inactive customer, or revoked driver status removes applicable access.
- Composite tenant/station foreign keys prevent spoofed cross-organization relationships independently of RLS.
- Direct client writes to role, membership, customer, account, product, ledger,
  sale, repayment, allocation, idempotency, driver, QR, policy, accrual run,
  accrual, component, and audit tables are denied.
- Posted transaction, entry, sale, repayment, and allocation updates/deletes
  are also rejected by triggers; RLS and grants are not the only immutability
  boundary.
- Interest evidence tables are append-only; operational runs permit exactly
  one guarded `STARTED` to final transition.
- Correction requests have a guarded pending-to-terminal update only. Proposal,
  transition-event, and reversal-evidence updates/deletes are rejected by hard
  triggers.
- Authenticated clients receive execute only on the five correction RPCs.
  `service_role` receives no raw correction-table capability.
