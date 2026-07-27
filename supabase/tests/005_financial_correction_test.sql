begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

-- Schema, RLS, privileges, and trusted-function boundaries.
select has_table(
  'public',
  'financial_correction_requests',
  'correction request table exists'
);
select has_table(
  'public',
  'financial_correction_events',
  'correction event table exists'
);
select has_table(
  'public',
  'financial_reversals',
  'reversal evidence table exists'
);
select has_table(
  'public',
  'fuel_credit_correction_proposals',
  'typed fuel replacement proposal table exists'
);
select has_table(
  'public',
  'repayment_correction_proposals',
  'typed repayment replacement proposal table exists'
);

select is(
  (
    select count(*)::bigint
    from pg_class as relation
    join pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relname = any (
        array[
          'financial_correction_requests',
          'financial_correction_events',
          'financial_reversals',
          'fuel_credit_correction_proposals',
          'repayment_correction_proposals'
        ]
      )
      and relation.relrowsecurity
      and relation.relforcerowsecurity
  ),
  5::bigint,
  'RLS is enabled and forced on every correction table'
);

select is(
  (
    select count(distinct tablename)::bigint
    from pg_policies
    where schemaname = 'public'
      and tablename = any (
        array[
          'financial_correction_requests',
          'financial_correction_events',
          'financial_reversals',
          'fuel_credit_correction_proposals',
          'repayment_correction_proposals'
        ]
      )
  ),
  5::bigint,
  'every correction table has an explicit select policy'
);

select ok(
  not has_table_privilege(
    'anon',
    'public.financial_correction_requests',
    'select'
  )
  and not has_table_privilege(
    'anon',
    'public.financial_correction_events',
    'select'
  )
  and not has_table_privilege(
    'anon',
    'public.financial_reversals',
    'select'
  ),
  'anonymous has no correction-table access'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.financial_correction_requests',
    'insert'
  )
  and not has_table_privilege(
    'authenticated',
    'public.financial_correction_requests',
    'update'
  )
  and not has_table_privilege(
    'authenticated',
    'public.financial_correction_requests',
    'delete'
  )
  and not has_table_privilege(
    'authenticated',
    'public.financial_correction_events',
    'insert'
  )
  and not has_table_privilege(
    'authenticated',
    'public.financial_reversals',
    'insert'
  ),
  'authenticated clients have no direct correction mutations'
);

select ok(
  not has_table_privilege(
    'service_role',
    'public.financial_correction_requests',
    'select'
  )
  and not has_table_privilege(
    'service_role',
    'public.financial_correction_events',
    'insert'
  )
  and not has_table_privilege(
    'service_role',
    'public.financial_reversals',
    'insert'
  ),
  'service role does not regain raw correction access'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.submit_financial_correction_request(uuid,text,text,text,uuid,uuid,numeric,text,numeric,text,numeric,numeric,uuid,text,text)',
    'execute'
  )
  and has_function_privilege(
    'authenticated',
    'public.get_financial_correction_impact(uuid)',
    'execute'
  )
  and has_function_privilege(
    'authenticated',
    'public.approve_and_execute_financial_correction(uuid,integer)',
    'execute'
  )
  and has_function_privilege(
    'authenticated',
    'public.reject_financial_correction_request(uuid,integer,text)',
    'execute'
  )
  and has_function_privilege(
    'authenticated',
    'public.cancel_financial_correction_request(uuid,integer,text)',
    'execute'
  ),
  'authenticated receives only the five narrow correction RPCs'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'app_private.calculate_financial_correction_impact(uuid)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'app_private.financial_transaction_fingerprint(uuid)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'app_private.assert_financial_reversal_shape()',
    'execute'
  ),
  'private correction helpers are inaccessible'
);

select has_enum(
  'public',
  'financial_correction_action',
  'typed correction-action enum exists'
);
select has_enum(
  'public',
  'financial_correction_status',
  'typed correction-status enum exists'
);
select has_enum(
  'public',
  'financial_correction_reason_category',
  'typed correction-reason enum exists'
);

select is(
  (
    select enumlabel
    from pg_enum
    join pg_type on pg_type.oid = pg_enum.enumtypid
    join pg_namespace on pg_namespace.oid = pg_type.typnamespace
    where pg_namespace.nspname = 'public'
      and pg_type.typname = 'ledger_transaction_type'
      and enumlabel = 'FINANCIAL_REVERSAL'
  ),
  'FINANCIAL_REVERSAL',
  'ledger supports a dedicated reversal transaction type'
);

select ok(
  (
    select count(*) = 8
    from pg_enum
    join pg_type on pg_type.oid = pg_enum.enumtypid
    join pg_namespace on pg_namespace.oid = pg_type.typnamespace
    where pg_namespace.nspname = 'public'
      and pg_type.typname = 'financial_correction_reason_category'
  ),
  'all eight controlled reason categories exist'
);

select ok(
  (
    select count(*) >= 4
    from pg_trigger
    where tgrelid = 'public.financial_correction_requests'::regclass
       or tgrelid = 'public.financial_correction_events'::regclass
       or tgrelid = 'public.financial_reversals'::regclass
  ),
  'request and evidence guards are installed'
);

-- Deterministic fake accounts used only inside this rolled-back test.
create function pg_temp.cor_create_account(
  target_customer_id uuid,
  target_account_id uuid,
  target_station_id uuid,
  target_phone text,
  target_credit_limit_paise bigint
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  station_row public.stations%rowtype;
begin
  select station.*
  into station_row
  from public.stations as station
  where station.id = target_station_id;

  insert into public.customers (
    id,
    organization_id,
    home_station_id,
    first_name,
    last_name,
    display_name,
    phone,
    status,
    created_by,
    updated_by
  )
  values (
    target_customer_id,
    station_row.organization_id,
    target_station_id,
    'Correction',
    'Fixture',
    'Phase 2D correction fixture',
    target_phone,
    'ACTIVE',
    case
      when station_row.organization_id =
        'a0000000-0000-0000-0000-000000000001'
        then '10000000-0000-0000-0000-000000000001'::uuid
      else '10000000-0000-0000-0000-000000000002'::uuid
    end,
    case
      when station_row.organization_id =
        'a0000000-0000-0000-0000-000000000001'
        then '10000000-0000-0000-0000-000000000001'::uuid
      else '10000000-0000-0000-0000-000000000002'::uuid
    end
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
    station_row.organization_id,
    target_credit_limit_paise,
    0.18000000,
    0,
    'AFTER_GRACE_ONLY',
    30,
    case
      when station_row.organization_id =
        'a0000000-0000-0000-0000-000000000001'
        then '10000000-0000-0000-0000-000000000001'::uuid
      else '10000000-0000-0000-0000-000000000002'::uuid
    end,
    case
      when station_row.organization_id =
        'a0000000-0000-0000-0000-000000000001'
        then '10000000-0000-0000-0000-000000000001'::uuid
      else '10000000-0000-0000-0000-000000000002'::uuid
    end
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
    target_account_id,
    station_row.organization_id,
    target_customer_id,
    target_station_id,
    'INR',
    true,
    case
      when station_row.organization_id =
        'a0000000-0000-0000-0000-000000000001'
        then '10000000-0000-0000-0000-000000000001'::uuid
      else '10000000-0000-0000-0000-000000000002'::uuid
    end,
    case
      when station_row.organization_id =
        'a0000000-0000-0000-0000-000000000001'
        then '10000000-0000-0000-0000-000000000001'::uuid
      else '10000000-0000-0000-0000-000000000002'::uuid
    end
  );
end;
$$;

create function pg_temp.cor_start_run(
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

create table pg_temp.phase2d_ids (
  name text primary key,
  id uuid not null
);
grant all on table pg_temp.phase2d_ids to authenticated;

select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000101',
  'd3000000-0000-0000-0000-000000000101',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000101',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000102',
  'd3000000-0000-0000-0000-000000000102',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000102',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000103',
  'd3000000-0000-0000-0000-000000000103',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000103',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000104',
  'd3000000-0000-0000-0000-000000000104',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000104',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000105',
  'd3000000-0000-0000-0000-000000000105',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000105',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000106',
  'd3000000-0000-0000-0000-000000000106',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000106',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000107',
  'd3000000-0000-0000-0000-000000000107',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000107',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000108',
  'd3000000-0000-0000-0000-000000000108',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000108',
  100000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000109',
  'd3000000-0000-0000-0000-000000000109',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000109',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000110',
  'd3000000-0000-0000-0000-000000000110',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000110',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000111',
  'd3000000-0000-0000-0000-000000000111',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000111',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000112',
  'd3000000-0000-0000-0000-000000000112',
  'a1000000-0000-0000-0000-000000000002',
  '+15553000112',
  2500000
);

select ok(
  exists (
    select 1
    from public.role_assignments
    where organization_id =
      'a0000000-0000-0000-0000-000000000001'
      and user_id =
        '10000000-0000-0000-0000-000000000010'
      and role = 'OWNER'
  ),
  'seed supplies a second active owner in Organization A'
);

-- Post isolated originals as Owner A.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
select 'fuel_eligible_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000101',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  200000,
  'd4100000-0000-4000-8000-000000000101',
  'cor-fuel-eligible'
);

