begin;

create extension if not exists pgtap with schema extensions;

select * from no_plan();

-- Schema, append-only evidence, and private execution boundary.
select has_table(
  'public',
  'interest_accrual_runs',
  'interest accrual runs exist'
);
select has_table(
  'public',
  'interest_accruals',
  'daily interest accrual evidence exists'
);
select has_table(
  'public',
  'interest_accrual_components',
  'principal-lot source evidence exists'
);
select has_column(
  'public',
  'stations',
  'time_zone_name',
  'stations store an IANA time zone'
);
select has_column(
  'public',
  'ledger_transactions',
  'business_date',
  'ledger transactions persist a business date'
);
select has_column(
  'public',
  'interest_policies',
  'interest_enabled',
  'effective policies can disable interest'
);
select has_column(
  'public',
  'interest_policies',
  'day_count_basis',
  'effective policies snapshot the day-count basis'
);
select has_column(
  'public',
  'interest_accruals',
  'closing_fractional_carry_paise',
  'accrual evidence preserves fractional-paise carry'
);
select has_column(
  'public',
  'interest_accruals',
  'annual_rate',
  'accrual evidence snapshots the applied rate'
);
select has_column(
  'public',
  'interest_accruals',
  'grace_policy',
  'accrual evidence snapshots the grace policy'
);
select has_column(
  'public',
  'interest_accruals',
  'interest_enabled',
  'accrual evidence snapshots the enabled state'
);

select ok(
  (
    select relation.relrowsecurity and relation.relforcerowsecurity
    from pg_class as relation
    join pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relname = 'interest_accrual_runs'
  ),
  'run evidence has enabled and forced RLS'
);
select ok(
  (
    select relation.relrowsecurity and relation.relforcerowsecurity
    from pg_class as relation
    join pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relname = 'interest_accruals'
  ),
  'daily evidence has enabled and forced RLS'
);
select ok(
  (
    select relation.relrowsecurity and relation.relforcerowsecurity
    from pg_class as relation
    join pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relname = 'interest_accrual_components'
  ),
  'component evidence has enabled and forced RLS'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.interest_accrual_runs',
    'insert'
  )
  and not has_table_privilege(
    'authenticated',
    'public.interest_accrual_runs',
    'update'
  )
  and not has_table_privilege(
    'authenticated',
    'public.interest_accrual_runs',
    'delete'
  ),
  'authenticated clients cannot mutate run evidence'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'public.interest_accruals',
    'insert'
  )
  and not has_table_privilege(
    'authenticated',
    'public.interest_accruals',
    'update'
  )
  and not has_table_privilege(
    'authenticated',
    'public.interest_accruals',
    'delete'
  ),
  'authenticated clients cannot mutate daily evidence'
);
select ok(
  not has_table_privilege(
    'authenticated',
    'public.interest_accrual_components',
    'insert'
  )
  and not has_table_privilege(
    'authenticated',
    'public.interest_accrual_components',
    'update'
  )
  and not has_table_privilege(
    'authenticated',
    'public.interest_accrual_components',
    'delete'
  ),
  'authenticated clients cannot mutate component evidence'
);
select ok(
  not has_table_privilege(
    'service_role',
    'public.interest_accrual_runs',
    'select'
  )
  and not has_table_privilege(
    'service_role',
    'public.interest_accruals',
    'select'
  )
  and not has_table_privilege(
    'service_role',
    'public.interest_accrual_components',
    'select'
  ),
  'service_role has no raw accrual-evidence bypass'
);

select has_function(
  'app_private',
  'resolve_effective_interest_policy',
  array['uuid', 'uuid', 'date'],
  'effective policy resolver exists'
);
select has_function(
  'app_private',
  'principal_lots_as_of',
  array['uuid', 'date'],
  'FIFO principal-lot derivation exists'
);
select has_function(
  'app_private',
  'calculate_interest_components',
  array['uuid', 'date'],
  'exact interest component calculator exists'
);
select has_function(
  'app_private',
  'post_interest_for_account_date',
  array['uuid', 'uuid', 'date'],
  'account/date posting function exists'
);
select has_function(
  'app_private',
  'run_interest_accrual_cycle',
  array[
    'timestamp with time zone',
    'interest_accrual_trigger_source',
    'integer'
  ],
  'station cycle function exists'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'app_private.post_interest_for_account_date(uuid,uuid,date)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'app_private.run_interest_accrual_cycle(timestamptz,interest_accrual_trigger_source,integer)',
    'execute'
  )
  and not has_function_privilege(
    'anon',
    'app_private.run_hourly_interest_accrual()',
    'execute'
  ),
  'normal clients cannot execute private accrual paths'
);

select ok(
  exists (
    select 1
    from pg_extension
    where extname = 'pg_cron'
  ),
  'pg_cron is enabled explicitly'
);
select is(
  (
    select count(*)::bigint
    from cron.job
    where jobname = 'credit-accounting-hourly-interest-accrual'
  ),
  1::bigint,
  'exactly one controlled hourly interest job is registered'
);
select is(
  (
    select schedule
    from cron.job
    where jobname = 'credit-accounting-hourly-interest-accrual'
  ),
  '7 * * * *',
  'the interest job runs hourly'
);
select is(
  (
    select command
    from cron.job
    where jobname = 'credit-accounting-hourly-interest-accrual'
  ),
  'select app_private.run_hourly_interest_accrual();',
  'the job targets only the fixed private entry point'
);
select ok(
  (
    select command !~* '(secret|token|password|service[_-]?role|https?://)'
    from cron.job
    where jobname = 'credit-accounting-hourly-interest-accrual'
  ),
  'the schedule contains no URL or embedded secret'
);
select ok(
  not has_schema_privilege('anon', 'cron', 'usage')
  and not has_schema_privilege('authenticated', 'cron', 'usage')
  and not has_schema_privilege('service_role', 'cron', 'usage'),
  'client-facing roles cannot use the cron schema'
);

select is(
  (
    select annual_rate
    from app_private.resolve_effective_interest_policy(
      'a0000000-0000-0000-0000-000000000001',
      'a2000000-0000-0000-0000-000000000002',
      '2026-01-15'
    )
  ),
  0.18000000::numeric,
  'organization default annual rate is 18 percent'
);
select is(
  (
    select day_count_basis
    from app_private.resolve_effective_interest_policy(
      'a0000000-0000-0000-0000-000000000001',
      'a2000000-0000-0000-0000-000000000002',
      '2026-01-15'
    )
  ),
  365::smallint,
  'the day-count denominator is fixed at 365'
);
select is(
  (
    select annual_rate
    from app_private.resolve_effective_interest_policy(
      'a0000000-0000-0000-0000-000000000001',
      'a2000000-0000-0000-0000-000000000001',
      '2026-01-15'
    )
  ),
  0.15000000::numeric,
  'customer override takes precedence over the organization default'
);

select throws_ok(
  $$update public.stations
    set time_zone_name = 'UTC+05:30'
    where id = 'a1000000-0000-0000-0000-000000000001'$$,
  '22023',
  'IAC_INVALID_TIMEZONE',
  'invalid fixed-offset timezone input is rejected'
);
select lives_ok(
  $$update public.stations
    set time_zone_name = 'Asia/Kolkata'
    where id = 'a1000000-0000-0000-0000-000000000001'$$,
  'a canonical IANA timezone remains valid'
);
select is(
  (
    select (
      '2026-07-01 19:00:00+00'::timestamptz
        at time zone time_zone_name
    )::date
    from public.stations
    where id = 'a1000000-0000-0000-0000-000000000001'
  ),
  '2026-07-02'::date,
  'Asia/Kolkata crosses the UTC date boundary correctly'
);

