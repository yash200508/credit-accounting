create function app_private.post_interest_for_account_date(
  target_run_id uuid,
  target_credit_account_id uuid,
  target_business_date date
)
returns table (
  interest_accrual_id uuid,
  was_created boolean,
  posted_interest_paise bigint,
  ledger_transaction_id uuid,
  raw_interest_paise numeric(38, 18),
  closing_fractional_carry_paise numeric(38, 18)
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_run public.interest_accrual_runs%rowtype;
  target_account public.credit_accounts%rowtype;
  active_policy record;
  existing_accrual public.interest_accruals%rowtype;
  first_fuel_business_date date;
  previous_accrual record;
  expected_business_date date;
  calculated_eligible_principal_paise numeric := 0;
  calculated_raw_interest_paise numeric := 0;
  calculated_component_count integer := 0;
  calculated_daily_component_count integer := 0;
  calculated_retroactive_component_count integer := 0;
  calculated_opening_carry_paise numeric(38, 18) := 0;
  previous_cumulative_raw_paise numeric := 0;
  previous_cumulative_posted_paise numeric := 0;
  calculated_posted_interest_paise_numeric numeric;
  calculated_posted_interest_paise bigint;
  calculated_closing_carry_paise numeric(38, 18);
  calculated_cumulative_raw_paise numeric := 0;
  calculated_cumulative_posted_paise_numeric numeric := 0;
  calculated_cumulative_posted_paise bigint;
  new_interest_accrual_id uuid := gen_random_uuid();
  new_ledger_transaction_id uuid;
  posting_timestamp timestamptz := statement_timestamp();
begin
  if target_business_date is null then
    raise exception 'IAC_INVALID_DATE'
      using errcode = '22023';
  end if;

  select run.*
  into target_run
  from public.interest_accrual_runs as run
  where run.id = target_run_id
    and run.status = 'STARTED';

  if not found then
    raise exception 'IAC_RUN_NOT_FOUND_OR_FINAL'
      using errcode = 'P0001';
  end if;

  if target_business_date > target_run.latest_completed_business_date then
    raise exception 'IAC_BUSINESS_DATE_NOT_COMPLETED'
      using errcode = 'P0001';
  end if;

  select account.*
  into target_account
  from public.credit_accounts as account
  where account.id = target_credit_account_id
    and account.organization_id = target_run.organization_id
    and account.home_station_id = target_run.station_id
  for update;

  if not found then
    raise exception 'IAC_ACCOUNT_NOT_FOUND_OR_STATION_MISMATCH'
      using errcode = 'P0001';
  end if;

  select accrual.*
  into existing_accrual
  from public.interest_accruals as accrual
  where accrual.credit_account_id = target_credit_account_id
    and accrual.business_date = target_business_date
    and accrual.calculation_version = 1;

  if found then
    return query
    select
      existing_accrual.id,
      false,
      existing_accrual.posted_interest_paise,
      existing_accrual.ledger_transaction_id,
      existing_accrual.raw_interest_paise,
      existing_accrual.closing_fractional_carry_paise;
    return;
  end if;

  select min(transaction.business_date)
  into first_fuel_business_date
  from public.ledger_transactions as transaction
  where transaction.credit_account_id = target_credit_account_id
    and transaction.organization_id = target_run.organization_id
    and transaction.transaction_type = 'FUEL_CREDIT'
    and transaction.status = 'POSTED';

  if first_fuel_business_date is null then
    raise exception 'IAC_NO_PRINCIPAL_HISTORY'
      using errcode = 'P0001';
  end if;

  select
    accrual.business_date,
    accrual.closing_fractional_carry_paise,
    accrual.cumulative_raw_interest_paise,
    accrual.cumulative_posted_interest_paise
  into previous_accrual
  from public.interest_accruals as accrual
  where accrual.credit_account_id = target_credit_account_id
    and accrual.calculation_version = 1
    and accrual.business_date < target_business_date
  order by accrual.business_date desc
  limit 1;

  if found then
    expected_business_date := previous_accrual.business_date + 1;
    calculated_opening_carry_paise :=
      previous_accrual.closing_fractional_carry_paise;
    previous_cumulative_raw_paise :=
      previous_accrual.cumulative_raw_interest_paise;
    previous_cumulative_posted_paise :=
      previous_accrual.cumulative_posted_interest_paise;
  else
    expected_business_date := first_fuel_business_date;
  end if;

  if target_business_date <> expected_business_date then
    raise exception 'IAC_DATE_SEQUENCE'
      using
        errcode = 'P0001',
        detail = format(
          'Expected %s before %s.',
          expected_business_date,
          target_business_date
        );
  end if;

  select *
  into active_policy
  from app_private.resolve_effective_interest_policy(
    target_run.organization_id,
    target_account.customer_id,
    target_business_date
  );

  select
    coalesce(
      sum(component.source_remaining_principal_paise::numeric)
        filter (where component.component_kind = 'DAILY'),
      0
    ),
    coalesce(sum(component.raw_interest_paise), 0),
    count(*)::integer,
    count(*) filter (
      where component.component_kind = 'DAILY'
    )::integer,
    count(*) filter (
      where component.component_kind = 'RETROACTIVE_CATCH_UP'
    )::integer
  into
    calculated_eligible_principal_paise,
    calculated_raw_interest_paise,
    calculated_component_count,
    calculated_daily_component_count,
    calculated_retroactive_component_count
  from app_private.calculate_interest_components(
    target_credit_account_id,
    target_business_date
  ) as component;

  if calculated_eligible_principal_paise
       not between 0::numeric and 9223372036854775807::numeric
  then
    raise exception 'IAC_ELIGIBLE_PRINCIPAL_OVERFLOW'
      using errcode = '22003';
  end if;

  if calculated_raw_interest_paise < 0
     or calculated_raw_interest_paise >
       99999999999999999999.999999999999999999::numeric
  then
    raise exception 'IAC_RAW_INTEREST_OVERFLOW'
      using errcode = '22003';
  end if;

  calculated_cumulative_raw_paise :=
    previous_cumulative_raw_paise
      + calculated_raw_interest_paise;

  if calculated_cumulative_raw_paise < 0
     or calculated_cumulative_raw_paise >
       99999999999999999999.999999999999999999::numeric
  then
    raise exception 'IAC_CUMULATIVE_RAW_INTEREST_OVERFLOW'
      using errcode = '22003';
  end if;

  calculated_cumulative_posted_paise_numeric :=
    round(calculated_cumulative_raw_paise, 0);
  calculated_posted_interest_paise_numeric :=
    calculated_cumulative_posted_paise_numeric
      - previous_cumulative_posted_paise;

  if calculated_posted_interest_paise_numeric
       not between 0::numeric and 9223372036854775807::numeric
  then
    raise exception 'IAC_POSTED_INTEREST_OVERFLOW'
      using errcode = '22003';
  end if;

  calculated_posted_interest_paise :=
    calculated_posted_interest_paise_numeric::bigint;
  calculated_closing_carry_paise :=
    calculated_cumulative_raw_paise
      - calculated_cumulative_posted_paise_numeric;

  if calculated_cumulative_posted_paise_numeric
       not between 0::numeric and 9223372036854775807::numeric
  then
    raise exception 'IAC_CUMULATIVE_INTEREST_OVERFLOW'
      using errcode = '22003';
  end if;

  calculated_cumulative_posted_paise :=
    calculated_cumulative_posted_paise_numeric::bigint;

  if calculated_posted_interest_paise > 0 then
    new_ledger_transaction_id := gen_random_uuid();

    insert into public.ledger_transactions (
      id,
      organization_id,
      station_id,
      credit_account_id,
      customer_id,
      transaction_type,
      status,
      amount_paise,
      currency_code,
      occurred_at,
      business_date,
      created_by,
      created_at
    )
    values (
      new_ledger_transaction_id,
      target_run.organization_id,
      target_run.station_id,
      target_credit_account_id,
      target_account.customer_id,
      'INTEREST_CHARGE',
      'POSTED',
      calculated_posted_interest_paise,
      'INR',
      posting_timestamp,
      target_business_date,
      null,
      posting_timestamp
    );

    insert into public.ledger_entries (
      organization_id,
      transaction_id,
      account_code,
      direction,
      amount_paise,
      currency_code,
      created_at
    )
    values
      (
        target_run.organization_id,
        new_ledger_transaction_id,
        'CUSTOMER_INTEREST_RECEIVABLE',
        'DEBIT',
        calculated_posted_interest_paise,
        'INR',
        posting_timestamp
      ),
      (
        target_run.organization_id,
        new_ledger_transaction_id,
        'INTEREST_INCOME',
        'CREDIT',
        calculated_posted_interest_paise,
        'INR',
        posting_timestamp
      );
  end if;

  insert into public.interest_accruals (
    id,
    run_id,
    organization_id,
    station_id,
    credit_account_id,
    customer_id,
    business_date,
    active_policy_id,
    annual_rate,
    grace_days,
    grace_policy,
    interest_enabled,
    day_count_basis,
    eligible_principal_paise,
    raw_interest_paise,
    opening_fractional_carry_paise,
    posted_interest_paise,
    closing_fractional_carry_paise,
    cumulative_raw_interest_paise,
    cumulative_posted_interest_paise,
    component_count,
    daily_component_count,
    retroactive_component_count,
    ledger_transaction_id,
    calculation_version,
    currency_code,
    created_at
  )
  values (
    new_interest_accrual_id,
    target_run_id,
    target_run.organization_id,
    target_run.station_id,
    target_credit_account_id,
    target_account.customer_id,
    target_business_date,
    active_policy.policy_id,
    active_policy.annual_rate,
    active_policy.grace_days,
    active_policy.grace_policy,
    active_policy.interest_enabled,
    active_policy.day_count_basis,
    calculated_eligible_principal_paise::bigint,
    calculated_raw_interest_paise,
    calculated_opening_carry_paise,
    calculated_posted_interest_paise,
    calculated_closing_carry_paise,
    calculated_cumulative_raw_paise,
    calculated_cumulative_posted_paise,
    calculated_component_count,
    calculated_daily_component_count,
    calculated_retroactive_component_count,
    new_ledger_transaction_id,
    1,
    'INR',
    posting_timestamp
  );

  insert into public.interest_accrual_components (
    interest_accrual_id,
    organization_id,
    station_id,
    credit_account_id,
    customer_id,
    source_transaction_id,
    source_business_date,
    eligibility_business_date,
    interest_business_date,
    accrual_business_date,
    component_kind,
    source_remaining_principal_paise,
    raw_interest_paise,
    source_policy_id,
    rate_policy_id,
    annual_rate,
    grace_days,
    grace_policy,
    interest_enabled,
    day_count_basis,
    calculation_version,
    created_at
  )
  select
    new_interest_accrual_id,
    component.organization_id,
    component.station_id,
    target_credit_account_id,
    component.customer_id,
    component.source_transaction_id,
    component.source_business_date,
    component.eligibility_business_date,
    component.interest_business_date,
    component.accrual_business_date,
    component.component_kind,
    component.source_remaining_principal_paise,
    component.raw_interest_paise,
    component.source_policy_id,
    component.rate_policy_id,
    component.annual_rate,
    component.grace_days,
    component.grace_policy,
    component.interest_enabled,
    component.day_count_basis,
    1,
    posting_timestamp
  from app_private.calculate_interest_components(
    target_credit_account_id,
    target_business_date
  ) as component;

  if calculated_posted_interest_paise > 0 then
    insert into public.audit_events (
      actor_user_id,
      actor_role,
      organization_id,
      station_id,
      action_category,
      action,
      entity_type,
      entity_id,
      reason,
      before_state,
      after_state,
      request_id,
      source_application,
      occurred_at
    )
    values (
      null,
      null,
      target_run.organization_id,
      target_run.station_id,
      'FINANCIAL',
      'interest.accrued',
      'interest_accrual',
      new_interest_accrual_id,
      'Trusted daily simple-interest accrual',
      null,
      jsonb_build_object(
        'business_date', target_business_date,
        'credit_account_id', target_credit_account_id,
        'customer_id', target_account.customer_id,
        'eligible_principal_paise',
          calculated_eligible_principal_paise::bigint,
        'annual_rate', active_policy.annual_rate::text,
        'grace_days', active_policy.grace_days,
        'grace_policy', active_policy.grace_policy,
        'interest_enabled', active_policy.interest_enabled,
        'raw_interest_paise',
          calculated_raw_interest_paise::text,
        'posted_interest_paise',
          calculated_posted_interest_paise,
        'ledger_transaction_id',
          new_ledger_transaction_id,
        'interest_accrual_run_id', target_run_id,
        'trigger_source', target_run.trigger_source,
        'correlation_request_id', target_run.request_id,
        'calculation_version', 1
      ),
      target_run.request_id,
      'postgres-interest-accrual',
      posting_timestamp
    );
  end if;

  return query
  select
    new_interest_accrual_id,
    true,
    calculated_posted_interest_paise,
    new_ledger_transaction_id,
    calculated_raw_interest_paise,
    calculated_closing_carry_paise;
end;
$$;

create function app_private.assert_interest_accrual_ledger_link()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_transaction public.ledger_transactions%rowtype;
  target_accrual public.interest_accruals%rowtype;
begin
  if tg_table_name = 'ledger_transactions' then
    target_transaction := new;

    if target_transaction.transaction_type <> 'INTEREST_CHARGE'
       or target_transaction.created_by is not null
    then
      return null;
    end if;

    select accrual.*
    into target_accrual
    from public.interest_accruals as accrual
    where accrual.ledger_transaction_id = target_transaction.id;

    if not found then
      raise exception 'IAC_LEDGER_DETAIL_REQUIRED'
        using errcode = '23514';
    end if;
  else
    target_accrual := new;

    if target_accrual.posted_interest_paise = 0 then
      return null;
    end if;

    select transaction.*
    into target_transaction
    from public.ledger_transactions as transaction
    where transaction.id = target_accrual.ledger_transaction_id;

    if not found then
      raise exception 'IAC_LEDGER_DETAIL_REQUIRED'
        using errcode = '23514';
    end if;
  end if;

  if target_transaction.organization_id
       is distinct from target_accrual.organization_id
     or target_transaction.station_id
       is distinct from target_accrual.station_id
     or target_transaction.credit_account_id
       is distinct from target_accrual.credit_account_id
     or target_transaction.customer_id
       is distinct from target_accrual.customer_id
     or target_transaction.transaction_type
       is distinct from 'INTEREST_CHARGE'
     or target_transaction.status is distinct from 'POSTED'
     or target_transaction.amount_paise
       is distinct from target_accrual.posted_interest_paise
     or target_transaction.currency_code
       is distinct from target_accrual.currency_code
     or target_transaction.business_date
       is distinct from target_accrual.business_date
     or target_transaction.created_by is not null
  then
    raise exception 'IAC_LEDGER_DETAIL_MISMATCH'
      using errcode = '23514';
  end if;

  return null;
end;
$$;

create constraint trigger system_interest_requires_accrual_detail
after insert on public.ledger_transactions
deferrable initially deferred
for each row execute function
  app_private.assert_interest_accrual_ledger_link();

create constraint trigger posted_accrual_requires_matching_interest_ledger
after insert on public.interest_accruals
deferrable initially deferred
for each row execute function
  app_private.assert_interest_accrual_ledger_link();

comment on function
  app_private.post_interest_for_account_date(uuid, uuid, date) is
  'Trusted, account-locked, idempotent daily interest posting. Uses exact NUMERIC carry and creates ledger/audit rows only for positive whole-paise postings.';

revoke all on function
  app_private.post_interest_for_account_date(uuid, uuid, date)
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_interest_accrual_ledger_link()
  from public, anon, authenticated, service_role;