insert into pg_temp.phase2d_ids
select 'fuel_partly_repaid_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000102',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  200000,
  'd4100000-0000-4000-8000-000000000102',
  'cor-fuel-partly-repaid'
);
insert into pg_temp.phase2d_ids
select 'fuel_partly_repaid_payment_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000102',
  'a1000000-0000-0000-0000-000000000001',
  50000,
  'PRINCIPAL_ONLY',
  'd4200000-0000-4000-8000-000000000102',
  50000,
  0,
  null,
  'cor-fuel-consumption',
  'CASH'
);

insert into pg_temp.phase2d_ids
select 'fuel_interest_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000103',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  500000,
  'd4100000-0000-4000-8000-000000000103',
  'cor-fuel-interest'
);

insert into pg_temp.phase2d_ids
select 'fuel_replace_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000104',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  100000,
  'd4100000-0000-4000-8000-000000000104',
  'cor-fuel-replace'
);

insert into pg_temp.phase2d_ids
select 'principal_base_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000105',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  300000,
  'd4100000-0000-4000-8000-000000000105',
  'cor-principal-base'
);
insert into pg_temp.phase2d_ids
select 'principal_repayment_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000105',
  'a1000000-0000-0000-0000-000000000001',
  100000,
  'PRINCIPAL_ONLY',
  'd4200000-0000-4000-8000-000000000105',
  100000,
  0,
  null,
  'cor-principal-repayment',
  'CASH'
);

insert into pg_temp.phase2d_ids
select 'interest_base_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000106',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  1000000,
  'd4100000-0000-4000-8000-000000000106',
  'cor-interest-base'
);

insert into pg_temp.phase2d_ids
select 'split_base_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000107',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  1000000,
  'd4100000-0000-4000-8000-000000000107',
  'cor-split-base'
);

insert into pg_temp.phase2d_ids
select 'limit_base_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000108',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  100000,
  'd4100000-0000-4000-8000-000000000108',
  'cor-limit-base'
);
insert into pg_temp.phase2d_ids
select 'limit_repayment_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000108',
  'a1000000-0000-0000-0000-000000000001',
  100000,
  'PRINCIPAL_ONLY',
  'd4200000-0000-4000-8000-000000000108',
  100000,
  0,
  null,
  'cor-limit-repayment',
  'CASH'
);
insert into pg_temp.phase2d_ids
select 'limit_reuse_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000108',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  100000,
  'd4100000-0000-4000-8000-000000000118',
  'cor-limit-reuse'
);

insert into pg_temp.phase2d_ids
select 'dependent_repayment_base_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000109',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  400000,
  'd4100000-0000-4000-8000-000000000109',
  'cor-dependent-repayment-base'
);
insert into pg_temp.phase2d_ids
select 'dependent_repayment_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000109',
  'a1000000-0000-0000-0000-000000000001',
  100000,
  'PRINCIPAL_ONLY',
  'd4200000-0000-4000-8000-000000000109',
  100000,
  0,
  null,
  'cor-dependent-repayment',
  'CASH'
);

insert into pg_temp.phase2d_ids
select 'repayment_replace_base_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000110',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  300000,
  'd4100000-0000-4000-8000-000000000110',
  'cor-repayment-replace-base'
);
insert into pg_temp.phase2d_ids
select 'repayment_replace_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000110',
  'a1000000-0000-0000-0000-000000000001',
  100000,
  'PRINCIPAL_ONLY',
  'd4200000-0000-4000-8000-000000000110',
  100000,
  0,
  null,
  'cor-repayment-replace',
  'CASH'
);

insert into pg_temp.phase2d_ids
select 'interest_charge_base_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000111',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  600000,
  'd4100000-0000-4000-8000-000000000111',
  'cor-interest-charge-base'
);

insert into pg_temp.phase2d_ids
select 'south_fuel_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000112',
  'a1000000-0000-0000-0000-000000000002',
  'af100000-0000-0000-0000-000000000001',
  100000,
  'd4100000-0000-4000-8000-000000000112',
  'cor-south'
);

reset role;

create or replace function pg_temp.cor_submit_reversal(
  target_transaction_id uuid,
  target_idempotency_key uuid,
  target_explanation text
)
returns uuid
language sql
set search_path = ''
as $$
  select request_id
  from public.submit_financial_correction_request(
    target_transaction_id,
    'REVERSAL_ONLY',
    'OPERATIONAL_ERROR',
    target_explanation,
    target_idempotency_key,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null
  );
$$;

create or replace function pg_temp.cor_submit_fuel_replacement(
  target_transaction_id uuid,
  target_idempotency_key uuid,
  target_product_id uuid,
  target_amount_paise bigint,
  target_reference text
)
returns uuid
language sql
set search_path = ''
as $$
  select request_id
  from public.submit_financial_correction_request(
    target_transaction_id,
    'REVERSE_AND_REPLACE',
    'WRONG_AMOUNT',
    'The fuel sale amount was entered incorrectly and needs correction.',
    target_idempotency_key,
    target_product_id,
    target_amount_paise,
    target_reference,
    null,
    null,
    null,
    null,
    null,
    null,
    null
  );
$$;

grant execute on function pg_temp.cor_submit_reversal(uuid, uuid, text)
  to authenticated;
grant execute on function pg_temp.cor_submit_fuel_replacement(
  uuid,
  uuid,
  uuid,
  bigint,
  text
) to authenticated;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
values (
  'fuel_eligible_request',
  pg_temp.cor_submit_reversal(
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_tx'
    ),
    'd5100000-0000-4000-8000-000000000101',
    'Duplicate sale confirmed during the controlled shift reconciliation.'
  )
);
reset role;

-- Approval authorization and an eligible full fuel reversal.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  'P0001',
  'COR_FORBIDDEN',
  'manager cannot approve'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000004',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  'P0001',
  'COR_FORBIDDEN',
  'attendant cannot approve'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000002',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  'P0001',
  'COR_FORBIDDEN',
  'owner cannot approve another organization request'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (
    select reversal_eligible
    from public.get_financial_correction_impact(
      (
        select id from pg_temp.phase2d_ids
        where name = 'fuel_eligible_request'
      )
    )
  ),
  true,
  'eligible fuel reversal preview has no blocker'
);

insert into pg_temp.phase2d_ids
select 'fuel_eligible_reversal', reversal_transaction_id
from public.approve_and_execute_financial_correction(
  (
    select id from pg_temp.phase2d_ids
    where name = 'fuel_eligible_request'
  ),
  1
);