-- Deterministic fake Phase 2C fixtures.
create function pg_temp.iac_create_account(
  target_customer_id uuid,
  target_credit_account_id uuid,
  target_station_id uuid,
  target_phone text,
  target_customer_active boolean default true,
  target_account_active boolean default true
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  target_organization_id uuid;
  target_actor_id uuid;
begin
  select station.organization_id
  into target_organization_id
  from public.stations as station
  where station.id = target_station_id;

  target_actor_id := case
    when target_organization_id =
      'a0000000-0000-0000-0000-000000000001'::uuid
      then '10000000-0000-0000-0000-000000000001'::uuid
    else '10000000-0000-0000-0000-000000000002'::uuid
  end;

  insert into public.customers (
    id,
    organization_id,
    home_station_id,
    first_name,
    last_name,
    phone,
    status,
    created_by,
    updated_by
  )
  values (
    target_customer_id,
    target_organization_id,
    target_station_id,
    'Phase',
    'Two C',
    target_phone,
    case
      when target_customer_active
        then 'ACTIVE'::public.customer_status
      else 'INACTIVE'::public.customer_status
    end,
    target_actor_id,
    target_actor_id
  );

  insert into public.customer_account_settings (
    customer_id,
    organization_id,
    credit_limit_paise,
    default_annual_interest_rate,
    grace_days,
    grace_policy,
    due_days,
    created_by,
    updated_by
  )
  values (
    target_customer_id,
    target_organization_id,
    9000000000000000000,
    0.18000000,
    0,
    'AFTER_GRACE_ONLY',
    30,
    target_actor_id,
    target_actor_id
  );

  insert into public.credit_accounts (
    id,
    organization_id,
    customer_id,
    home_station_id,
    currency_code,
    is_active,
    created_by,
    updated_by
  )
  values (
    target_credit_account_id,
    target_organization_id,
    target_customer_id,
    target_station_id,
    'INR',
    target_account_active,
    target_actor_id,
    target_actor_id
  );
end;
$$;

create function pg_temp.iac_post_fuel(
  target_transaction_id uuid,
  target_credit_account_id uuid,
  target_business_date date,
  target_amount_paise bigint
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  account_row record;
  target_occurred_at timestamptz;
  target_actor_id uuid;
begin
  select
    account.organization_id,
    account.home_station_id as station_id,
    account.customer_id,
    station.time_zone_name
  into account_row
  from public.credit_accounts as account
  join public.stations as station
    on station.id = account.home_station_id
   and station.organization_id = account.organization_id
  where account.id = target_credit_account_id;

  target_occurred_at := (
    target_business_date::timestamp + interval '12 hours'
  ) at time zone account_row.time_zone_name;
  target_actor_id := case
    when account_row.organization_id =
      'a0000000-0000-0000-0000-000000000001'::uuid
      then '10000000-0000-0000-0000-000000000001'::uuid
    else '10000000-0000-0000-0000-000000000002'::uuid
  end;

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
    created_by,
    created_at
  )
  values (
    target_transaction_id,
    account_row.organization_id,
    account_row.station_id,
    target_credit_account_id,
    account_row.customer_id,
    'FUEL_CREDIT',
    'POSTED',
    target_amount_paise,
    'INR',
    target_occurred_at,
    target_actor_id,
    target_occurred_at
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
      account_row.organization_id,
      target_transaction_id,
      'CUSTOMER_ACCOUNTS_RECEIVABLE',
      'DEBIT',
      target_amount_paise,
      'INR',
      target_occurred_at
    ),
    (
      account_row.organization_id,
      target_transaction_id,
      'FUEL_SALES_REVENUE',
      'CREDIT',
      target_amount_paise,
      'INR',
      target_occurred_at
    );
end;
$$;

create function pg_temp.iac_post_repayment(
  target_transaction_id uuid,
  target_credit_account_id uuid,
  target_business_date date,
  target_principal_paise bigint,
  target_interest_paise bigint
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  account_row record;
  target_occurred_at timestamptz;
  target_actor_id uuid;
  target_total_paise bigint :=
    target_principal_paise + target_interest_paise;
begin
  select
    account.organization_id,
    account.home_station_id as station_id,
    account.customer_id,
    station.time_zone_name
  into account_row
  from public.credit_accounts as account
  join public.stations as station
    on station.id = account.home_station_id
   and station.organization_id = account.organization_id
  where account.id = target_credit_account_id;

  target_occurred_at := (
    target_business_date::timestamp + interval '18 hours'
  ) at time zone account_row.time_zone_name;
  target_actor_id := case
    when account_row.organization_id =
      'a0000000-0000-0000-0000-000000000001'::uuid
      then '10000000-0000-0000-0000-000000000001'::uuid
    else '10000000-0000-0000-0000-000000000002'::uuid
  end;

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
    created_by,
    created_at
  )
  values (
    target_transaction_id,
    account_row.organization_id,
    account_row.station_id,
    target_credit_account_id,
    account_row.customer_id,
    'CUSTOMER_REPAYMENT',
    'POSTED',
    target_total_paise,
    'INR',
    target_occurred_at,
    target_actor_id,
    target_occurred_at
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
  values (
    account_row.organization_id,
    target_transaction_id,
    'CASH_ON_HAND',
    'DEBIT',
    target_total_paise,
    'INR',
    target_occurred_at
  );

  if target_principal_paise > 0 then
    insert into public.ledger_entries (
      organization_id,
      transaction_id,
      account_code,
      direction,
      amount_paise,
      currency_code,
      created_at
    )
    values (
      account_row.organization_id,
      target_transaction_id,
      'CUSTOMER_ACCOUNTS_RECEIVABLE',
      'CREDIT',
      target_principal_paise,
      'INR',
      target_occurred_at
    );
  end if;

  if target_interest_paise > 0 then
    insert into public.ledger_entries (
      organization_id,
      transaction_id,
      account_code,
      direction,
      amount_paise,
      currency_code,
      created_at
    )
    values (
      account_row.organization_id,
      target_transaction_id,
      'CUSTOMER_INTEREST_RECEIVABLE',
      'CREDIT',
      target_interest_paise,
      'INR',
      target_occurred_at
    );
  end if;
end;
$$;

create function pg_temp.iac_start_run(
  target_station_id uuid,
  target_latest_completed_date date
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  target_run_id uuid := gen_random_uuid();
  station_row public.stations%rowtype;
  target_requested_at timestamptz;
begin
  select station.*
  into station_row
  from public.stations as station
  where station.id = target_station_id;

  target_requested_at := (
    (target_latest_completed_date + 1)::timestamp
      + interval '12 hours'
  ) at time zone station_row.time_zone_name;

  insert into public.interest_accrual_runs (
    id,
    organization_id,
    station_id,
    trigger_source,
    request_id,
    requested_at,
    station_time_zone_name,
    station_local_date,
    latest_completed_business_date,
    max_catch_up_days,
    status
  )
  values (
    target_run_id,
    station_row.organization_id,
    station_row.id,
    'TEST',
    gen_random_uuid(),
    target_requested_at,
    station_row.time_zone_name,
    target_latest_completed_date + 1,
    target_latest_completed_date,
    3660,
    'STARTED'
  );

  return target_run_id;
end;
$$;

create function pg_temp.iac_run_days(
  target_run_id uuid,
  target_credit_account_id uuid,
  target_first_date date,
  target_last_date date
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  processing_date date;
begin
  for processing_date in
    select generated_date::date
    from generate_series(
      target_first_date::timestamp,
      target_last_date::timestamp,
      interval '1 day'
    ) as generated_date
  loop
    perform *
    from app_private.post_interest_for_account_date(
      target_run_id,
      target_credit_account_id,
      processing_date
    );
  end loop;
end;
$$;

select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000101',
  'c2c00000-0000-0000-0000-000000000101',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000101'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000102',
  'c2c00000-0000-0000-0000-000000000102',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000102'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000103',
  'c2c00000-0000-0000-0000-000000000103',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000103'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000104',
  'c2c00000-0000-0000-0000-000000000104',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000104'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000105',
  'c2c00000-0000-0000-0000-000000000105',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000105'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000106',
  'c2c00000-0000-0000-0000-000000000106',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000106',
  false,
  false
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000107',
  'c2c00000-0000-0000-0000-000000000107',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000107'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000108',
  'c2c00000-0000-0000-0000-000000000108',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000108'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000109',
  'c2c00000-0000-0000-0000-000000000109',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000109'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000110',
  'c2c00000-0000-0000-0000-000000000110',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000110'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000111',
  'c2c00000-0000-0000-0000-000000000111',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000111'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000112',
  'c2c00000-0000-0000-0000-000000000112',
  'a1000000-0000-0000-0000-000000000002',
  '+15552000112'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000113',
  'c2c00000-0000-0000-0000-000000000113',
  'b1000000-0000-0000-0000-000000000001',
  '+15552000113'
);

insert into public.interest_policies (
  id,
  organization_id,
  customer_id,
  annual_rate,
  grace_days,
  grace_policy,
  effective_from,
  effective_to,
  is_active,
  interest_enabled,
  day_count_basis,
  created_by,
  updated_by
)
values
  ('c2d00000-0000-0000-0000-000000000101', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000101', 0.18000000, 3, 'AFTER_GRACE_ONLY', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000102', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000102', 0.18000000, 3, 'RETROACTIVE_AFTER_GRACE', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000103', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000103', 0.18000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000104', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000104', 0.18250000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000105', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000105', 0.18000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', '2026-08-02', true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000205', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000105', 0.18000000, 0, 'AFTER_GRACE_ONLY', '2026-08-02', null, true, false, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000106', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000106', 0.18000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000107', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000107', 0.10000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', '2026-07-03', true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000207', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000107', 0.20000000, 0, 'AFTER_GRACE_ONLY', '2026-07-03', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000108', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000108', 0.18000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000109', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000109', 0.50000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', '2026-05-02', true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000209', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000109', 0.50000000, 0, 'AFTER_GRACE_ONLY', '2026-05-02', null, true, false, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000110', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000110', 1.00000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000111', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000111', 1.00000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000112', 'a0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000112', 0.18000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('c2d00000-0000-0000-0000-000000000113', 'b0000000-0000-0000-0000-000000000001', 'c2b00000-0000-0000-0000-000000000113', 0.18000000, 0, 'AFTER_GRACE_ONLY', '2024-01-01', null, true, true, 365, '10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002');

select throws_ok(
  $$insert into public.interest_policies (
      organization_id,
      customer_id,
      annual_rate,
      grace_days,
      grace_policy,
      effective_from,
      effective_to,
      created_by,
      updated_by
    )
    values (
      'a0000000-0000-0000-0000-000000000001',
      'c2b00000-0000-0000-0000-000000000107',
      0.30,
      0,
      'AFTER_GRACE_ONLY',
      '2026-07-02',
      '2026-07-04',
      '10000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000001'
    )$$,
  '23P01',
  null,
  'overlapping customer policy history is rejected'
);

select is(
  (
    select annual_rate
    from app_private.resolve_effective_interest_policy(
      'a0000000-0000-0000-0000-000000000001',
      'c2b00000-0000-0000-0000-000000000107',
      '2026-07-02'
    )
  ),
  0.10000000::numeric,
  'the old rate resolves before its exclusive end date'
);
select is(
  (
    select annual_rate
    from app_private.resolve_effective_interest_policy(
      'a0000000-0000-0000-0000-000000000001',
      'c2b00000-0000-0000-0000-000000000107',
      '2026-07-03'
    )
  ),
  0.20000000::numeric,
  'the new rate resolves from its effective date'
);

create temporary table iac_test_state (
  state_key text primary key,
  state_uuid uuid not null
);

insert into iac_test_state
values (
  'north_run',
  pg_temp.iac_start_run(
    'a1000000-0000-0000-0000-000000000001',
    '2030-12-31'
  )
);

-- AFTER_GRACE_ONLY: D, D+1, D+2 are free; D+3 starts interest.
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000101',
  'c2c00000-0000-0000-0000-000000000101',
  '2026-01-01',
  36500
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000101',
  '2026-01-01',
  '2026-01-05'
);

select is(
  (
    select count(*)::bigint
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'
      and business_date between '2026-01-01' and '2026-01-03'
      and raw_interest_paise = 0
      and posted_interest_paise = 0
  ),
  3::bigint,
  'AFTER_GRACE_ONLY records all three grace days as zero'
);
select is(
  (
    select posted_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'
      and business_date = '2026-01-04'
  ),
  18::bigint,
  'AFTER_GRACE_ONLY starts normal interest on D plus G'
);
select is(
  (
    select posted_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'
      and business_date = '2026-01-05'
  ),
  18::bigint,
  'AFTER_GRACE_ONLY continues normally after the threshold'
);
select is(
  (
    select count(*)::bigint
    from public.interest_accrual_components
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'
      and component_kind = 'RETROACTIVE_CATCH_UP'
  ),
  0::bigint,
  'AFTER_GRACE_ONLY never adds grace-period catch-up'
);

-- RETROACTIVE_AFTER_GRACE: threshold catches up D through D+2 once.
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000102',
  'c2c00000-0000-0000-0000-000000000102',
  '2026-02-01',
  36500
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000102',
  '2026-02-01',
  '2026-02-05'
);

select is(
  (
    select count(*)::bigint
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000102'
      and business_date between '2026-02-01' and '2026-02-03'
      and posted_interest_paise = 0
  ),
  3::bigint,
  'retroactive grace dates initially post zero'
);
select is(
  (
    select raw_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000102'
      and business_date = '2026-02-04'
  ),
  72.000000000000000000::numeric,
  'retroactive threshold includes three catch-up days plus threshold day'
);
select is(
  (
    select count(*)::bigint
    from public.interest_accrual_components
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000102'
      and accrual_business_date = '2026-02-04'
      and component_kind = 'RETROACTIVE_CATCH_UP'
  ),
  3::bigint,
  'retroactive evidence identifies each intended catch-up source date'
);
select results_eq(
  $$select interest_business_date
    from public.interest_accrual_components
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000102'
      and accrual_business_date = '2026-02-04'
      and component_kind = 'RETROACTIVE_CATCH_UP'
    order by interest_business_date$$,
  $$values
      ('2026-02-01'::date),
      ('2026-02-02'::date),
      ('2026-02-03'::date)$$,
  'retroactive catch-up covers D through threshold minus one exactly'
);
select is(
  (
    select posted_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000102'
      and business_date = '2026-02-05'
  ),
  18::bigint,
  'retroactive policy returns to normal daily interest after threshold'
);
select is(
  (
    select was_created
    from app_private.post_interest_for_account_date(
      (select state_uuid
       from iac_test_state
       where state_key = 'north_run'),
      'c2c00000-0000-0000-0000-000000000102',
      '2026-02-04'
    )
  ),
  false,
  'rerunning the retroactive threshold is a safe no-op'
);
select is(
  (
    select count(*)::bigint
    from public.interest_accrual_components
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000102'
      and component_kind = 'RETROACTIVE_CATCH_UP'
  ),
  3::bigint,
  'rerun does not duplicate catch-up components'
);

select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000116',
  'c2c00000-0000-0000-0000-000000000116',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000116'
);
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000117',
  'c2c00000-0000-0000-0000-000000000117',
  'a1000000-0000-0000-0000-000000000001',
  '+15552000117'
);
insert into public.interest_policies (
  id,
  organization_id,
  customer_id,
  annual_rate,
  grace_days,
  grace_policy,
  effective_from,
  is_active,
  interest_enabled,
  day_count_basis,
  created_by,
  updated_by
)
values
  (
    'c2d00000-0000-0000-0000-000000000116',
    'a0000000-0000-0000-0000-000000000001',
    'c2b00000-0000-0000-0000-000000000116',
    0.18000000,
    3,
    'RETROACTIVE_AFTER_GRACE',
    '2024-01-01',
    true,
    true,
    365,
    '10000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001'
  ),
  (
    'c2d00000-0000-0000-0000-000000000117',
    'a0000000-0000-0000-0000-000000000001',
    'c2b00000-0000-0000-0000-000000000117',
    0.18000000,
    3,
    'RETROACTIVE_AFTER_GRACE',
    '2024-01-01',
    true,
    true,
    365,
    '10000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001'
  );

