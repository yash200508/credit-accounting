-- Read-only hosted Phase 2E functional-smoke reconciliation.
-- Values are synthetic counts only; no credential or customer data is emitted.
with metrics(metric, value) as (
  select 'auth_users_total', count(*)::bigint
  from auth.users
  union all
  select 'auth_users_unexpected', count(*)::bigint
  from auth.users
  where email not like '%@credit-accounting.example.test'
     or coalesce(raw_app_meta_data ->> 'environment', '') <> 'DEVELOPMENT'
     or coalesce((raw_app_meta_data ->> 'fake_data')::boolean, false) is not true
  union all
  select 'organizations', count(*)::bigint from public.organizations
  union all
  select 'stations', count(*)::bigint from public.stations
  union all
  select 'customers', count(*)::bigint from public.customers
  union all
  select 'credit_accounts', count(*)::bigint from public.credit_accounts
  union all
  select 'fuel_credit_sales', count(*)::bigint from public.fuel_credit_sales
  union all
  select 'customer_repayments', count(*)::bigint from public.customer_repayments
  union all
  select 'repayment_allocations', count(*)::bigint from public.repayment_allocations
  union all
  select 'interest_accrual_runs', count(*)::bigint from public.interest_accrual_runs
  union all
  select 'interest_accruals', count(*)::bigint from public.interest_accruals
  union all
  select 'interest_accrual_components', count(*)::bigint
  from public.interest_accrual_components
  union all
  select 'ledger_transactions', count(*)::bigint from public.ledger_transactions
  union all
  select 'ledger_entries', count(*)::bigint from public.ledger_entries
  union all
  select 'idempotency_keys', count(*)::bigint from public.idempotency_keys
  union all
  select 'financial_correction_requests', count(*)::bigint
  from public.financial_correction_requests
  union all
  select 'financial_correction_events', count(*)::bigint
  from public.financial_correction_events
  union all
  select 'financial_reversals', count(*)::bigint from public.financial_reversals
  union all
  select 'audit_events', count(*)::bigint from public.audit_events
  union all
  select 'unexpected_customer_markers', count(*)::bigint
  from public.customers
  where display_name not like 'DEVELOPMENT %'
     or (
       phone not like 'fake-%'
       and phone not like '+999%'
     )
  union all
  select 'unexpected_organization_markers', count(*)::bigint
  from public.organizations
  where legal_name not like 'DEVELOPMENT %NOT REAL DATA'
  union all
  select 'unbalanced_ledger_transactions', count(*)::bigint
  from (
    select transaction.id
    from public.ledger_transactions as transaction
    left join public.ledger_entries as entry
      on entry.transaction_id = transaction.id
    group by transaction.id
    having count(entry.id) <> 2
       or coalesce(sum(entry.amount_paise)
          filter (where entry.direction = 'DEBIT'), 0)
          <> coalesce(sum(entry.amount_paise)
             filter (where entry.direction = 'CREDIT'), 0)
  ) as imbalance
  union all
  select 'incomplete_idempotency_keys', count(*)::bigint
  from public.idempotency_keys
  where status <> 'COMPLETED'
  union all
  select 'failed_interest_runs', count(*)::bigint
  from public.interest_accrual_runs
  where status = 'FAILED'
  union all
  select 'isolation_financial_transactions', count(*)::bigint
  from public.ledger_transactions
  where organization_id = 'e0000000-0000-0000-0000-000000000002'
  union all
  select 'cron_jobs', count(*)::bigint
  from cron.job
  union all
  select 'unexpected_cron_jobs', count(*)::bigint
  from cron.job
  where jobname <> 'credit-accounting-hourly-interest-accrual'
     or schedule <> '7 * * * *'
     or command <> 'select app_private.run_hourly_interest_accrual();'
     or username <> 'postgres'
     or active is not true
),
metric_summary as (
  select jsonb_object_agg(metric, value order by metric) as values
  from metrics
),
correction_summary as (
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'requester_role', grouped.requester_role,
        'status', grouped.status,
        'request_count', grouped.request_count
      )
      order by grouped.requester_role, grouped.status
    ),
    '[]'::jsonb
  ) as values
  from (
    select
      request.requester_role,
      request.status,
      count(*) as request_count
    from public.financial_correction_requests as request
    group by request.requester_role, request.status
  ) as grouped
),
interest_run_summary as (
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'trigger_source', grouped.trigger_source,
        'status', grouped.status,
        'run_count', grouped.run_count,
        'interest_posted_paise', grouped.interest_posted_paise
      )
      order by grouped.trigger_source, grouped.status
    ),
    '[]'::jsonb
  ) as values
  from (
    select
      run.trigger_source,
      run.status,
      count(*) as run_count,
      sum(run.interest_posted_paise) as interest_posted_paise
    from public.interest_accrual_runs as run
    group by run.trigger_source, run.status
  ) as grouped
),
owner_smoke_summary as (
  select jsonb_build_object(
    'synthetic_owner_smoke_accounts', count(*),
    'interrupted_accounts_with_interest_due',
      count(*) filter (where obligation.outstanding_interest_paise > 0),
    'synthetic_outstanding_principal_paise',
      sum(obligation.outstanding_principal_paise),
    'synthetic_outstanding_interest_paise',
      sum(obligation.outstanding_interest_paise)
  ) as values
  from public.credit_accounts as account
  join public.customers as customer
    on customer.id = account.customer_id
  cross join lateral app_private.calculate_credit_account_obligations(
    account.id
  ) as obligation
  where customer.display_name like 'DEVELOPMENT OWNER % - NOT REAL'
)
select
  metric_summary.values as metrics,
  correction_summary.values as correction_requests,
  interest_run_summary.values as interest_runs,
  owner_smoke_summary.values as owner_smoke_accounts
from metric_summary
cross join correction_summary
cross join interest_run_summary
cross join owner_smoke_summary;