select is(
  (
    select status::text
    from public.financial_correction_requests
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  'APPROVED_AND_EXECUTED',
  'active independent owner approves and executes'
);

select is(
  (
    select version
    from public.financial_correction_requests
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  2,
  'execution advances the optimistic version exactly once'
);

select is(
  (
    select amount_paise
    from public.ledger_transactions
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_tx'
    )
  ),
  200000::bigint,
  'original transaction remains unchanged'
);

select is(
  (
    select original_transaction_id
    from public.financial_reversals
    where reversal_transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_reversal'
    )
  ),
  (
    select id from pg_temp.phase2d_ids
    where name = 'fuel_eligible_tx'
  ),
  'reversal evidence references the original'
);

select is(
  (
    select count(*)::bigint
    from (
      (
        select
          original_entry.account_code,
          case original_entry.direction
            when 'DEBIT' then 'CREDIT'::public.ledger_entry_direction
            else 'DEBIT'::public.ledger_entry_direction
          end as direction,
          original_entry.amount_paise,
          original_entry.currency_code
        from public.ledger_entries as original_entry
        where original_entry.transaction_id = (
          select id from pg_temp.phase2d_ids
          where name = 'fuel_eligible_tx'
        )
        except all
        select
          reversal_entry.account_code,
          reversal_entry.direction,
          reversal_entry.amount_paise,
          reversal_entry.currency_code
        from public.ledger_entries as reversal_entry
        where reversal_entry.transaction_id = (
          select id from pg_temp.phase2d_ids
          where name = 'fuel_eligible_reversal'
        )
      )
    ) as difference
  ),
  0::bigint,
  'reversal entries exactly invert the original'
);

select is(
  (
    select
      sum(amount_paise) filter (where direction = 'DEBIT')
      - sum(amount_paise) filter (where direction = 'CREDIT')
    from public.ledger_entries
    where transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_reversal'
    )
  ),
  0::numeric,
  'reversal ledger balances exactly'
);

select is(
  (
    select business_date
    from public.ledger_transactions
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_reversal'
    )
  ),
  (
    select
      (statement_timestamp() at time zone station.time_zone_name)::date
    from public.stations as station
    where station.id =
      'a1000000-0000-0000-0000-000000000001'
  ),
  'reversal uses the current station-local business date'
);

select is(
  (
    select outstanding_principal_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000101'
    )
  ),
  0::bigint,
  'fuel reversal decreases principal'
);

select is(
  (
    select available_credit_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000101'
    )
  ),
  2500000::bigint,
  'fuel reversal restores available credit'
);

select is(
  (
    select count(*)::bigint
    from public.financial_correction_events
    where request_id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
      and event_type = 'APPROVED_AND_EXECUTED'
  ),
  1::bigint,
  'one approval-success event is recorded'
);

select is(
  (
    select count(*)::bigint
    from public.audit_events
    where request_id = (
      select correlation_id
      from public.financial_correction_requests
      where id = (
        select id from pg_temp.phase2d_ids
        where name = 'fuel_eligible_request'
      )
    )
      and action in (
        'financial_correction.submitted',
        'financial_correction.approved',
        'financial_correction.reversal_executed'
      )
  ),
  3::bigint,
  'submission approval and reversal audit evidence exists'
);

select is(
  (
    select idempotent_replay
    from public.approve_and_execute_financial_correction(
      (
        select id from pg_temp.phase2d_ids
        where name = 'fuel_eligible_request'
      ),
      1
    )
  ),
  true,
  'repeated execution safely replays the terminal result'
);

select is(
  (
    select count(*)::bigint
    from public.financial_reversals
    where original_transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_tx'
    )
  ),
  1::bigint,
  'repeated execution creates exactly one reversal'
);

select throws_ok(
  format(
    'select pg_temp.cor_submit_reversal(%L,%L,%L)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_tx'
    ),
    'd5100000-0000-4000-8000-000000000119',
    'A second correction must not reverse the same original again.'
  ),
  'P0001',
  'COR_ALREADY_REVERSED',
  'a second reversal request is rejected'
);

reset role;
insert into pg_temp.phase2d_ids
select 'fuel_interest_accrual_tx', posted.ledger_transaction_id
from app_private.post_interest_for_account_date(
  pg_temp.cor_start_run(
    'a1000000-0000-0000-0000-000000000001',
    (
      select transaction.business_date
      from public.ledger_transactions as transaction
      where transaction.id = (
        select id from pg_temp.phase2d_ids
        where name = 'fuel_interest_tx'
      )
    )
  ),
  'd3000000-0000-0000-0000-000000000103',
  (
    select transaction.business_date
    from public.ledger_transactions as transaction
    where transaction.id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_interest_tx'
    )
  )
) as posted;

-- Fuel dependency blockers.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
values (
  'fuel_partly_repaid_request',
  pg_temp.cor_submit_reversal(
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_partly_repaid_tx'
    ),
    'd5100000-0000-4000-8000-000000000120',
    'The sale is wrong but some principal has already been repaid.'
  )
);

select ok(
  array_position(
    (
      select blocking_error_codes
      from public.get_financial_correction_impact(
        (
          select id from pg_temp.phase2d_ids
          where name = 'fuel_partly_repaid_request'
        )
      )
    ),
    'COR_PRINCIPAL_ALREADY_REPAID'
  ) is not null,
  'partly repaid fuel lot reports the stable dependency blocker'
);

insert into pg_temp.phase2d_ids
values (
  'fuel_interest_request',
  pg_temp.cor_submit_reversal(
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_interest_tx'
    ),
    'd5100000-0000-4000-8000-000000000121',
    'The sale is wrong but interest evidence already references it.'
  )
);

select ok(
  array_position(
    (
      select blocking_error_codes
      from public.get_financial_correction_impact(
        (
          select id from pg_temp.phase2d_ids
          where name = 'fuel_interest_request'
        )
      )
    ),
    'COR_DEPENDENT_INTEREST_EXISTS'
  ) is not null,
  'fuel sale with interest components reports the stable blocker'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_partly_repaid_request'
    )
  ),
  'P0001',
  'COR_PRINCIPAL_ALREADY_REPAID',
  'approval recalculates and blocks a partly repaid sale'
);

select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_interest_request'
    )
  ),
  'P0001',
  'COR_DEPENDENT_INTEREST_EXISTS',
  'approval blocks a fuel sale with dependent interest'
);

select is(
  (
    select count(*)::bigint
    from public.financial_reversals
    where original_transaction_id in (
      select id from pg_temp.phase2d_ids
      where name in ('fuel_partly_repaid_tx', 'fuel_interest_tx')
    )
  ),
  0::bigint,
  'blocked fuel reversals leave no partial reversal evidence'
);

-- Atomic fuel reverse-and-replace.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
values (
  'fuel_replace_request',
  pg_temp.cor_submit_fuel_replacement(
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_replace_tx'
    ),
    'd5100000-0000-4000-8000-000000000122',
    'af100000-0000-0000-0000-000000000002',
    120000,
    'cor-fuel-corrected'
  )
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,2)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_replace_request'
    )
  ),
  'P0001',
  'COR_VERSION_CONFLICT',
  'expected-version mismatch is rejected'
);

insert into pg_temp.phase2d_ids
select 'fuel_replace_reversal', reversal_transaction_id
from public.approve_and_execute_financial_correction(
  (
    select id from pg_temp.phase2d_ids
    where name = 'fuel_replace_request'
  ),
  1
);
insert into pg_temp.phase2d_ids
select 'fuel_replace_replacement', replacement_transaction_id
from public.financial_correction_requests
where id = (
  select id from pg_temp.phase2d_ids
  where name = 'fuel_replace_request'
);

select is(
  (
    select amount_paise
    from public.ledger_transactions
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_replace_replacement'
    )
  ),
  120000::bigint,
  'fuel replacement posts the corrected amount'
);

select is(
  (
    select fuel_product_id
    from public.fuel_credit_sales
    where transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_replace_replacement'
    )
  ),
  'af100000-0000-0000-0000-000000000002'::uuid,
  'fuel replacement uses the typed corrected product'
);