select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000116',
  'c2c00000-0000-0000-0000-000000000116',
  '2026-02-10',
  36500
);
select pg_temp.iac_post_repayment(
  'c2f00000-0000-0000-0000-000000000116',
  'c2c00000-0000-0000-0000-000000000116',
  '2026-02-12',
  18250,
  0
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000116',
  '2026-02-10',
  '2026-02-13'
);
select is(
  (
    select raw_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000116'
      and business_date = '2026-02-13'
  ),
  54.000000000000000000::numeric,
  'retroactive catch-up uses each grace day historical closing balance'
);
select results_eq(
  $$select interest_business_date, raw_interest_paise
    from public.interest_accrual_components
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000116'
      and accrual_business_date = '2026-02-13'
    order by interest_business_date$$,
  $$values
      ('2026-02-10'::date, 18.000000000000000000::numeric),
      ('2026-02-11'::date, 18.000000000000000000::numeric),
      ('2026-02-12'::date, 9.000000000000000000::numeric),
      ('2026-02-13'::date, 9.000000000000000000::numeric)$$,
  'partial grace-period repayment reduces catch-up from its closing date'
);

select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000117',
  'c2c00000-0000-0000-0000-000000000117',
  '2026-02-20',
  36500
);
select pg_temp.iac_post_repayment(
  'c2f00000-0000-0000-0000-000000000117',
  'c2c00000-0000-0000-0000-000000000117',
  '2026-02-22',
  36500,
  0
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000117',
  '2026-02-20',
  '2026-02-23'
);
select is(
  (
    select raw_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000117'
      and business_date = '2026-02-23'
  ),
  0.000000000000000000::numeric,
  'a lot fully repaid before retroactive threshold has no catch-up'
);
select is(
  (
    select component_count
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000117'
      and business_date = '2026-02-23'
  ),
  0,
  'fully repaid retroactive lot creates no threshold components'
);

