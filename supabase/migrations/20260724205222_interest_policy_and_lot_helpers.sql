create function app_private.resolve_effective_interest_policy(
  target_organization_id uuid,
  target_customer_id uuid,
  target_business_date date
)
returns table (
  policy_id uuid,
  annual_rate numeric(9, 8),
  grace_days integer,
  grace_policy public.interest_grace_policy_type,
  interest_enabled boolean,
  day_count_basis smallint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query
  select
    policy.id,
    policy.annual_rate,
    policy.grace_days,
    policy.grace_policy,
    policy.interest_enabled,
    policy.day_count_basis
  from public.interest_policies as policy
  where policy.organization_id = target_organization_id
    and (
      policy.customer_id = target_customer_id
      or policy.customer_id is null
    )
    and policy.is_active
    and policy.effective_from <= target_business_date
    and (
      policy.effective_to is null
      or policy.effective_to > target_business_date
    )
  order by
    (policy.customer_id is not null) desc,
    policy.effective_from desc,
    policy.id
  limit 1;

  if not found then
    raise exception 'IAC_POLICY_NOT_FOUND'
      using
        errcode = 'P0001',
        detail = 'No effective organization default or customer override.';
  end if;
end;
$$;

create function app_private.principal_lots_as_of(
  target_credit_account_id uuid,
  target_business_date date
)
returns table (
  organization_id uuid,
  station_id uuid,
  customer_id uuid,
  source_transaction_id uuid,
  source_business_date date,
  source_occurred_at timestamptz,
  source_principal_paise bigint,
  source_remaining_principal_paise bigint,
  source_policy_id uuid,
  grace_days integer,
  grace_policy public.interest_grace_policy_type,
  eligibility_business_date date
)
language sql
stable
security definer
set search_path = ''
as $$
  with account_scope as (
    select
      account.id,
      account.organization_id,
      account.home_station_id as station_id,
      account.customer_id
    from public.credit_accounts as account
    where account.id = target_credit_account_id
  ),
  fuel_lots as (
    select
      account.organization_id,
      account.station_id,
      account.customer_id,
      transaction.id as source_transaction_id,
      transaction.business_date as source_business_date,
      transaction.occurred_at as source_occurred_at,
      transaction.amount_paise as source_principal_paise,
      coalesce(
        sum(transaction.amount_paise::numeric) over (
          order by
            transaction.business_date,
            transaction.occurred_at,
            transaction.id
          rows between unbounded preceding and 1 preceding
        ),
        0::numeric
      ) as prior_principal_paise
    from account_scope as account
    join public.ledger_transactions as transaction
      on transaction.credit_account_id = account.id
     and transaction.organization_id = account.organization_id
     and transaction.transaction_type = 'FUEL_CREDIT'
     and transaction.status = 'POSTED'
     and transaction.business_date <= target_business_date
  ),
  principal_repaid as (
    select coalesce(sum(entry.amount_paise::numeric), 0) as amount_paise
    from account_scope as account
    join public.ledger_transactions as transaction
      on transaction.credit_account_id = account.id
     and transaction.organization_id = account.organization_id
     and transaction.status = 'POSTED'
     and transaction.business_date <= target_business_date
    join public.ledger_entries as entry
      on entry.transaction_id = transaction.id
     and entry.organization_id = transaction.organization_id
     and entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
     and entry.direction = 'CREDIT'
  )
  select
    lot.organization_id,
    lot.station_id,
    lot.customer_id,
    lot.source_transaction_id,
    lot.source_business_date,
    lot.source_occurred_at,
    lot.source_principal_paise,
    greatest(
      0::numeric,
      lot.source_principal_paise::numeric
        - greatest(
          0::numeric,
          repayment.amount_paise - lot.prior_principal_paise
        )
    )::bigint as source_remaining_principal_paise,
    source_policy.policy_id,
    source_policy.grace_days,
    source_policy.grace_policy,
    lot.source_business_date
      + source_policy.grace_days as eligibility_business_date
  from fuel_lots as lot
  cross join principal_repaid as repayment
  cross join lateral app_private.resolve_effective_interest_policy(
    lot.organization_id,
    lot.customer_id,
    lot.source_business_date
  ) as source_policy
  order by
    lot.source_business_date,
    lot.source_occurred_at,
    lot.source_transaction_id;
$$;

create function app_private.calculate_interest_components(
  target_credit_account_id uuid,
  target_accrual_business_date date
)
returns table (
  organization_id uuid,
  station_id uuid,
  customer_id uuid,
  source_transaction_id uuid,
  source_business_date date,
  eligibility_business_date date,
  interest_business_date date,
  accrual_business_date date,
  component_kind public.interest_accrual_component_kind,
  source_remaining_principal_paise bigint,
  raw_interest_paise numeric(38, 18),
  source_policy_id uuid,
  rate_policy_id uuid,
  annual_rate numeric(9, 8),
  grace_days integer,
  grace_policy public.interest_grace_policy_type,
  interest_enabled boolean,
  day_count_basis smallint
)
language sql
stable
security definer
set search_path = ''
as $$
  with target_lots as (
    select *
    from app_private.principal_lots_as_of(
      target_credit_account_id,
      target_accrual_business_date
    )
  ),
  source_lots as (
    select
      lot.*,
      coalesce(
        sum(lot.source_principal_paise::numeric) over (
          order by
            lot.source_business_date,
            lot.source_occurred_at,
            lot.source_transaction_id
          rows between unbounded preceding and 1 preceding
        ),
        0::numeric
      ) as prior_principal_paise
    from target_lots as lot
  ),
  repayment_by_date as (
    select
      transaction.business_date,
      sum(entry.amount_paise::numeric) as repaid_principal_paise
    from public.ledger_transactions as transaction
    join public.ledger_entries as entry
      on entry.transaction_id = transaction.id
     and entry.organization_id = transaction.organization_id
     and entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
     and entry.direction = 'CREDIT'
    where transaction.credit_account_id = target_credit_account_id
      and transaction.status = 'POSTED'
      and transaction.business_date <= target_accrual_business_date
    group by transaction.business_date
  ),
  repayment_cumulative as (
    select
      repayment.business_date,
      sum(repayment.repaid_principal_paise) over (
        order by repayment.business_date
        rows between unbounded preceding and current row
      ) as repaid_principal_paise
    from repayment_by_date as repayment
  ),
  daily_components as (
    select
      lot.organization_id,
      lot.station_id,
      lot.customer_id,
      lot.source_transaction_id,
      lot.source_business_date,
      lot.eligibility_business_date,
      target_accrual_business_date as interest_business_date,
      target_accrual_business_date as accrual_business_date,
      'DAILY'::public.interest_accrual_component_kind
        as component_kind,
      lot.source_remaining_principal_paise,
      lot.source_policy_id,
      lot.grace_days,
      lot.grace_policy
    from source_lots as lot
    where lot.source_remaining_principal_paise > 0
      and target_accrual_business_date
        >= lot.eligibility_business_date
  ),
  retroactive_dates as (
    select
      threshold_lot.organization_id,
      threshold_lot.station_id,
      threshold_lot.customer_id,
      threshold_lot.source_transaction_id,
      threshold_lot.source_business_date,
      threshold_lot.eligibility_business_date,
      generated_date::date as interest_business_date,
      target_accrual_business_date as accrual_business_date,
      'RETROACTIVE_CATCH_UP'
        ::public.interest_accrual_component_kind as component_kind,
      threshold_lot.source_policy_id,
      threshold_lot.grace_days,
      threshold_lot.grace_policy,
      threshold_lot.source_principal_paise,
      threshold_lot.prior_principal_paise
    from source_lots as threshold_lot
    cross join lateral generate_series(
      threshold_lot.source_business_date::timestamp,
      (
        threshold_lot.eligibility_business_date - 1
      )::timestamp,
      interval '1 day'
    ) as generated_date
    where threshold_lot.source_remaining_principal_paise > 0
      and threshold_lot.grace_policy = 'RETROACTIVE_AFTER_GRACE'
      and target_accrual_business_date
        = threshold_lot.eligibility_business_date
  ),
  retroactive_components as (
    select
      retroactive.organization_id,
      retroactive.station_id,
      retroactive.customer_id,
      retroactive.source_transaction_id,
      retroactive.source_business_date,
      retroactive.eligibility_business_date,
      retroactive.interest_business_date,
      retroactive.accrual_business_date,
      retroactive.component_kind,
      calculated_lot.source_remaining_principal_paise,
      retroactive.source_policy_id,
      retroactive.grace_days,
      retroactive.grace_policy
    from retroactive_dates as retroactive
    left join lateral (
      select repayment.repaid_principal_paise
      from repayment_cumulative as repayment
      where repayment.business_date
        <= retroactive.interest_business_date
      order by repayment.business_date desc
      limit 1
    ) as repayment_at_date on true
    cross join lateral (
      select greatest(
        0::numeric,
        retroactive.source_principal_paise::numeric
          - greatest(
            0::numeric,
            coalesce(
              repayment_at_date.repaid_principal_paise,
              0::numeric
            ) - retroactive.prior_principal_paise
          )
      )::bigint as source_remaining_principal_paise
    ) as calculated_lot
    where calculated_lot.source_remaining_principal_paise > 0
  ),
  unpriced_components as (
    select * from daily_components
    union all
    select * from retroactive_components
  )
  select
    component.organization_id,
    component.station_id,
    component.customer_id,
    component.source_transaction_id,
    component.source_business_date,
    component.eligibility_business_date,
    component.interest_business_date,
    component.accrual_business_date,
    component.component_kind,
    component.source_remaining_principal_paise,
    (
      case
        when rate_policy.interest_enabled
          then (
            component.source_remaining_principal_paise::numeric(38, 18)
            * rate_policy.annual_rate::numeric(38, 18)
            / rate_policy.day_count_basis::numeric(38, 18)
          )
        else 0::numeric
      end
    )::numeric(38, 18) as raw_interest_paise,
    component.source_policy_id,
    rate_policy.policy_id as rate_policy_id,
    rate_policy.annual_rate,
    component.grace_days,
    component.grace_policy,
    rate_policy.interest_enabled,
    rate_policy.day_count_basis
  from unpriced_components as component
  cross join lateral app_private.resolve_effective_interest_policy(
    component.organization_id,
    component.customer_id,
    component.interest_business_date
  ) as rate_policy
  order by
    component.interest_business_date,
    component.source_business_date,
    component.source_transaction_id,
    component.component_kind;
$$;

comment on function
  app_private.resolve_effective_interest_policy(uuid, uuid, date) is
  'Resolves the effective customer override first, then the organization default; raises if neither exists.';
comment on function
  app_private.principal_lots_as_of(uuid, date) is
  'Derives station-local closing principal lots with deterministic FIFO repayment allocation and source-date grace snapshots.';
comment on function
  app_private.calculate_interest_components(uuid, date) is
  'Produces exact NUMERIC Actual/365 simple-interest components; interest ledger balances never become principal lots.';

revoke all on function
  app_private.resolve_effective_interest_policy(uuid, uuid, date)
  from public, anon, authenticated, service_role;
revoke all on function app_private.principal_lots_as_of(uuid, date)
  from public, anon, authenticated, service_role;
revoke all on function
  app_private.calculate_interest_components(uuid, date)
  from public, anon, authenticated, service_role;