select ok(
  (
    select
      original_transaction_id = (
        select id from pg_temp.phase2d_ids
        where name = 'fuel_replace_tx'
      )
      and reversal_transaction_id = (
        select id from pg_temp.phase2d_ids
        where name = 'fuel_replace_reversal'
      )
      and replacement_transaction_id = (
        select id from pg_temp.phase2d_ids
        where name = 'fuel_replace_replacement'
      )
    from public.financial_reversals
    where request_id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_replace_request'
    )
  ),
  'original reversal and fuel replacement are permanently linked'
);

select is(
  (
    select outstanding_principal_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000104'
    )
  ),
  120000::bigint,
  'final principal reflects only the corrected fuel sale'
);

select is(
  (
    select count(*)::bigint
    from public.idempotency_keys
    where response_transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_replace_replacement'
    )
      and operation = 'FUEL_CREDIT_POSTING'
      and status = 'COMPLETED'
  ),
  1::bigint,
  'fuel replacement reuses normal Phase 2A evidence'
);

-- Create deterministic interest evidence only for dependency fixtures.
reset role;
insert into pg_temp.phase2d_ids
select 'interest_repayment_charge_tx', posted.ledger_transaction_id
from app_private.post_interest_for_account_date(
  pg_temp.cor_start_run(
    'a1000000-0000-0000-0000-000000000001',
    (
      select transaction.business_date
      from public.ledger_transactions as transaction
      where transaction.id = (
        select id from pg_temp.phase2d_ids
        where name = 'interest_base_tx'
      )
    )
  ),
  'd3000000-0000-0000-0000-000000000106',
  (
    select transaction.business_date
    from public.ledger_transactions as transaction
    where transaction.id = (
      select id from pg_temp.phase2d_ids
      where name = 'interest_base_tx'
    )
  )
) as posted;

insert into pg_temp.phase2d_ids
select 'split_charge_tx', posted.ledger_transaction_id
from app_private.post_interest_for_account_date(
  pg_temp.cor_start_run(
    'a1000000-0000-0000-0000-000000000001',
    (
      select transaction.business_date
      from public.ledger_transactions as transaction
      where transaction.id = (
        select id from pg_temp.phase2d_ids
        where name = 'split_base_tx'
      )
    )
  ),
  'd3000000-0000-0000-0000-000000000107',
  (
    select transaction.business_date
    from public.ledger_transactions as transaction
    where transaction.id = (
      select id from pg_temp.phase2d_ids
      where name = 'split_base_tx'
    )
  )
) as posted;

insert into pg_temp.phase2d_ids
select 'interest_charge_tx', posted.ledger_transaction_id
from app_private.post_interest_for_account_date(
  pg_temp.cor_start_run(
    'a1000000-0000-0000-0000-000000000001',
    (
      select transaction.business_date
      from public.ledger_transactions as transaction
      where transaction.id = (
        select id from pg_temp.phase2d_ids
        where name = 'interest_charge_base_tx'
      )
    )
  ),
  'd3000000-0000-0000-0000-000000000111',
  (
    select transaction.business_date
    from public.ledger_transactions as transaction
    where transaction.id = (
      select id from pg_temp.phase2d_ids
      where name = 'interest_charge_base_tx'
    )
  )
) as posted;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
select 'interest_repayment_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000106',
  'a1000000-0000-0000-0000-000000000001',
  (
    select outstanding_interest_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000106'
    )
  ),
  'INTEREST_ONLY',
  'd4200000-0000-4000-8000-000000000106',
  0,
  (
    select outstanding_interest_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000106'
    )
  ),
  null,
  'cor-interest-repayment',
  'CASH'
);

insert into pg_temp.phase2d_ids
select 'split_repayment_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000107',
  'a1000000-0000-0000-0000-000000000001',
  100100,
  'SPLIT',
  'd4200000-0000-4000-8000-000000000107',
  100000,
  100,
  null,
  'cor-split-repayment',
  'CASH'
);

reset role;

-- This later accrual used principal reduced by the repayment on account 109.
insert into pg_temp.phase2d_ids
select 'dependent_repayment_accrual_tx', posted.ledger_transaction_id
from app_private.post_interest_for_account_date(
  pg_temp.cor_start_run(
    'a1000000-0000-0000-0000-000000000001',
    (
      select transaction.business_date
      from public.ledger_transactions as transaction
      where transaction.id = (
        select id from pg_temp.phase2d_ids
        where name = 'dependent_repayment_tx'
      )
    )
  ),
  'd3000000-0000-0000-0000-000000000109',
  (
    select transaction.business_date
    from public.ledger_transactions as transaction
    where transaction.id = (
      select id from pg_temp.phase2d_ids
      where name = 'dependent_repayment_tx'
    )
  )
) as posted;

create or replace function pg_temp.cor_submit_reversal(
  target_transaction_id uuid,
  target_idempotency_key uuid,
  target_explanation text
)
returns uuid
language sql
set search_path = ''
as $$
  select request_id
  from public.submit_financial_correction_request(
    target_transaction_id,
    'REVERSAL_ONLY',
    'OPERATIONAL_ERROR',
    target_explanation,
    target_idempotency_key,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null
  );
$$;

create or replace function pg_temp.cor_submit_fuel_replacement(
  target_transaction_id uuid,
  target_idempotency_key uuid,
  target_product_id uuid,
  target_amount_paise bigint,
  target_reference text
)
returns uuid
language sql
set search_path = ''
as $$
  select request_id
  from public.submit_financial_correction_request(
    target_transaction_id,
    'REVERSE_AND_REPLACE',
    'WRONG_AMOUNT',
    'The fuel sale amount was entered incorrectly and needs correction.',
    target_idempotency_key,
    target_product_id,
    target_amount_paise,
    target_reference,
    null,
    null,
    null,
    null,
    null,
    null,
    null
  );
$$;

create function pg_temp.cor_submit_repayment_replacement(
  target_transaction_id uuid,
  target_idempotency_key uuid,
  target_total_paise bigint,
  target_mode text,
  target_principal_paise bigint,
  target_interest_paise bigint,
  target_driver_id uuid,
  target_reference text
)
returns uuid
language sql
set search_path = ''
as $$
  select request_id
  from public.submit_financial_correction_request(
    target_transaction_id,
    'REVERSE_AND_REPLACE',
    'WRONG_REPAYMENT_ALLOCATION',
    'The repayment allocation was entered incorrectly and needs correction.',
    target_idempotency_key,
    null,
    null,
    null,
    target_total_paise,
    target_mode,
    target_principal_paise,
    target_interest_paise,
    target_driver_id,
    target_reference,
    'CASH'
  );
$$;

grant execute on function pg_temp.cor_submit_reversal(uuid, uuid, text)
  to authenticated;
grant execute on function pg_temp.cor_submit_fuel_replacement(
  uuid,
  uuid,
  uuid,
  bigint,
  text
) to authenticated;
grant execute on function pg_temp.cor_submit_repayment_replacement(
  uuid,
  uuid,
  bigint,
  text,
  bigint,
  bigint,
  uuid,
  text
) to authenticated;

-- Request authorization and idempotency.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (
    select requester_role::text
    from public.financial_correction_requests
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  'MANAGER',
  'assigned manager submits a correction in the assigned station'
);

select is(
  pg_temp.cor_submit_reversal(
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_tx'
    ),
    'd5100000-0000-4000-8000-000000000101',
    'Duplicate sale confirmed during the controlled shift reconciliation.'
  ),
  (
    select id from pg_temp.phase2d_ids
    where name = 'fuel_eligible_request'
  ),
  'same submission idempotency key and payload replays'
);

select throws_ok(
  format(
    'select pg_temp.cor_submit_reversal(%L,%L,%L)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_tx'
    ),
    'd5100000-0000-4000-8000-000000000101',
    'A materially different explanation is intentionally conflicting.'
  ),
  'P0001',
  'COR_IDEMPOTENCY_CONFLICT',
  'changed proposal under the same key conflicts deterministically'
);

select throws_ok(
  format(
    'select pg_temp.cor_submit_reversal(%L,%L,%L)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'south_fuel_tx'
    ),
    'd5100000-0000-4000-8000-000000000112',
    'Manager is not assigned to the station holding this transaction.'
  ),
  'P0001',
  'COR_FORBIDDEN',
  'manager cannot submit outside the assigned station'
);