-- FIFO principal lots and same-day closing principal.
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000103',
  'c2c00000-0000-0000-0000-000000000103',
  '2026-03-01',
  10000
);
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000203',
  'c2c00000-0000-0000-0000-000000000103',
  '2026-03-02',
  20000
);
select is(
  (
    select sum(source_remaining_principal_paise)::bigint
    from app_private.principal_lots_as_of(
      'c2c00000-0000-0000-0000-000000000103',
      '2026-03-02'
    )
  ),
  30000::bigint,
  'multiple fully outstanding fuel lots sum correctly'
);

select pg_temp.iac_post_repayment(
  'c2f00000-0000-0000-0000-000000000103',
  'c2c00000-0000-0000-0000-000000000103',
  '2026-03-03',
  15000,
  0
);
select is(
  (
    select source_remaining_principal_paise
    from app_private.principal_lots_as_of(
      'c2c00000-0000-0000-0000-000000000103',
      '2026-03-03'
    )
    where source_transaction_id =
      'c2e00000-0000-0000-0000-000000000103'
  ),
  0::bigint,
  'FIFO repayment closes the oldest lot first'
);
select is(
  (
    select source_remaining_principal_paise
    from app_private.principal_lots_as_of(
      'c2c00000-0000-0000-0000-000000000103',
      '2026-03-03'
    )
    where source_transaction_id =
      'c2e00000-0000-0000-0000-000000000203'
  ),
  15000::bigint,
  'FIFO repayment partially reduces the next-oldest lot'
);

select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000303',
  'c2c00000-0000-0000-0000-000000000103',
  '2026-03-04',
  10000
);
select pg_temp.iac_post_repayment(
  'c2f00000-0000-0000-0000-000000000203',
  'c2c00000-0000-0000-0000-000000000103',
  '2026-03-04',
  5000,
  0
);
select is(
  (
    select sum(source_remaining_principal_paise)::bigint
    from app_private.principal_lots_as_of(
      'c2c00000-0000-0000-0000-000000000103',
      '2026-03-04'
    )
  ),
  20000::bigint,
  'same-day fuel and principal repayment produce deterministic closing principal'
);
select is(
  (
    select source_remaining_principal_paise
    from app_private.principal_lots_as_of(
      'c2c00000-0000-0000-0000-000000000103',
      '2026-03-04'
    )
    where source_transaction_id =
      'c2e00000-0000-0000-0000-000000000303'
  ),
  10000::bigint,
  'a later fuel lot retains its own remaining principal after FIFO allocation'
);

select pg_temp.iac_post_repayment(
  'c2f00000-0000-0000-0000-000000000303',
  'c2c00000-0000-0000-0000-000000000103',
  '2026-03-05',
  0,
  1
);
select is(
  (
    select sum(source_remaining_principal_paise)::bigint
    from app_private.principal_lots_as_of(
      'c2c00000-0000-0000-0000-000000000103',
      '2026-03-05'
    )
  ),
  20000::bigint,
  'interest-only repayment does not alter principal lots'
);

select pg_temp.iac_post_repayment(
  'c2f00000-0000-0000-0000-000000000403',
  'c2c00000-0000-0000-0000-000000000103',
  '2026-03-06',
  3000,
  100
);
select is(
  (
    select sum(source_remaining_principal_paise)::bigint
    from app_private.principal_lots_as_of(
      'c2c00000-0000-0000-0000-000000000103',
      '2026-03-06'
    )
  ),
  17000::bigint,
  'split repayment reduces lots only by its principal component'
);

select pg_temp.iac_post_repayment(
  'c2f00000-0000-0000-0000-000000000503',
  'c2c00000-0000-0000-0000-000000000103',
  '2026-03-07',
  12000,
  0
);
select is(
  (
    select count(*)::bigint
    from app_private.principal_lots_as_of(
      'c2c00000-0000-0000-0000-000000000103',
      '2026-03-07'
    )
    where source_remaining_principal_paise > 0
  ),
  1::bigint,
  'one FIFO repayment can close multiple oldest lots'
);
select is(
  (
    select sum(source_remaining_principal_paise)::bigint
    from app_private.principal_lots_as_of(
      'c2c00000-0000-0000-0000-000000000103',
      '2026-03-07'
    )
  ),
  5000::bigint,
  'multi-lot repayment leaves the correct newest-lot balance'
);

