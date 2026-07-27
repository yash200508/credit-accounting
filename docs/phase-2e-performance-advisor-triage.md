# Phase 2E Performance Advisor Triage

## Scope and decision rule

The hosted Free/Nano development project reported 62
`unindexed_foreign_keys` findings after the first 24 migrations. The project
was empty, so the findings contain no production cardinality, selectivity, or
query-plan evidence. This review does not add indexes to the privilege
hardening migration.

Catalog review confirmed that every flagged foreign key already has a valid
index whose first key is the foreign key's first referencing column. Those
first columns are UUID identity or scope columns and are the columns used by
the current transaction, RLS, scheduler, and correction paths. The advisor is
correct that these are not full covering indexes for every column in each
composite foreign key, but a second composite index is not automatically an
improvement: it adds write amplification and Free/Nano storage pressure and
may duplicate a selective existing access path.

The classifications below use:

- **Add before production:** proven necessary from a realistic plan or parent
  update/delete workload; none is proven yet.
- **Prefix-indexed:** already adequately left-prefix-indexed for the current
  implemented and tested workload.
- **Needs evidence:** retain as a review gate if realistic staging plans show
  excessive scanning.
- **Not actionable:** no safe action can be inferred from a fresh empty
  project.

## Individual foreign-key findings

| # | Advisor finding | Existing valid left-prefix index | Classification |
|---:|---|---|---|
| 1 | `app_settings_station_tenant_fk` | `app_settings_station_id_idx` | Prefix-indexed |
| 2 | `audit_events_station_tenant_fk` | `audit_events_station_occurred_at_idx` | Prefix-indexed |
| 3 | `credit_accounts_customer_tenant_fk` | `credit_accounts_customer_unique` | Prefix-indexed |
| 4 | `credit_accounts_home_station_tenant_fk` | `credit_accounts_home_station_id_idx` | Prefix-indexed |
| 5 | `customer_drivers_customer_tenant_fk` | `customer_drivers_customer_id_idx` | Prefix-indexed |
| 6 | `customer_repayments_account_customer_tenant_fk` | `customer_repayments_account_created_idx` | Prefix-indexed |
| 7 | `customer_repayments_driver_customer_tenant_fk` | `customer_repayments_driver_idx` | Prefix-indexed |
| 8 | `customer_repayments_idempotency_tenant_fk` | `customer_repayments_idempotency_unique` | Prefix-indexed |
| 9 | `customer_repayments_station_tenant_fk` | `customer_repayments_station_created_idx` | Prefix-indexed |
| 10 | `customer_repayments_transaction_identity_fk` | `customer_repayments_transaction_unique` | Prefix-indexed |
| 11 | `customers_home_station_tenant_fk` | `customers_home_station_id_idx` | Prefix-indexed |
| 12 | `driver_permissions_driver_customer_tenant_fk` | `driver_permissions_pkey` | Prefix-indexed |
| 13 | `financial_correction_events_request_tenant_fk` | `financial_correction_events_request_time_idx` | Prefix-indexed |
| 14 | `financial_correction_requests_account_tenant_fk` | `financial_correction_requests_account_idx` | Prefix-indexed |
| 15 | `financial_correction_requests_original_identity_fk` | `financial_correction_requests_one_pending_original_idx` | Prefix-indexed |
| 16 | `financial_correction_requests_replacement_tenant_fk` | `financial_correction_requests_replacement_idx` | Prefix-indexed |
| 17 | `financial_correction_requests_reversal_tenant_fk` | `financial_correction_requests_reversal_idx` | Prefix-indexed |
| 18 | `financial_correction_requests_station_tenant_fk` | `financial_correction_requests_station_status_idx` | Prefix-indexed |
| 19 | `financial_reversals_account_tenant_fk` | `financial_reversals_account_date_idx` | Prefix-indexed |
| 20 | `financial_reversals_original_identity_fk` | `financial_reversals_original_unique` | Prefix-indexed |
| 21 | `financial_reversals_replacement_tenant_fk` | `financial_reversals_replacement_unique` | Prefix-indexed |
| 22 | `financial_reversals_request_tenant_fk` | `financial_reversals_request_unique` | Prefix-indexed |
| 23 | `financial_reversals_reversal_identity_fk` | `financial_reversals_reversal_unique` | Prefix-indexed |
| 24 | `financial_reversals_station_tenant_fk` | `financial_reversals_station_idx` | Prefix-indexed |
| 25 | `fuel_credit_correction_proposals_account_tenant_fk` | `fuel_credit_correction_proposals_account_idx` | Prefix-indexed |
| 26 | `fuel_credit_correction_proposals_product_tenant_fk` | `fuel_credit_correction_proposals_product_idx` | Prefix-indexed |
| 27 | `fuel_credit_correction_proposals_request_tenant_fk` | `fuel_credit_correction_proposals_pkey` | Prefix-indexed |
| 28 | `fuel_credit_correction_proposals_station_tenant_fk` | `fuel_credit_correction_proposals_station_idx` | Prefix-indexed |
| 29 | `fuel_credit_sales_product_tenant_fk` | `fuel_credit_sales_product_created_idx` | Prefix-indexed |
| 30 | `fuel_credit_sales_transaction_identity_fk` | `fuel_credit_sales_transaction_unique` | Prefix-indexed |
| 31 | `fuel_products_station_tenant_fk` | `fuel_products_station_active_idx` | Prefix-indexed |
| 32 | `idempotency_keys_account_tenant_fk` | `idempotency_keys_account_idx` | Prefix-indexed |
| 33 | `idempotency_keys_product_tenant_fk` | `idempotency_keys_product_idx` | Prefix-indexed |
| 34 | `idempotency_keys_response_repayment_tenant_fk` | `idempotency_keys_response_repayment_idx` | Prefix-indexed |
| 35 | `idempotency_keys_sale_tenant_fk` | `idempotency_keys_response_sale_idx` | Prefix-indexed |
| 36 | `idempotency_keys_station_tenant_fk` | `idempotency_keys_station_idx` | Prefix-indexed |
| 37 | `idempotency_keys_transaction_tenant_fk` | `idempotency_keys_response_transaction_idx` | Prefix-indexed |
| 38 | `interest_accrual_components_account_customer_tenant_fk` | `interest_accrual_components_account_interest_date_idx` | Prefix-indexed |
| 39 | `interest_accrual_components_accrual_tenant_fk` | `interest_accrual_components_accrual_idx` | Prefix-indexed |
| 40 | `interest_accrual_components_rate_policy_tenant_fk` | `interest_accrual_components_rate_policy_idx` | Prefix-indexed |
| 41 | `interest_accrual_components_source_policy_tenant_fk` | `interest_accrual_components_source_policy_idx` | Prefix-indexed |
| 42 | `interest_accrual_components_source_transaction_tenant_fk` | `interest_accrual_components_source_transaction_idx` | Prefix-indexed |
| 43 | `interest_accrual_components_station_tenant_fk` | `interest_accrual_components_station_idx` | Prefix-indexed |
| 44 | `interest_accrual_runs_station_tenant_fk` | `interest_accrual_runs_station_requested_idx` | Prefix-indexed |
| 45 | `interest_accruals_account_customer_tenant_fk` | `interest_accruals_account_date_version_unique` | Prefix-indexed |
| 46 | `interest_accruals_ledger_transaction_tenant_fk` | `interest_accruals_ledger_transaction_idx` | Prefix-indexed |
| 47 | `interest_accruals_policy_tenant_fk` | `interest_accruals_active_policy_idx` | Prefix-indexed |
| 48 | `interest_accruals_run_tenant_fk` | `interest_accruals_run_idx` | Prefix-indexed |
| 49 | `interest_accruals_station_tenant_fk` | `interest_accruals_station_business_date_idx` | Prefix-indexed |
| 50 | `interest_policies_customer_tenant_fk` | `interest_policies_customer_id_idx` | Prefix-indexed |
| 51 | `ledger_entries_transaction_tenant_currency_fk` | `ledger_entries_transaction_idx` | Prefix-indexed |
| 52 | `ledger_transactions_account_customer_tenant_fk` | `ledger_transactions_account_business_date_idx` | Prefix-indexed |
| 53 | `ledger_transactions_station_tenant_fk` | `ledger_transactions_station_business_date_idx` | Prefix-indexed |
| 54 | `qr_credentials_customer_tenant_fk` | `qr_credentials_customer_id_idx` | Prefix-indexed |
| 55 | `qr_credentials_driver_tenant_fk` | `qr_credentials_driver_id_idx` | Prefix-indexed |
| 56 | `repayment_allocations_repayment_account_tenant_fk` | `repayment_allocations_component_unique` | Prefix-indexed |
| 57 | `repayment_correction_proposals_account_tenant_fk` | `repayment_correction_proposals_account_idx` | Prefix-indexed |
| 58 | `repayment_correction_proposals_driver_tenant_fk` | `repayment_correction_proposals_driver_idx` | Prefix-indexed |
| 59 | `repayment_correction_proposals_request_tenant_fk` | `repayment_correction_proposals_pkey` | Prefix-indexed |
| 60 | `repayment_correction_proposals_station_tenant_fk` | `repayment_correction_proposals_station_idx` | Prefix-indexed |
| 61 | `role_assignments_station_tenant_fk` | `role_assignments_station_user_role_idx` | Prefix-indexed |
| 62 | `station_memberships_station_tenant_fk` | `station_memberships_station_user_unique` | Prefix-indexed |

Classification totals for the 62 foreign-key findings are: 0 add before
production, 62 already prefix-indexed for the current workload, 0 currently
requiring an additional index, and 0 otherwise not actionable. This is a
current-workload disposition, not permission to skip pre-production plan
review.

## Production evidence gate

Before production, capture `EXPLAIN (ANALYZE, BUFFERS)` on realistic synthetic
volumes for parent-key update/delete checks and the main station, account,
transaction, scheduler, and correction queries. Move an item to **Add before
production** only when a plan shows material scanning that a full composite
index removes. Any new index must be a separate reviewed migration, measured
for write cost and redundant-prefix overlap.

The advisor also reported 115 `unused_index` findings. They are **Not currently
actionable** because an empty, newly migrated project has no representative
usage statistics. No index is removed on that evidence. Revisit only after a
representative workload, a statistics collection window, dependency review,
and rollback plan.

This triage is documentation only. It has not changed the hosted project.