select throws_ok(
  format(
    $sql$
      select * from public.submit_financial_correction_request(
        %L,'REVERSAL_ONLY','OTHER','short',
        'd5100000-0000-4000-8000-000000000113',
        null,null,null,null,null,null,null,null,null,null
      )
    $sql$,
    (
      select id from pg_temp.phase2d_ids
      where name = 'south_fuel_tx'
    )
  ),
  'P0001',
  'COR_INVALID_REASON',
  'mandatory reason minimum length is enforced'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000004',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select pg_temp.cor_submit_reversal(%L,%L,%L)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'south_fuel_tx'
    ),
    'd5100000-0000-4000-8000-000000000114',
    'Attendants are not permitted to request financial corrections.'
  ),
  'P0001',
  'COR_FORBIDDEN',
  'attendant cannot submit'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000005',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select pg_temp.cor_submit_reversal(%L,%L,%L)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'south_fuel_tx'
    ),
    'd5100000-0000-4000-8000-000000000115',
    'Customers are not permitted to request financial corrections.'
  ),
  'P0001',
  'COR_FORBIDDEN',
  'customer cannot submit'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000006',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select pg_temp.cor_submit_reversal(%L,%L,%L)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'south_fuel_tx'
    ),
    'd5100000-0000-4000-8000-000000000116',
    'Drivers are not permitted to request financial corrections.'
  ),
  'P0001',
  'COR_FORBIDDEN',
  'driver cannot submit'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000008',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select pg_temp.cor_submit_reversal(%L,%L,%L)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_partly_repaid_tx'
    ),
    'd5100000-0000-4000-8000-000000000117',
    'Revoked managers are not permitted to submit corrections.'
  ),
  'P0001',
  'COR_FORBIDDEN',
  'revoked manager cannot submit'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000002',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select pg_temp.cor_submit_reversal(%L,%L,%L)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_partly_repaid_tx'
    ),
    'd5100000-0000-4000-8000-000000000118',
    'Cross tenant owners are not permitted to submit corrections.'
  ),
  'P0001',
  'COR_FORBIDDEN',
  'cross-tenant owner cannot submit'
);

reset role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', 'anon', true);
select throws_ok(
  $$
    select * from public.approve_and_execute_financial_correction(
      'd5900000-0000-4000-8000-000000000001',
      1
    )
  $$,
  '42501',
  null,
  'anonymous execution is denied at the privilege boundary'
);

reset role;

-- Repayment reversal and correction requests.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
values
  (
    'principal_repayment_request',
    pg_temp.cor_submit_reversal(
      (
        select id from pg_temp.phase2d_ids
        where name = 'principal_repayment_tx'
      ),
      'd5100000-0000-4000-8000-000000000201',
      'The principal repayment was duplicated during receipt entry.'
    )
  ),
  (
    'interest_repayment_request',
    pg_temp.cor_submit_reversal(
      (
        select id from pg_temp.phase2d_ids
        where name = 'interest_repayment_tx'
      ),
      'd5100000-0000-4000-8000-000000000202',
      'The interest repayment was duplicated during receipt entry.'
    )
  ),
  (
    'split_repayment_request',
    pg_temp.cor_submit_reversal(
      (
        select id from pg_temp.phase2d_ids
        where name = 'split_repayment_tx'
      ),
      'd5100000-0000-4000-8000-000000000203',
      'The split repayment was duplicated during receipt entry.'
    )
  ),
  (
    'limit_repayment_request',
    pg_temp.cor_submit_reversal(
      (
        select id from pg_temp.phase2d_ids
        where name = 'limit_repayment_tx'
      ),
      'd5100000-0000-4000-8000-000000000204',
      'The repayment release was already reused by a later fuel sale.'
    )
  ),
  (
    'dependent_repayment_request',
    pg_temp.cor_submit_reversal(
      (
        select id from pg_temp.phase2d_ids
        where name = 'dependent_repayment_tx'
      ),
      'd5100000-0000-4000-8000-000000000205',
      'A later interest calculation used the reduced principal balance.'
    )
  );

select ok(
  array_position(
    (
      select blocking_error_codes
      from public.get_financial_correction_impact(
        (
          select id from pg_temp.phase2d_ids
          where name = 'limit_repayment_request'
        )
      )
    ),
    'COR_REVERSAL_EXCEEDS_CREDIT_LIMIT'
  ) is not null,
  'repayment reversal reports credit-limit restoration blocker'
);

select ok(
  array_position(
    (
      select blocking_error_codes
      from public.get_financial_correction_impact(
        (
          select id from pg_temp.phase2d_ids
          where name = 'dependent_repayment_request'
        )
      )
    ),
    'COR_DEPENDENT_INTEREST_EXISTS'
  ) is not null,
  'repayment reversal reports later-interest dependency blocker'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
select 'principal_repayment_reversal', reversal_transaction_id
from public.approve_and_execute_financial_correction(
  (
    select id from pg_temp.phase2d_ids
    where name = 'principal_repayment_request'
  ),
  1
);
insert into pg_temp.phase2d_ids
select 'interest_repayment_reversal', reversal_transaction_id
from public.approve_and_execute_financial_correction(
  (
    select id from pg_temp.phase2d_ids
    where name = 'interest_repayment_request'
  ),
  1
);
insert into pg_temp.phase2d_ids
select 'split_repayment_reversal', reversal_transaction_id
from public.approve_and_execute_financial_correction(
  (
    select id from pg_temp.phase2d_ids
    where name = 'split_repayment_request'
  ),
  1
);

select is(
  (
    select outstanding_principal_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000105'
    )
  ),
  300000::bigint,
  'principal repayment reversal exactly restores principal'
);

select is(
  (
    select outstanding_interest_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000106'
    )
  ),
  (
    select posted_interest_paise
    from public.interest_accruals
    where ledger_transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'interest_repayment_charge_tx'
    )
  ),
  'interest repayment reversal exactly restores interest'
);

select ok(
  (
    select
      outstanding_principal_paise = 1000000
      and outstanding_interest_paise = (
        select posted_interest_paise
        from public.interest_accruals
        where ledger_transaction_id = (
          select id from pg_temp.phase2d_ids
          where name = 'split_charge_tx'
        )
      )
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000107'
    )
  ),
  'split repayment reversal restores both obligation components'
);

select is(
  (
    select available_credit_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000105'
    )
  ),
  2200000::bigint,
  'principal restoration updates available credit'
);

reset role;
select is(
  (
    select source_remaining_principal_paise
    from app_private.principal_lots_as_of(
      'd3000000-0000-0000-0000-000000000105',
      (
        select business_date
        from public.ledger_transactions
        where id = (
          select id from pg_temp.phase2d_ids
          where name = 'principal_repayment_reversal'
        )
      )
    )
    where source_transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'principal_base_tx'
    )
  ),
  300000::bigint,
  'correction-aware FIFO restores the original principal lot'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'limit_repayment_request'
    )
  ),
  'P0001',
  'COR_REVERSAL_EXCEEDS_CREDIT_LIMIT',
  'repayment reversal that exceeds the credit limit is blocked'
);

select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'dependent_repayment_request'
    )
  ),
  'P0001',
  'COR_DEPENDENT_INTEREST_EXISTS',
  'repayment reversal with later interest is blocked'
);

select is(
  (
    select count(*)::bigint
    from public.financial_reversals
    where original_transaction_id in (
      select id from pg_temp.phase2d_ids
      where name in ('limit_repayment_tx', 'dependent_repayment_tx')
    )
  ),
  0::bigint,
  'blocked repayment reversals leave no partial evidence'
);