select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000103',
  '2026-03-01',
  '2026-03-07'
);
select is(
  (
    select eligible_principal_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000103'
      and business_date = '2026-03-04'
  ),
  20000::bigint,
  'same-day repayment is reflected before that day interest is finalized'
);
select is(
  (
    select count(*)::bigint
    from public.interest_accrual_components
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000103'
      and accrual_business_date = '2026-03-04'
      and component_kind = 'DAILY'
  ),
  2::bigint,
  'multi-lot eligible principal has one auditable component per open lot'
);

-- Exact NUMERIC carry and deterministic rounding.
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000104',
  'c2c00000-0000-0000-0000-000000000104',
  '2026-04-01',
  100
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000104',
  '2026-04-01',
  '2026-04-10'
);
select is(
  (
    select raw_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000104'
      and business_date = '2026-04-01'
  ),
  0.050000000000000000::numeric,
  'authoritative raw interest uses exact NUMERIC arithmetic'
);
select is(
  (
    select closing_fractional_carry_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000104'
      and business_date = '2026-04-09'
  ),
  0.450000000000000000::numeric,
  'fractional paise are preserved across zero-post days'
);
select is(
  (
    select posted_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000104'
      and business_date = '2026-04-10'
  ),
  1::bigint,
  'small fractions eventually become one payable paise'
);
select is(
  (
    select count(*)::bigint
    from public.ledger_transactions as transaction
    where transaction.credit_account_id =
      'c2c00000-0000-0000-0000-000000000104'
      and transaction.transaction_type = 'INTEREST_CHARGE'
  ),
  1::bigint,
  'nine zero-whole-paise days create no ledger charge'
);
select is(
  (
    select count(*)::bigint
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000104'
  ),
  10::bigint,
  'zero-post calculation evidence remains complete'
);

select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000109',
  'c2c00000-0000-0000-0000-000000000109',
  '2026-05-01',
  365
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000109',
  '2026-05-01',
  '2026-05-02'
);
select is(
  (
    select raw_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000109'
      and business_date = '2026-05-01'
  ),
  0.500000000000000000::numeric,
  'half-paise fixture reaches the exact boundary'
);
select is(
  (
    select posted_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000109'
      and business_date = '2026-05-01'
  ),
  1::bigint,
  'NUMERIC round uses half away from zero'
);
select is(
  (
    select closing_fractional_carry_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000109'
      and business_date = '2026-05-01'
  ),
  (-0.500000000000000000)::numeric,
  'the exact half boundary preserves the signed residual carry'
);
select is(
  (
    select posted_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000109'
      and business_date = '2026-05-02'
  ),
  0::bigint,
  'a later zero-raw day never reverses an exact half-paise posting'
);
select is(
  (
    select closing_fractional_carry_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000109'
      and business_date = '2026-05-02'
  ),
  (-0.500000000000000000)::numeric,
  'a disabled day preserves the prior negative half-paise residual exactly'
);
select is(
  (
    select count(*)::bigint
    from public.interest_accruals
    where posted_interest_paise < 0
  ),
  0::bigint,
  'the engine never creates negative interest'
);

select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000110',
  'c2c00000-0000-0000-0000-000000000110',
  '2026-06-01',
  9000000000000000000
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000110',
  '2026-06-01',
  '2026-06-01'
);
select is(
  (
    select raw_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000110'
  ),
  24657534246575342.465753424657534247::numeric,
  'large in-range principal calculates exactly without binary float'
);

select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000111',
  'c2c00000-0000-0000-0000-000000000111',
  '2026-06-10',
  9000000000000000000
);
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000211',
  'c2c00000-0000-0000-0000-000000000111',
  '2026-06-10',
  9000000000000000000
);
select throws_ok(
  format(
    'select * from app_private.post_interest_for_account_date(%L,%L,%L)',
    (select state_uuid
     from iac_test_state
     where state_key = 'north_run'),
    'c2c00000-0000-0000-0000-000000000111',
    '2026-06-10'
  ),
  '22003',
  'IAC_ELIGIBLE_PRINCIPAL_OVERFLOW',
  'eligible-principal overflow is rejected before posting'
);

-- Effective-date snapshots, disabled periods, inactive debt, and leap day.
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000107',
  'c2c00000-0000-0000-0000-000000000107',
  '2026-07-01',
  36500
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000107',
  '2026-07-01',
  '2026-07-03'
);
select is(
  (
    select annual_rate
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000107'
      and business_date = '2026-07-02'
  ),
  0.10000000::numeric,
  'historical accrual retains the pre-change policy snapshot'
);
select is(
  (
    select annual_rate
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000107'
      and business_date = '2026-07-03'
  ),
  0.20000000::numeric,
  'rate change applies only from its effective date'
);
select is(
  (
    select posted_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000107'
      and business_date = '2026-07-03'
  ),
  20::bigint,
  'new effective rate determines only forward interest'
);

select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000105',
  'c2c00000-0000-0000-0000-000000000105',
  '2026-08-01',
  36500
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000105',
  '2026-08-01',
  '2026-08-02'
);
select is(
  (
    select posted_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000105'
      and business_date = '2026-08-01'
  ),
  18::bigint,
  'enabled policy accrues before the disabled effective date'
);
select is(
  (
    select raw_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000105'
      and business_date = '2026-08-02'
  ),
  0.000000000000000000::numeric,
  'disabled effective policy produces no new raw interest'
);
select is(
  (
    select interest_enabled
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000105'
      and business_date = '2026-08-02'
  ),
  false,
  'disabled state is preserved in daily evidence'
);
select is(
  (
    select outstanding_interest_paise
    from app_private.calculate_credit_account_obligations(
      'c2c00000-0000-0000-0000-000000000105'
    )
  ),
  18::bigint,
  'historical posted interest remains due after disabling'
);

select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000106',
  'c2c00000-0000-0000-0000-000000000106',
  '2026-09-01',
  36500
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000106',
  '2026-09-01',
  '2026-09-01'
);
select is(
  (
    select posted_interest_paise
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000106'
  ),
  18::bigint,
  'inactive customer with unpaid principal continues to accrue'
);
select ok(
  (
    select customer.status = 'INACTIVE' and not account.is_active
    from public.customers as customer
    join public.credit_accounts as account
      on account.customer_id = customer.id
    where account.id =
      'c2c00000-0000-0000-0000-000000000106'
  ),
  'inactive-account accrual fixture is actually inactive'
);

select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000108',
  'c2c00000-0000-0000-0000-000000000108',
  '2024-02-29',
  36500
);
select pg_temp.iac_run_days(
  (select state_uuid from iac_test_state where state_key = 'north_run'),
  'c2c00000-0000-0000-0000-000000000108',
  '2024-02-29',
  '2024-02-29'
);
select is(
  (
    select business_date
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000108'
  ),
  '2024-02-29'::date,
  'leap day is processed as a normal business date'
);
select is(
  (
    select day_count_basis
    from public.interest_accrual_components
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000108'
  ),
  365::smallint,
  'leap-day calculation still uses denominator 365'
);

