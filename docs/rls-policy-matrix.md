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

## Privileged helpers

Helpers live in `app_private`, set an empty `search_path`, obtain the actor from `(select auth.uid())`, and use `SECURITY DEFINER` only to read RLS-protected authorization rows without recursive policy evaluation. Their owner retains no application login. `PUBLIC` and `anon` execution are revoked.

Data-returning privileged functions are deliberately narrow:

- `get_my_driver_parent_account()` returns the existing driver projection.
- `get_credit_account_balance(account_id)` returns an authorized account's
  limit, principal, and available credit.
- `create_customer_with_credit_account(...)` returns identifiers and safe
  account configuration after an atomic create.
- `post_fuel_credit_transaction(...)` returns the original or newly committed
  safe receipt.

Only the latter two mutate data. `PUBLIC` and `anon` execution are revoked.

## Policy rules

- No protected-table policy contains an unrestricted `USING (true)` or `WITH CHECK (true)`.
- Revoked membership, inactive organization/station, inactive customer, or revoked driver status removes applicable access.
- Composite tenant/station foreign keys prevent spoofed cross-organization relationships independently of RLS.
- Direct client writes to role, membership, customer, account, product, ledger,
  sale, idempotency, driver, QR, interest, and audit tables are denied.
- Posted transaction, entry, and sale updates/deletes are also rejected by
  triggers; RLS and grants are not the only immutability boundary.