-- Invalid repayment replacement and self approval do not create effects.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  format(
    $sql$
      select pg_temp.cor_submit_repayment_replacement(
        %L,%L,80000,'PRINCIPAL_ONLY',80000,0,%L,%L
      )
    $sql$,
    (
      select id from pg_temp.phase2d_ids
      where name = 'repayment_replace_tx'
    ),
    'd5100000-0000-4000-8000-000000000206',
    'a4000000-0000-0000-0000-000000000001',
    'cor-invalid-driver'
  ),
  'P0001',
  'COR_INVALID_DRIVER',
  'replacement driver must belong to the same customer'
);

insert into pg_temp.phase2d_ids
values (
  'repayment_overpay_request',
  pg_temp.cor_submit_repayment_replacement(
    (
      select id from pg_temp.phase2d_ids
      where name = 'repayment_replace_tx'
    ),
    'd5100000-0000-4000-8000-000000000207',
    400000,
    'PRINCIPAL_ONLY',
    400000,
    0,
    null,
    'cor-overpay'
  )
);

select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'repayment_overpay_request'
    )
  ),
  'P0001',
  'COR_SELF_APPROVAL_FORBIDDEN',
  'requester cannot approve their own request'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'repayment_overpay_request'
    )
  ),
  'P0001',
  'COR_REPLACEMENT_ALLOCATION_INVALID',
  'replacement overpayment is rejected'
);

select is(
  (
    select count(*)::bigint
    from public.financial_reversals
    where request_id = (
      select id from pg_temp.phase2d_ids
      where name = 'repayment_overpay_request'
    )
  ),
  0::bigint,
  'failed repayment replacement rolls the reversal back'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select * from public.cancel_financial_correction_request(
  (
    select id from pg_temp.phase2d_ids
    where name = 'repayment_overpay_request'
  ),
  1,
  'The invalid replacement proposal is withdrawn for resubmission.'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
values (
  'repayment_replace_request',
  pg_temp.cor_submit_repayment_replacement(
    (
      select id from pg_temp.phase2d_ids
      where name = 'repayment_replace_tx'
    ),
    'd5100000-0000-4000-8000-000000000208',
    80000,
    'PRINCIPAL_ONLY',
    80000,
    0,
    null,
    'cor-repayment-corrected'
  )
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
select 'repayment_replace_reversal', reversal_transaction_id
from public.approve_and_execute_financial_correction(
  (
    select id from pg_temp.phase2d_ids
    where name = 'repayment_replace_request'
  ),
  1
);
insert into pg_temp.phase2d_ids
select 'repayment_replace_replacement', replacement_transaction_id
from public.financial_correction_requests
where id = (
  select id from pg_temp.phase2d_ids
  where name = 'repayment_replace_request'
);

select is(
  (
    select outstanding_principal_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000110'
    )
  ),
  220000::bigint,
  'corrected repayment leaves only the replacement allocation effect'
);

select is(
  (
    select total_amount_paise
    from public.customer_repayments
    where transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'repayment_replace_replacement'
    )
  ),
  80000::bigint,
  'typed repayment replacement posts the corrected total'
);

select is(
  (
    select amount_paise
    from public.repayment_allocations
    where repayment_id = (
      select id
      from public.customer_repayments
      where transaction_id = (
        select id from pg_temp.phase2d_ids
        where name = 'repayment_replace_replacement'
      )
    )
      and component = 'PRINCIPAL'
  ),
  80000::bigint,
  'typed repayment replacement posts the corrected allocation'
);

select ok(
  (
    select
      original_transaction_id = (
        select id from pg_temp.phase2d_ids
        where name = 'repayment_replace_tx'
      )
      and reversal_transaction_id = (
        select id from pg_temp.phase2d_ids
        where name = 'repayment_replace_reversal'
      )
      and replacement_transaction_id = (
        select id from pg_temp.phase2d_ids
        where name = 'repayment_replace_replacement'
      )
    from public.financial_reversals
    where request_id = (
      select id from pg_temp.phase2d_ids
      where name = 'repayment_replace_request'
    )
  ),
  'original reversal and repayment replacement are linked'
);

select is(
  (
    select count(*)::bigint
    from public.idempotency_keys
    where response_transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'repayment_replace_replacement'
    )
      and operation = 'CUSTOMER_REPAYMENT'
      and status = 'COMPLETED'
  ),
  1::bigint,
  'repayment replacement reuses normal Phase 2B evidence'
);

-- Interest-only and split repayment replacements use the same typed path.
reset role;
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000114',
  'd3000000-0000-0000-0000-000000000114',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000114',
  2500000
);
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000115',
  'd3000000-0000-0000-0000-000000000115',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000115',
  2500000
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
select 'interest_correction_base_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000114',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  1000000,
  'd4100000-0000-4000-8000-000000000114',
  'cor-interest-correction-base'
);
insert into pg_temp.phase2d_ids
select 'split_correction_base_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000115',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  1000000,
  'd4100000-0000-4000-8000-000000000115',
  'cor-split-correction-base'
);

reset role;
insert into pg_temp.phase2d_ids
select 'interest_correction_charge_tx', posted.ledger_transaction_id
from app_private.post_interest_for_account_date(
  pg_temp.cor_start_run(
    'a1000000-0000-0000-0000-000000000001',
    (
      select business_date from public.ledger_transactions
      where id = (
        select id from pg_temp.phase2d_ids
        where name = 'interest_correction_base_tx'
      )
    )
  ),
  'd3000000-0000-0000-0000-000000000114',
  (
    select business_date from public.ledger_transactions
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'interest_correction_base_tx'
    )
  )
) as posted;
insert into pg_temp.phase2d_ids
select 'split_correction_charge_tx', posted.ledger_transaction_id
from app_private.post_interest_for_account_date(
  pg_temp.cor_start_run(
    'a1000000-0000-0000-0000-000000000001',
    (
      select business_date from public.ledger_transactions
      where id = (
        select id from pg_temp.phase2d_ids
        where name = 'split_correction_base_tx'
      )
    )
  ),
  'd3000000-0000-0000-0000-000000000115',
  (
    select business_date from public.ledger_transactions
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'split_correction_base_tx'
    )
  )
) as posted;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
select 'interest_correction_original_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000114',
  'a1000000-0000-0000-0000-000000000001',
  (
    select outstanding_interest_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000114'
    )
  ),
  'INTEREST_ONLY',
  'd4200000-0000-4000-8000-000000000114',
  0,
  (
    select outstanding_interest_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000114'
    )
  ),
  null,
  'cor-interest-correction-original',
  'CASH'
);
insert into pg_temp.phase2d_ids
select 'split_correction_original_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000115',
  'a1000000-0000-0000-0000-000000000001',
  100100,
  'SPLIT',
  'd4200000-0000-4000-8000-000000000115',
  100000,
  100,
  null,
  'cor-split-correction-original',
  'CASH'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
values
  (
    'interest_correction_request',
    pg_temp.cor_submit_repayment_replacement(
      (
        select id from pg_temp.phase2d_ids
        where name = 'interest_correction_original_tx'
      ),
      'd5100000-0000-4000-8000-000000000216',
      200,
      'INTEREST_ONLY',
      0,
      200,
      null,
      'cor-interest-corrected'
    )
  ),
  (
    'split_correction_request',
    pg_temp.cor_submit_repayment_replacement(
      (
        select id from pg_temp.phase2d_ids
        where name = 'split_correction_original_tx'
      ),
      'd5100000-0000-4000-8000-000000000217',
      80080,
      'SPLIT',
      80000,
      80,
      null,
      'cor-split-corrected'
    )
  );

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
select 'interest_correction_replacement', replacement_transaction_id
from public.approve_and_execute_financial_correction(
  (
    select id from pg_temp.phase2d_ids
    where name = 'interest_correction_request'
  ),
  1
);
insert into pg_temp.phase2d_ids
select 'split_correction_replacement', replacement_transaction_id
from public.approve_and_execute_financial_correction(
  (
    select id from pg_temp.phase2d_ids
    where name = 'split_correction_request'
  ),
  1
);

select is(
  (
    select outstanding_interest_paise
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000114'
    )
  ),
  (
    select posted_interest_paise - 200
    from public.interest_accruals
    where ledger_transaction_id = (
      select id from pg_temp.phase2d_ids
      where name = 'interest_correction_charge_tx'
    )
  ),
  'interest-only corrected replacement yields expected interest due'
);