-- Accounting, derived balances, no compounding, and idempotency.
select is(
  (
    select count(*)::bigint
    from public.ledger_transactions
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'
      and transaction_type = 'INTEREST_CHARGE'
  ),
  2::bigint,
  'each positive daily amount posts one interest transaction'
);
select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.ledger_transactions as transaction
      on transaction.id = entry.transaction_id
    where transaction.credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'
      and transaction.transaction_type = 'INTEREST_CHARGE'
      and entry.account_code = 'CUSTOMER_INTEREST_RECEIVABLE'
      and entry.direction = 'DEBIT'
  ),
  2::bigint,
  'interest transactions debit interest receivable'
);
select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.ledger_transactions as transaction
      on transaction.id = entry.transaction_id
    where transaction.credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'
      and transaction.transaction_type = 'INTEREST_CHARGE'
      and entry.account_code = 'INTEREST_INCOME'
      and entry.direction = 'CREDIT'
  ),
  2::bigint,
  'interest transactions credit interest income'
);
select is(
  (
    select sum(
      case entry.direction
        when 'DEBIT' then entry.amount_paise
        else -entry.amount_paise
      end
    )::bigint
    from public.ledger_entries as entry
    join public.ledger_transactions as transaction
      on transaction.id = entry.transaction_id
    where transaction.credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'
      and transaction.transaction_type = 'INTEREST_CHARGE'
  ),
  0::bigint,
  'interest debits and credits remain exactly balanced'
);
select is(
  (
    select outstanding_principal_paise
    from app_private.calculate_credit_account_obligations(
      'c2c00000-0000-0000-0000-000000000101'
    )
  ),
  36500::bigint,
  'interest posting does not increase principal'
);
select is(
  (
    select available_credit_paise
    from app_private.calculate_credit_account_obligations(
      'c2c00000-0000-0000-0000-000000000101'
    )
  ),
  8999999999999963500::bigint,
  'interest posting does not reduce available credit'
);
select is(
  (
    select outstanding_interest_paise
    from app_private.calculate_credit_account_obligations(
      'c2c00000-0000-0000-0000-000000000101'
    )
  ),
  36::bigint,
  'derived outstanding interest increases by posted charges'
);
select is(
  (
    select total_due_paise
    from app_private.calculate_credit_account_obligations(
      'c2c00000-0000-0000-0000-000000000101'
    )
  ),
  36536::bigint,
  'derived total due includes principal plus interest'
);
select is(
  (
    select raw_interest_paise
    from app_private.calculate_interest_components(
      'c2c00000-0000-0000-0000-000000000101',
      '2026-01-06'
    )
  ),
  18.000000000000000000::numeric,
  'prior posted interest is excluded from the next interest basis'
);
select is(
  (
    select count(*)::bigint
    from public.audit_events
    where action = 'interest.accrued'
      and after_state->>'credit_account_id' =
        'c2c00000-0000-0000-0000-000000000101'
  ),
  2::bigint,
  'positive interest creates one financial audit event per posting'
);
select ok(
  (
    select bool_and(
      after_state ? 'interest_accrual_run_id'
      and after_state ? 'trigger_source'
      and after_state ? 'annual_rate'
      and after_state ? 'grace_policy'
      and after_state ? 'correlation_request_id'
    )
    from public.audit_events
    where action = 'interest.accrued'
  ),
  'audit evidence includes policy, run, trigger, and correlation fields'
);

select is(
  (
    select count(*)::bigint
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000102'
      and business_date = '2026-02-04'
  ),
  1::bigint,
  'one logical accrual row exists after rerun'
);
select is(
  (
    select count(*)::bigint
    from public.ledger_transactions
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000102'
      and transaction_type = 'INTEREST_CHARGE'
      and business_date = '2026-02-04'
  ),
  1::bigint,
  'rerun creates no duplicate interest transaction'
);
select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.ledger_transactions as transaction
      on transaction.id = entry.transaction_id
    where transaction.credit_account_id =
      'c2c00000-0000-0000-0000-000000000102'
      and transaction.transaction_type = 'INTEREST_CHARGE'
      and transaction.business_date = '2026-02-04'
  ),
  2::bigint,
  'rerun creates no duplicate ledger entries'
);
select is(
  (
    select count(*)::bigint
    from public.audit_events
    where action = 'interest.accrued'
      and after_state->>'credit_account_id' =
        'c2c00000-0000-0000-0000-000000000102'
      and after_state->>'business_date' = '2026-02-04'
  ),
  1::bigint,
  'rerun creates no duplicate financial-success audit event'
);

select is(
  (
    select count(*)::bigint
    from pg_proc as procedure
    join pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'app_private'
      and procedure.proname in (
        'principal_lots_as_of',
        'calculate_interest_components',
        'post_interest_for_account_date'
      )
      and pg_get_functiondef(procedure.oid)
        ~* '(double precision|::real|::float)'
  ),
  0::bigint,
  'authoritative interest functions contain no binary floating-point path'
);
select is(
  (
    select count(*)::bigint
    from public.audit_events
    where action = 'interest.accrued'
      and (
        after_state ? 'phone'
        or after_state ? 'address'
        or after_state ? 'token'
        or after_state ? 'password'
        or after_state ? 'secret'
      )
  ),
  0::bigint,
  'interest audit evidence contains no PII or secret fields'
);
select is(
  (
    select count(*)::bigint
    from public.ledger_transactions as transaction
    where transaction.transaction_type = 'INTEREST_CHARGE'
      and transaction.created_by is null
  ),
  (
    select count(*)::bigint
    from public.interest_accruals
    where posted_interest_paise > 0
  ),
  'each engine-authored interest ledger charge has one positive accrual detail'
);
select throws_ok(
  $$insert into public.ledger_transactions (
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
      created_by
    )
    values (
      'c2e00000-0000-0000-0000-000000000999',
      'a0000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'c2c00000-0000-0000-0000-000000000101',
      'c2b00000-0000-0000-0000-000000000101',
      'INTEREST_CHARGE',
      'POSTED',
      1,
      'INR',
      '2026-01-10 12:00:00+05:30',
      '2026-01-10',
      null
    );
    insert into public.ledger_entries (
      organization_id,
      transaction_id,
      account_code,
      direction,
      amount_paise,
      currency_code
    )
    values
      (
        'a0000000-0000-0000-0000-000000000001',
        'c2e00000-0000-0000-0000-000000000999',
        'CUSTOMER_INTEREST_RECEIVABLE',
        'DEBIT',
        1,
        'INR'
      ),
      (
        'a0000000-0000-0000-0000-000000000001',
        'c2e00000-0000-0000-0000-000000000999',
        'INTEREST_INCOME',
        'CREDIT',
        1,
        'INR'
      );
    set constraints system_interest_requires_accrual_detail immediate$$,
  '23514',
  'IAC_LEDGER_DETAIL_REQUIRED',
  'system-authored interest cannot commit without accrual business detail'
);
set constraints all deferred;

select throws_ok(
  $$update public.interest_accruals
    set posted_interest_paise = posted_interest_paise
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'$$,
  '42501',
  'interest accrual evidence is append-only',
  'daily calculation evidence rejects updates'
);
select throws_ok(
  $$delete from public.interest_accrual_components
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000101'$$,
  '42501',
  'interest accrual evidence is append-only',
  'source evidence rejects deletes'
);
select throws_ok(
  $$update public.ledger_transactions
    set amount_paise = amount_paise
    where id = (
      select id
      from public.ledger_transactions
      where transaction_type = 'INTEREST_CHARGE'
      limit 1
    )$$,
  '42501',
  'financial records are append-only',
  'interest ledger transactions remain immutable'
);

select throws_ok(
  $$delete from public.audit_events
    where action = 'interest.accrued'$$,
  '42501',
  'audit events are append-only',
  'interest audit evidence remains immutable'
);

select throws_ok(
  format(
    'select * from app_private.post_interest_for_account_date(%L,%L,null)',
    (select state_uuid
     from iac_test_state
     where state_key = 'north_run'),
    'c2c00000-0000-0000-0000-000000000101'
  ),
  '22023',
  'IAC_INVALID_DATE',
  'null accrual date has a stable safe error'
);
select throws_ok(
  format(
    'select * from app_private.post_interest_for_account_date(%L,%L,%L)',
    (select state_uuid
     from iac_test_state
     where state_key = 'north_run'),
    'c2c00000-0000-0000-0000-000000000101',
    '2031-01-01'
  ),
  'P0001',
  'IAC_BUSINESS_DATE_NOT_COMPLETED',
  'a current or future local day cannot be accrued'
);
select throws_ok(
  $$select * from app_private.resolve_effective_interest_policy(
      'a0000000-0000-0000-0000-000000000001',
      'c2b00000-0000-0000-0000-000000000101',
      '2023-12-31'
    )$$,
  'P0001',
  'IAC_POLICY_NOT_FOUND',
  'missing effective policy has a stable safe error'
);

select throws_ok(
  $$insert into public.ledger_transactions (
      organization_id,
      station_id,
      credit_account_id,
      customer_id,
      transaction_type,
      status,
      amount_paise,
      occurred_at,
      business_date,
      created_by
    )
    values (
      'a0000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'c2c00000-0000-0000-0000-000000000101',
      'c2b00000-0000-0000-0000-000000000101',
      'FUEL_CREDIT',
      'POSTED',
      1,
      '2026-01-10 12:00:00+05:30',
      '2026-01-09',
      '10000000-0000-0000-0000-000000000001'
    )$$,
  '23514',
  'LEDGER_BUSINESS_DATE_MISMATCH',
  'trusted event timestamp and supplied principal business date must agree'
);
select is(
  (
    select business_date
    from public.ledger_transactions
    where id = 'c2e00000-0000-0000-0000-000000000101'
  ),
  '2026-01-01'::date,
  'principal event business date is stored deterministically'
);

-- Station-local last-completed-day selection.
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000112',
  'c2c00000-0000-0000-0000-000000000112',
  '2026-07-01',
  36500
);

select is(
  (
    select account_days_processed
    from app_private.run_interest_accrual_for_station(
      'a1000000-0000-0000-0000-000000000002',
      '2026-07-01 18:29:00+00',
      'TEST',
      'c2a00000-0000-0000-0000-000000000112',
      10
    )
  ),
  0,
  'the current incomplete Asia/Kolkata business day is not accrued'
);
select is(
  (
    select latest_completed_business_date
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000112'
  ),
  '2026-06-30'::date,
  '23:59 Asia/Kolkata exposes only the prior completed day'
);
select is(
  (
    select account_days_processed
    from app_private.run_interest_accrual_for_station(
      'a1000000-0000-0000-0000-000000000002',
      '2026-07-01 18:31:00+00',
      'TEST',
      'c2a00000-0000-0000-0000-000000000212',
      10
    )
  ),
  1,
  'the same date is accrued after local midnight completes it'
);
select is(
  (
    select business_date
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000112'
  ),
  '2026-07-01'::date,
  'the last completed station-local date is the accrued date'
);
select is(
  (
    select station_local_date
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000212'
  ),
  '2026-07-02'::date,
  'UTC boundary resolves to the correct Asia/Kolkata processing date'
);

-- Bounded catch-up and equality with uninterrupted processing.
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000113',
  'c2c00000-0000-0000-0000-000000000113',
  '2026-07-20',
  36500
);

select is(
  (
    select run_status
    from app_private.run_interest_accrual_for_station(
      'b1000000-0000-0000-0000-000000000001',
      '2026-07-25 12:00:00-05',
      'CATCH_UP',
      'c2a00000-0000-0000-0000-000000000113',
      2
    )
  ),
  'COMPLETED_WITH_REMAINING'::public.interest_accrual_run_status,
  'catch-up limit is represented as completed with remaining work'
);
select is(
  (
    select result_code
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000113'
  ),
  'IAC_CATCHUP_LIMIT',
  'catch-up limit uses a stable result code'
);
select is(
  (
    select account_days_processed
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000113'
  ),
  2,
  'the configured catch-up span is enforced per account'
);
select is(
  (
    select more_dates_pending
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000113'
  ),
  true,
  'the first bounded run reports remaining dates accurately'
);
select results_eq(
  $$select business_date
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000113'
    order by business_date$$,
  $$values ('2026-07-20'::date), ('2026-07-21'::date)$$,
  'the first catch-up run processes missing dates chronologically'
);

select is(
  (
    select run_status
    from app_private.run_interest_accrual_for_station(
      'b1000000-0000-0000-0000-000000000001',
      '2026-07-25 12:05:00-05',
      'CATCH_UP',
      'c2a00000-0000-0000-0000-000000000213',
      2
    )
  ),
  'COMPLETED_WITH_REMAINING'::public.interest_accrual_run_status,
  'the next cycle continues bounded work safely'
);
select results_eq(
  $$select business_date
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000113'
    order by business_date$$,
  $$values
      ('2026-07-20'::date),
      ('2026-07-21'::date),
      ('2026-07-22'::date),
      ('2026-07-23'::date)$$,
  'the second catch-up cycle neither skips nor duplicates a date'
);
select is(
  (
    select run_status
    from app_private.run_interest_accrual_for_station(
      'b1000000-0000-0000-0000-000000000001',
      '2026-07-25 12:10:00-05',
      'CATCH_UP',
      'c2a00000-0000-0000-0000-000000000313',
      2
    )
  ),
  'COMPLETED'::public.interest_accrual_run_status,
  'the final catch-up cycle completes the remaining date'
);
select results_eq(
  $$select business_date
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000113'
    order by business_date$$,
  $$values
      ('2026-07-20'::date),
      ('2026-07-21'::date),
      ('2026-07-22'::date),
      ('2026-07-23'::date),
      ('2026-07-24'::date)$$,
  'bounded catch-up eventually produces each missing date exactly once'
);
select is(
  (
    select more_dates_pending
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000313'
  ),
  false,
  'the final catch-up run reports no remaining work'
);

select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000114',
  'c2c00000-0000-0000-0000-000000000114',
  'b1000000-0000-0000-0000-000000000001',
  '+15552000114'
);
insert into public.interest_policies (
  id,
  organization_id,
  customer_id,
  annual_rate,
  grace_days,
  grace_policy,
  effective_from,
  is_active,
  interest_enabled,
  day_count_basis,
  created_by,
  updated_by
)
values (
  'c2d00000-0000-0000-0000-000000000114',
  'b0000000-0000-0000-0000-000000000001',
  'c2b00000-0000-0000-0000-000000000114',
  0.18000000,
  0,
  'AFTER_GRACE_ONLY',
  '2024-01-01',
  true,
  true,
  365,
  '10000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000002'
);
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000114',
  'c2c00000-0000-0000-0000-000000000114',
  '2026-07-20',
  36500
);
insert into iac_test_state
values (
  'b_uninterrupted_run',
  pg_temp.iac_start_run(
    'b1000000-0000-0000-0000-000000000001',
    '2026-07-24'
  )
);
select pg_temp.iac_run_days(
  (select state_uuid
   from iac_test_state
   where state_key = 'b_uninterrupted_run'),
  'c2c00000-0000-0000-0000-000000000114',
  '2026-07-20',
  '2026-07-24'
);
select is(
  (
    select sum(raw_interest_paise)
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000113'
  ),
  (
    select sum(raw_interest_paise)
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000114'
  ),
  'catch-up and uninterrupted processing have identical exact raw interest'
);
select is(
  (
    select sum(posted_interest_paise)::bigint
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000113'
  ),
  (
    select sum(posted_interest_paise)::bigint
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000114'
  ),
  'catch-up and uninterrupted processing post the same whole paise'
);