select is(
  (
    select amount_paise
    from public.repayment_allocations
    where repayment_id = (
      select id from public.customer_repayments
      where transaction_id = (
        select id from pg_temp.phase2d_ids
        where name = 'interest_correction_replacement'
      )
    )
      and component = 'INTEREST'
  ),
  200::bigint,
  'interest-only correction posts the typed replacement allocation'
);

select ok(
  (
    select
      count(*) = 2
      and sum(amount_paise) = 80080
    from public.repayment_allocations
    where repayment_id = (
      select id from public.customer_repayments
      where transaction_id = (
        select id from pg_temp.phase2d_ids
        where name = 'split_correction_replacement'
      )
    )
  ),
  'split correction posts exactly two balanced allocation components'
);

select ok(
  (
    select
      outstanding_principal_paise = 920000
      and outstanding_interest_paise = (
        select posted_interest_paise - 80
        from public.interest_accruals
        where ledger_transaction_id = (
          select id from pg_temp.phase2d_ids
          where name = 'split_correction_charge_tx'
        )
      )
    from public.get_credit_account_obligations(
      'd3000000-0000-0000-0000-000000000115'
    )
  ),
  'split corrected replacement yields the expected final obligations'
);

-- Interest charge corrections are accepted for review but never executed.
reset role;
insert into pg_temp.phase2d_ids
select 'interest_charge_later_tx', posted.ledger_transaction_id
from app_private.post_interest_for_account_date(
  pg_temp.cor_start_run(
    'a1000000-0000-0000-0000-000000000001',
    (
      select transaction.business_date + 1
      from public.ledger_transactions as transaction
      where transaction.id = (
        select id from pg_temp.phase2d_ids
        where name = 'interest_charge_tx'
      )
    )
  ),
  'd3000000-0000-0000-0000-000000000111',
  (
    select transaction.business_date + 1
    from public.ledger_transactions as transaction
    where transaction.id = (
      select id from pg_temp.phase2d_ids
      where name = 'interest_charge_tx'
    )
  )
) as posted;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
values (
  'interest_charge_request',
  pg_temp.cor_submit_reversal(
    (
      select id from pg_temp.phase2d_ids
      where name = 'interest_charge_tx'
    ),
    'd5100000-0000-4000-8000-000000000209',
    'The generated interest charge has been flagged for governed review.'
  )
);

insert into pg_temp.phase2d_ids
values (
  'paid_interest_charge_request',
  pg_temp.cor_submit_reversal(
    (
      select id from pg_temp.phase2d_ids
      where name = 'interest_repayment_charge_tx'
    ),
    'd5100000-0000-4000-8000-000000000210',
    'The paid interest charge has been flagged for governed review.'
  )
);

select ok(
  array_position(
    (
      select blocking_error_codes
      from public.get_financial_correction_impact(
        (
          select id from pg_temp.phase2d_ids
          where name = 'interest_charge_request'
        )
      )
    ),
    'COR_INTEREST_REVERSAL_UNSUPPORTED'
  ) is not null,
  'interest reversal reports the explicit unsupported blocker'
);

select ok(
  array_position(
    (
      select blocking_error_codes
      from public.get_financial_correction_impact(
        (
          select id from pg_temp.phase2d_ids
          where name = 'interest_charge_request'
        )
      )
    ),
    'COR_LATER_ACCRUAL_DEPENDS_ON_CHARGE'
  ) is not null,
  'interest reversal reports later cumulative-accrual dependency'
);

select ok(
  array_position(
    (
      select blocking_error_codes
      from public.get_financial_correction_impact(
        (
          select id from pg_temp.phase2d_ids
          where name = 'paid_interest_charge_request'
        )
      )
    ),
    'COR_INTEREST_ALREADY_PAID'
  ) is not null,
  'paid interest charge reports the paid-interest blocker'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'interest_charge_request'
    )
  ),
  'P0001',
  'COR_LATER_ACCRUAL_DEPENDS_ON_CHARGE',
  'later-dependent interest charge cannot execute'
);

select is(
  (
    select count(*)::bigint
    from public.interest_accruals
    where credit_account_id =
      'd3000000-0000-0000-0000-000000000111'
  ),
  2::bigint,
  'failed interest reversal does not recreate or duplicate accruals'
);

select ok(
  (
    select bool_and(
      closing_fractional_carry_paise
        = cumulative_raw_interest_paise
          - cumulative_posted_interest_paise
    )
    from public.interest_accruals
    where credit_account_id =
      'd3000000-0000-0000-0000-000000000111'
  ),
  'failed interest reversal preserves fractional-carry equations'
);

-- Explicit unsupported interest charge with no paid/later dependency.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
values (
  'clean_interest_charge_request',
  pg_temp.cor_submit_reversal(
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_interest_accrual_tx'
    ),
    'd5100000-0000-4000-8000-000000000211',
    'This isolated interest charge has been flagged for governed review.'
  )
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'clean_interest_charge_request'
    )
  ),
  'P0001',
  'COR_INTEREST_REVERSAL_UNSUPPORTED',
  'isolated interest reversal returns the explicit stable blocker'
);

-- Rejection and cancellation are terminal and append-only.
select * from public.reject_financial_correction_request(
  (
    select id from pg_temp.phase2d_ids
    where name = 'fuel_partly_repaid_request'
  ),
  1,
  'The request is rejected because principal has already been consumed.'
);

select is(
  (
    select status::text
    from public.financial_correction_requests
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_partly_repaid_request'
    )
  ),
  'REJECTED',
  'active owner rejects a pending request with a reason'
);

select is(
  (
    select count(*)::bigint
    from public.financial_correction_events
    where request_id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_partly_repaid_request'
    )
      and event_type = 'REJECTED'
  ),
  1::bigint,
  'rejection creates one immutable state event'
);

select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,2)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_partly_repaid_request'
    )
  ),
  'P0001',
  'COR_REQUEST_NOT_PENDING',
  'rejected request cannot execute'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select * from public.cancel_financial_correction_request(
  (
    select id from pg_temp.phase2d_ids
    where name = 'fuel_interest_request'
  ),
  1,
  'The requester withdraws this case pending a broader dependency review.'
);

select is(
  (
    select status::text
    from public.financial_correction_requests
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_interest_request'
    )
  ),
  'CANCELLED',
  'original requester cancels a pending request'
);

select is(
  (
    select count(*)::bigint
    from public.financial_correction_events
    where request_id = (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_interest_request'
    )
      and event_type = 'CANCELLED'
  ),
  1::bigint,
  'cancellation creates one immutable state event'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,2)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_interest_request'
    )
  ),
  'P0001',
  'COR_REQUEST_NOT_PENDING',
  'cancelled request cannot execute'
);

-- South-station owner request proves self-approval and station RLS.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into pg_temp.phase2d_ids
values (
  'south_owner_request',
  pg_temp.cor_submit_reversal(
    (
      select id from pg_temp.phase2d_ids
      where name = 'south_fuel_tx'
    ),
    'd5100000-0000-4000-8000-000000000212',
    'The owner opened this south-station request for independent review.'
  )
);

select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'south_owner_request'
    )
  ),
  'P0001',
  'COR_SELF_APPROVAL_FORBIDDEN',
  'owner self-approval is impossible'
);

select * from public.cancel_financial_correction_request(
  (
    select id from pg_temp.phase2d_ids
    where name = 'south_owner_request'
  ),
  1,
  'The owner withdraws this test request before independent approval.'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select is(
  (
    select count(*)::bigint
    from public.financial_correction_requests
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'south_owner_request'
    )
  ),
  0::bigint,
  'north-station manager cannot read a south-station request'
);

-- Replacement becoming invalid after preview rolls back the reversal.
reset role;
insert into public.fuel_products (
  id,
  organization_id,
  station_id,
  product_code,
  display_name,
  is_active,
  currency_code,
  created_by,
  updated_by
)
values (
  'df100000-0000-0000-0000-000000000001',
  'a0000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000002',
  'COR_TEST',
  'Correction test product',
  true,
  'INR',
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
values (
  'invalid_fuel_replace_request',
  pg_temp.cor_submit_fuel_replacement(
    (
      select id from pg_temp.phase2d_ids
      where name = 'south_fuel_tx'
    ),
    'd5100000-0000-4000-8000-000000000213',
    'df100000-0000-0000-0000-000000000001',
    90000,
    'cor-stale-product'
  )
);

select is(
  (
    select replacement_valid
    from public.get_financial_correction_impact(
      (
        select id from pg_temp.phase2d_ids
        where name = 'invalid_fuel_replace_request'
      )
    )
  ),
  true,
  'replacement is valid at preview time'
);

reset role;
update public.fuel_products
set is_active = false
where id = 'df100000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'invalid_fuel_replace_request'
    )
  ),
  'P0001',
  'COR_REPLACEMENT_INVALID',
  'execution recalculates and rejects a newly invalid replacement'
);

select is(
  (
    select count(*)::bigint
    from public.financial_reversals
    where request_id = (
      select id from pg_temp.phase2d_ids
      where name = 'invalid_fuel_replace_request'
    )
  ),
  0::bigint,
  'replacement failure rolls the fuel reversal back'
);

select is(
  (
    select status::text
    from public.financial_correction_requests
    where id = (
      select id from pg_temp.phase2d_ids
      where name = 'invalid_fuel_replace_request'
    )
  ),
  'PENDING_REVIEW',
  'failed execution leaves the request pending without partial effects'
);

reset role;
update public.fuel_products
set is_active = true
where id = 'df100000-0000-0000-0000-000000000001';

update public.customer_account_settings
set credit_limit_paise = 80000
where customer_id = 'd2000000-0000-0000-0000-000000000112';

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'invalid_fuel_replace_request'
    )
  ),
  'P0001',
  'COR_REPLACEMENT_CREDIT_LIMIT',
  'fuel replacement credit limit is enforced after reversing the original'
);

reset role;
update public.customer_account_settings
set credit_limit_paise = 2500000
where customer_id = 'd2000000-0000-0000-0000-000000000112';

-- A stale eligible preview cannot bypass a new repayment dependency.
reset role;
select pg_temp.cor_create_account(
  'd2000000-0000-0000-0000-000000000113',
  'd3000000-0000-0000-0000-000000000113',
  'a1000000-0000-0000-0000-000000000001',
  '+15553000113',
  2500000
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
select 'stale_fuel_tx', transaction_id
from public.post_fuel_credit_transaction(
  'd3000000-0000-0000-0000-000000000113',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  200000,
  'd4100000-0000-4000-8000-000000000113',
  'cor-stale-preview'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
values (
  'stale_fuel_request',
  pg_temp.cor_submit_reversal(
    (
      select id from pg_temp.phase2d_ids
      where name = 'stale_fuel_tx'
    ),
    'd5100000-0000-4000-8000-000000000214',
    'This sale is initially eligible before a concurrent dependency appears.'
  )
);
select is(
  (
    select reversal_eligible
    from public.get_financial_correction_impact(
      (
        select id from pg_temp.phase2d_ids
        where name = 'stale_fuel_request'
      )
    )
  ),
  true,
  'stale-preview fixture starts eligible'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.phase2d_ids
select 'stale_dependency_repayment_tx', transaction_id
from public.post_customer_repayment(
  'd3000000-0000-0000-0000-000000000113',
  'a1000000-0000-0000-0000-000000000001',
  50000,
  'PRINCIPAL_ONLY',
  'd4200000-0000-4000-8000-000000000113',
  50000,
  0,
  null,
  'cor-stale-dependency',
  'CASH'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000010',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok(
  format(
    'select * from public.approve_and_execute_financial_correction(%L,1)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'stale_fuel_request'
    )
  ),
  'P0001',
  'COR_PRINCIPAL_ALREADY_REPAID',
  'execution recalculation blocks the new dependency'
);

select is(
  (
    select count(*)::bigint
    from public.financial_reversals
    where request_id = (
      select id from pg_temp.phase2d_ids
      where name = 'stale_fuel_request'
    )
  ),
  0::bigint,
  'stale preview cannot create a partial reversal'
);

-- Hard immutability is defense in depth beyond table grants.
reset role;
select throws_ok(
  format(
    'update public.financial_correction_events set reason=reason where request_id=%L',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  '23514',
  'financial correction evidence is immutable',
  'correction events cannot be updated'
);

select throws_ok(
  format(
    'delete from public.financial_correction_events where request_id=%L',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  '23514',
  'financial correction evidence is immutable',
  'correction events cannot be deleted'
);

select throws_ok(
  format(
    'update public.financial_reversals set correlation_id=correlation_id where request_id=%L',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  '23514',
  'financial correction evidence is immutable',
  'reversal evidence cannot be updated'
);

select throws_ok(
  format(
    'update public.financial_correction_requests set version=version where id=%L',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_request'
    )
  ),
  '23514',
  'terminal correction requests are immutable',
  'executed request is terminal'
);

select throws_ok(
  format(
    'update public.ledger_transactions set amount_paise=amount_paise where id=%L',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_tx'
    )
  ),
  '42501',
  'financial records are append-only',
  'original posted ledger remains immutable'
);

select ok(
  (
    select bool_and(amount_paise > 0)
    from public.ledger_entries
    where transaction_id in (
      select reversal_transaction_id
      from public.financial_reversals
    )
  ),
  'all reversal entries remain positive integer paise'
);

select throws_ok(
  format(
    'select pg_temp.cor_submit_reversal(%L,%L,%L)',
    (
      select id from pg_temp.phase2d_ids
      where name = 'fuel_eligible_reversal'
    ),
    'd5100000-0000-4000-8000-000000000215',
    'A reversal transaction itself must not be reversed in this phase.'
  ),
  'P0001',
  'COR_INVALID_ORIGINAL_TRANSACTION',
  'a reversal transaction cannot itself be reversed'
);

select ok(
  not exists (
    select 1
    from public.audit_events
    where action like 'financial_correction.%'
      and (
        coalesce(after_state, '{}'::jsonb)
          ?| array[
            'password',
            'jwt',
            'token',
            'secret',
            'phone',
            'address'
          ]
      )
  ),
  'correction audit JSON excludes secrets and full PII'
);

select ok(
  not exists (
    select 1
    from public.financial_correction_events
    where reason ~* '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
  ),
  'event reasons contain no email-like PII'
);

select ok(
  (
    select bool_and(
      proposal.organization_id = request.organization_id
      and proposal.station_id = request.station_id
      and proposal.credit_account_id = request.credit_account_id
      and proposal.customer_id = request.customer_id
    )
    from public.fuel_credit_correction_proposals as proposal
    join public.financial_correction_requests as request
      on request.id = proposal.request_id
  ),
  'fuel proposals cannot move organization station customer or account'
);

select ok(
  (
    select bool_and(
      proposal.organization_id = request.organization_id
      and proposal.station_id = request.station_id
      and proposal.credit_account_id = request.credit_account_id
      and proposal.customer_id = request.customer_id
    )
    from public.repayment_correction_proposals as proposal
    join public.financial_correction_requests as request
      on request.id = proposal.request_id
  ),
  'repayment proposals cannot move organization station customer or account'
);

-- Customer and driver have no raw correction visibility.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000005',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select is(
  (select count(*)::bigint from public.financial_correction_requests),
  0::bigint,
  'customer sees no correction requests'
);
select is(
  (select count(*)::bigint from public.financial_correction_events),
  0::bigint,
  'customer sees no correction events'
);
select is(
  (select count(*)::bigint from public.financial_reversals),
  0::bigint,
  'customer sees no reversal evidence'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000006',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);
select is(
  (select count(*)::bigint from public.financial_correction_requests),
  0::bigint,
  'driver sees no correction requests'
);

reset role;

select * from finish();

rollback;