select is(
  (
    select interest_accrual_run_id
    from app_private.run_interest_accrual_for_station(
      'b1000000-0000-0000-0000-000000000001',
      '2026-07-25 12:00:00-05',
      'CATCH_UP',
      'c2a00000-0000-0000-0000-000000000113',
      2
    )
  ),
  (
    select id
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000113'
  ),
  'reusing a run correlation request safely replays the original run'
);
select is(
  (
    select count(*)::bigint
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000113'
  ),
  1::bigint,
  'run replay creates no duplicate operational record'
);

-- Read authorization: owners and assigned managers only.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select ok(
  (select count(*) > 0 from public.interest_accrual_runs)
  and not exists (
    select 1
    from public.interest_accrual_runs
    where organization_id =
      'b0000000-0000-0000-0000-000000000001'
  ),
  'owner reads accrual runs only in the owned organization'
);
select ok(
  (select count(*) > 0 from public.interest_accruals)
  and not exists (
    select 1
    from public.interest_accruals
    where organization_id =
      'b0000000-0000-0000-0000-000000000001'
  ),
  'owner reads daily evidence only in the owned organization'
);
select ok(
  (select count(*) > 0 from public.interest_accrual_components)
  and not exists (
    select 1
    from public.interest_accrual_components
    where organization_id =
      'b0000000-0000-0000-0000-000000000001'
  ),
  'owner reads source evidence only in the owned organization'
);

select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select ok(
  (select count(*) > 0 from public.interest_accrual_runs)
  and not exists (
    select 1
    from public.interest_accrual_runs
    where station_id <>
      'a1000000-0000-0000-0000-000000000001'
  ),
  'manager reads runs only at the assigned station'
);
select ok(
  (select count(*) > 0 from public.interest_accruals)
  and not exists (
    select 1
    from public.interest_accruals
    where station_id <>
      'a1000000-0000-0000-0000-000000000001'
  ),
  'manager cannot read another station daily evidence'
);
select ok(
  (select count(*) > 0 from public.interest_accrual_components)
  and not exists (
    select 1
    from public.interest_accrual_components
    where station_id <>
      'a1000000-0000-0000-0000-000000000001'
  ),
  'manager cannot read another station source components'
);

select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000004',
  true
);
select is(
  (select count(*)::bigint from public.interest_accrual_runs),
  0::bigint,
  'attendant cannot browse run tables'
);
select is(
  (select count(*)::bigint from public.interest_accruals),
  0::bigint,
  'attendant cannot browse daily calculation evidence'
);
select is(
  (select count(*)::bigint from public.interest_accrual_components),
  0::bigint,
  'attendant cannot browse source components'
);

select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000005',
  true
);
select is(
  (select count(*)::bigint from public.interest_accruals),
  0::bigint,
  'customer cannot browse raw accrual evidence'
);
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000006',
  true
);
select is(
  (select count(*)::bigint from public.interest_accrual_runs),
  0::bigint,
  'driver cannot browse organization accrual runs'
);
select is(
  (select count(*)::bigint from public.interest_accruals),
  0::bigint,
  'driver cannot browse raw daily accruals'
);

select throws_ok(
  $$insert into public.interest_accrual_runs default values$$,
  '42501',
  'permission denied for table interest_accrual_runs',
  'ordinary authenticated clients cannot create a run'
);

reset role;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000002',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select ok(
  (select count(*) > 0 from public.interest_accrual_runs)
  and not exists (
    select 1
    from public.interest_accrual_runs
    where organization_id =
      'a0000000-0000-0000-0000-000000000001'
  ),
  'cross-tenant owner sees only the separately owned organization'
);
reset role;

select ok(
  not has_table_privilege(
    'anon',
    'public.interest_accrual_runs',
    'select'
  )
  and not has_table_privilege(
    'anon',
    'public.interest_accruals',
    'select'
  )
  and not has_table_privilege(
    'anon',
    'public.interest_accrual_components',
    'select'
  ),
  'anonymous role reads no interest evidence'
);

-- A failed trusted station run keeps only a sanitized operational result.
select pg_temp.iac_create_account(
  'c2b00000-0000-0000-0000-000000000115',
  'c2c00000-0000-0000-0000-000000000115',
  'a1000000-0000-0000-0000-000000000002',
  '+15552000115'
);
insert into public.interest_policies (
  id,
  organization_id,
  customer_id,
  annual_rate,
  grace_days,
  grace_policy,
  effective_from,
  is_active,
  interest_enabled,
  day_count_basis,
  created_by,
  updated_by
)
values (
  'c2d00000-0000-0000-0000-000000000115',
  'a0000000-0000-0000-0000-000000000001',
  'c2b00000-0000-0000-0000-000000000115',
  0.18000000,
  0,
  'AFTER_GRACE_ONLY',
  '2026-01-01',
  true,
  true,
  365,
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001'
);
select pg_temp.iac_post_fuel(
  'c2e00000-0000-0000-0000-000000000115',
  'c2c00000-0000-0000-0000-000000000115',
  '2025-12-31',
  36500
);
select is(
  (
    select run_status
    from app_private.run_interest_accrual_for_station(
      'a1000000-0000-0000-0000-000000000002',
      '2026-01-02 12:00:00+05:30',
      'TEST',
      'c2a00000-0000-0000-0000-000000000115',
      10
    )
  ),
  'FAILED'::public.interest_accrual_run_status,
  'trusted station failure is recorded without partial financial effects'
);
select is(
  (
    select result_code
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000115'
  ),
  'IAC_SCHEDULER_FAILURE',
  'scheduler failure uses a stable result code'
);
select ok(
  (
    select error_message =
      'Accrual execution failed; inspect database logs using the request ID.'
      and error_message !~* '(select|insert|update|delete|password|token|secret)'
    from public.interest_accrual_runs
    where request_id =
      'c2a00000-0000-0000-0000-000000000115'
  ),
  'failed-run evidence contains only a sanitized error summary'
);
select is(
  (
    select count(*)::bigint
    from public.interest_accruals
    where credit_account_id =
      'c2c00000-0000-0000-0000-000000000115'
  ),
  0::bigint,
  'failed station work rolls back all account/day evidence atomically'
);

-- Regression interfaces remain present and preserve principal-only credit use.
select has_function(
  'public',
  'post_fuel_credit_transaction',
  array[
    'uuid',
    'uuid',
    'uuid',
    'numeric',
    'uuid',
    'text'
  ],
  'fuel-credit posting interface remains compatible'
);
select has_function(
  'public',
  'post_customer_repayment',
  array[
    'uuid',
    'uuid',
    'numeric',
    'text',
    'uuid',
    'numeric',
    'numeric',
    'uuid',
    'text',
    'text'
  ],
  'repayment interface remains compatible'
);
select has_function(
  'public',
  'get_credit_account_obligations',
  array['uuid'],
  'approved balance interface remains compatible'
);
select is(
  (
    select available_credit_paise
    from app_private.calculate_credit_account_obligations(
      'c2c00000-0000-0000-0000-000000000105'
    )
  ),
  8999999999999963500::bigint,
  'historical interest due still does not consume principal credit'
);

select * from finish();

rollback;
