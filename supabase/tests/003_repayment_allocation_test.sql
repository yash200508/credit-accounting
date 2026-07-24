begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

-- Schema, type, RLS, trigger, and privilege boundaries.
select has_table(
  'public',
  'customer_repayments',
  'repayment business-detail table exists'
);

select has_table(
  'public',
  'repayment_allocations',
  'repayment allocation table exists'
);

select is(
  (
    select count(*)::bigint
    from pg_class as relation
    join pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relname = any (
        array['customer_repayments', 'repayment_allocations']
      )
      and relation.relrowsecurity
      and relation.relforcerowsecurity
  ),
  2::bigint,
  'RLS is enabled and forced on both repayment tables'
);

select is(
  (
    select count(distinct tablename)::bigint
    from pg_policies
    where schemaname = 'public'
      and tablename = any (
        array['customer_repayments', 'repayment_allocations']
      )
  ),
  2::bigint,
  'both repayment tables have explicit policies'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.customer_repayments',
    'insert'
  )
  and not has_table_privilege(
    'authenticated',
    'public.customer_repayments',
    'update'
  )
  and not has_table_privilege(
    'authenticated',
    'public.customer_repayments',
    'delete'
  )
  and not has_table_privilege(
    'authenticated',
    'public.repayment_allocations',
    'insert'
  )
  and not has_table_privilege(
    'authenticated',
    'public.repayment_allocations',
    'update'
  )
  and not has_table_privilege(
    'authenticated',
    'public.repayment_allocations',
    'delete'
  ),
  'authenticated clients have no raw repayment writes'
);

select ok(
  not has_table_privilege(
    'service_role',
    'public.customer_repayments',
    'select'
  )
  and not has_table_privilege(
    'service_role',
    'public.customer_repayments',
    'insert'
  )
  and not has_table_privilege(
    'service_role',
    'public.customer_repayments',
    'update'
  )
  and not has_table_privilege(
    'service_role',
    'public.customer_repayments',
    'delete'
  )
  and not has_table_privilege(
    'service_role',
    'public.repayment_allocations',
    'select'
  )
  and not has_table_privilege(
    'service_role',
    'public.repayment_allocations',
    'insert'
  )
  and not has_table_privilege(
    'service_role',
    'public.repayment_allocations',
    'update'
  )
  and not has_table_privilege(
    'service_role',
    'public.repayment_allocations',
    'delete'
  ),
  'service role has no raw repayment-table capability'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.post_customer_repayment(uuid,uuid,numeric,text,uuid,numeric,numeric,uuid,text,text)',
    'execute'
  )
  and has_function_privilege(
    'authenticated',
    'public.get_credit_account_obligations(uuid)',
    'execute'
  )
  and not has_function_privilege(
    'anon',
    'public.post_customer_repayment(uuid,uuid,numeric,text,uuid,numeric,numeric,uuid,text,text)',
    'execute'
  )
  and not has_function_privilege(
    'anon',
    'public.get_credit_account_obligations(uuid)',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'public.post_customer_repayment(uuid,uuid,numeric,text,uuid,numeric,numeric,uuid,text,text)',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'public.get_credit_account_obligations(uuid)',
    'execute'
  ),
  'repayment and obligations RPCs are authenticated-only, including no service-role bypass'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'app_private.calculate_credit_account_obligations(uuid)',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'app_private.calculate_credit_account_obligations(uuid)',
    'execute'
  ),
  'private obligation calculator is unavailable to clients'
);

select is(
  (
    select count(*)::bigint
    from pg_proc as procedure
    join pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where namespace.nspname in ('public', 'app_private')
      and procedure.proname = any (
        array[
          'post_customer_repayment',
          'get_credit_account_obligations',
          'calculate_credit_account_obligations',
          'can_read_customer_repayment',
          'assert_repayment_allocations_balanced',
          'assert_ledger_transaction_balanced'
        ]
      )
      and procedure.prosecdef
      and coalesce(array_to_string(procedure.proconfig, ','), '')
        like '%search_path=%'
  ),
  6::bigint,
  'all Phase 2B privileged functions fix search_path'
);

select is(
  (
    select count(*)::bigint
    from information_schema.columns
    where table_schema = 'public'
      and (
        (
          table_name = 'customer_repayments'
          and column_name = 'total_amount_paise'
        )
        or (
          table_name = 'repayment_allocations'
          and column_name = 'amount_paise'
        )
        or (
          table_name = 'idempotency_keys'
          and column_name in (
            'response_outstanding_interest_paise',
            'response_total_due_paise'
          )
        )
      )
      and data_type = 'bigint'
  ),
  4::bigint,
  'all stored Phase 2B money values use BIGINT paise'
);

select ok(
  exists (
    select 1
    from pg_enum as value
    where value.enumtypid = 'public.ledger_transaction_type'::regtype
      and value.enumlabel = 'CUSTOMER_REPAYMENT'
  )
  and exists (
    select 1
    from pg_enum as value
    where value.enumtypid = 'public.ledger_transaction_type'::regtype
      and value.enumlabel = 'INTEREST_CHARGE'
  ),
  'repayment and historical interest-charge transaction types exist'
);

select is(
  (
    select count(*)::bigint
    from pg_enum as value
    where value.enumtypid = 'public.ledger_account_code'::regtype
      and value.enumlabel = any (
        array[
          'CUSTOMER_INTEREST_RECEIVABLE',
          'INTEREST_INCOME',
          'CASH_ON_HAND'
        ]
      )
  ),
  3::bigint,
  'interest receivable, interest income, and cash ledger accounts exist'
);

select is(
  (
    select count(*)::bigint
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'credit_accounts'
      and column_name in (
        'outstanding_principal_paise',
        'outstanding_interest_paise',
        'total_due_paise',
        'available_credit_paise'
      )
  ),
  0::bigint,
  'credit accounts contain no mutable authoritative balance columns'
);

select is(
  (
    select count(*)::bigint
    from pg_trigger
    where not tgisinternal
      and tgname = any (
        array[
          'customer_repayments_reject_update_delete',
          'repayment_allocations_reject_update_delete',
          'customer_repayments_require_allocations',
          'repayment_allocations_require_repayment_total'
        ]
      )
  ),
  4::bigint,
  'repayment immutability and deferred allocation triggers exist'
);

-- Deterministic local-only repayment fixtures.
insert into public.customers (
  id,
  organization_id,
  home_station_id,
  auth_user_id,
  first_name,
  last_name,
  phone,
  status,
  created_by,
  updated_by,
  created_at,
  updated_at
)
values
  ('e2000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Principal', 'Fixture', '+15550210001', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e2000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Interest', 'Fixture', '+15550210002', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e2000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Split', 'Fixture', '+15550210003', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e2000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Nothing', 'Fixture', '+15550210004', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e2000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Low Due', 'Fixture', '+15550210005', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e2000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Inactive', 'Customer', '+15550210006', 'INACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e2000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Inactive', 'Account', '+15550210007', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e2000000-0000-0000-0000-000000000008', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Driver', 'Fixture', '+15550210008', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e2000000-0000-0000-0000-000000000009', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Manager', 'Fixture', '+15550210009', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e2000000-0000-0000-0000-00000000000a', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', null, 'Attendant', 'Fixture', '+15550210010', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z');

insert into public.customer_account_settings (
  customer_id,
  organization_id,
  credit_limit_paise,
  default_annual_interest_rate,
  grace_days,
  grace_policy,
  due_days,
  created_by,
  updated_by,
  created_at,
  updated_at
)
select
  customer.id,
  customer.organization_id,
  case when customer.id = 'e2000000-0000-0000-0000-000000000005'
    then 20000 else 200000 end,
  0.18000000,
  0,
  'AFTER_GRACE_ONLY',
  30,
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '2026-07-24T00:00:00Z',
  '2026-07-24T00:00:00Z'
from public.customers as customer
where customer.id::text like 'e2000000-0000-0000-0000-00000000000%';

insert into public.credit_accounts (
  id,
  organization_id,
  customer_id,
  home_station_id,
  currency_code,
  is_active,
  created_by,
  updated_by,
  created_at,
  updated_at
)
select
  ('e3000000-0000-0000-0000-' || right(customer.id::text, 12))::uuid,
  customer.organization_id,
  customer.id,
  customer.home_station_id,
  'INR',
  customer.id <> 'e2000000-0000-0000-0000-000000000007',
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  '2026-07-24T00:00:00Z',
  '2026-07-24T00:00:00Z'
from public.customers as customer
where customer.id::text like 'e2000000-0000-0000-0000-00000000000%';

insert into public.customer_drivers (
  id,
  organization_id,
  customer_id,
  auth_user_id,
  first_name,
  last_name,
  phone,
  status,
  created_by,
  updated_by,
  created_at,
  updated_at
)
values
  ('e4000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000008', null, 'Active', 'Delivery Driver', '+15550211001', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e4000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000008', null, 'Revoked', 'Delivery Driver', '+15550211002', 'REVOKED', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e4000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000008', null, 'Expired', 'Delivery Driver', '+15550211003', 'ACTIVE', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z');

insert into public.driver_permissions (
  driver_id,
  customer_id,
  organization_id,
  transaction_limit_paise,
  daily_limit_paise,
  valid_from,
  expires_on,
  created_by,
  updated_by,
  created_at,
  updated_at
)
values
  ('e4000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000008', 'a0000000-0000-0000-0000-000000000001', null, null, '2026-01-01', '2099-12-31', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e4000000-0000-0000-0000-000000000002', 'e2000000-0000-0000-0000-000000000008', 'a0000000-0000-0000-0000-000000000001', null, null, '2026-01-01', '2099-12-31', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z'),
  ('e4000000-0000-0000-0000-000000000003', 'e2000000-0000-0000-0000-000000000008', 'a0000000-0000-0000-0000-000000000001', null, null, '2026-01-01', '2026-06-30', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z');

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select count(*) from public.post_fuel_credit_transaction(
  'e3000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  100000,
  'e0100000-0000-0000-0000-000000000001',
  'RPP-FIXTURE-P'
);
select count(*) from public.post_fuel_credit_transaction(
  'e3000000-0000-0000-0000-000000000003',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  100000,
  'e0100000-0000-0000-0000-000000000003',
  'RPP-FIXTURE-S'
);
select count(*) from public.post_fuel_credit_transaction(
  'e3000000-0000-0000-0000-000000000005',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  10000,
  'e0100000-0000-0000-0000-000000000005',
  'RPP-FIXTURE-L'
);
select count(*) from public.post_fuel_credit_transaction(
  'e3000000-0000-0000-0000-000000000008',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  40000,
  'e0100000-0000-0000-0000-000000000008',
  'RPP-FIXTURE-D'
);
select count(*) from public.post_fuel_credit_transaction(
  'e3000000-0000-0000-0000-000000000009',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  20000,
  'e0100000-0000-0000-0000-000000000009',
  'RPP-FIXTURE-M'
);
select count(*) from public.post_fuel_credit_transaction(
  'e3000000-0000-0000-0000-00000000000a',
  'a1000000-0000-0000-0000-000000000001',
  'af100000-0000-0000-0000-000000000001',
  20000,
  'e0100000-0000-0000-0000-00000000000a',
  'RPP-FIXTURE-A'
);

reset role;

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
values
  ('e5000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-000000000002', 'e2000000-0000-0000-0000-000000000002', 'INTEREST_CHARGE', 'POSTED', 50000, 'INR', '2026-07-24T00:00:00Z', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z'),
  ('e5000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-000000000003', 'e2000000-0000-0000-0000-000000000003', 'INTEREST_CHARGE', 'POSTED', 50000, 'INR', '2026-07-24T00:00:00Z', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z'),
  ('e5000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-000000000005', 'e2000000-0000-0000-0000-000000000005', 'INTEREST_CHARGE', 'POSTED', 5000, 'INR', '2026-07-24T00:00:00Z', '10000000-0000-0000-0000-000000000001', '2026-07-24T00:00:00Z');

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
  ('a0000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000002', 'CUSTOMER_INTEREST_RECEIVABLE', 'DEBIT', 50000, 'INR', '2026-07-24T00:00:00Z'),
  ('a0000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000002', 'INTEREST_INCOME', 'CREDIT', 50000, 'INR', '2026-07-24T00:00:00Z'),
  ('a0000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000003', 'CUSTOMER_INTEREST_RECEIVABLE', 'DEBIT', 50000, 'INR', '2026-07-24T00:00:00Z'),
  ('a0000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000003', 'INTEREST_INCOME', 'CREDIT', 50000, 'INR', '2026-07-24T00:00:00Z'),
  ('a0000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000005', 'CUSTOMER_INTEREST_RECEIVABLE', 'DEBIT', 5000, 'INR', '2026-07-24T00:00:00Z'),
  ('a0000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000005', 'INTEREST_INCOME', 'CREDIT', 5000, 'INR', '2026-07-24T00:00:00Z');

set constraints all immediate;
set constraints all deferred;

-- Execution authentication and authorization.
set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000000'
    )
  $$,
  'P0001',
  'RPP_AUTH_REQUIRED',
  'authenticated database role without Auth identity is rejected'
);

reset role;
set local role anon;

select throws_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-00000000000f'
    )
  $$,
  '42501',
  'permission denied for function post_customer_repayment',
  'anonymous cannot execute repayment posting'
);

reset role;

-- Denied station-side actors and scopes.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000002',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'b1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000010'
    )
  $$,
  'P0001',
  'RPP_FORBIDDEN',
  'cross-tenant owner cannot post a repayment'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select * from public.post_customer_repayment(
      'a3000000-0000-0000-0000-000000000002',
      'a1000000-0000-0000-0000-000000000002',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000011'
    )
  $$,
  'P0001',
  'RPP_FORBIDDEN',
  'manager cannot post outside the assigned station'
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
  $$
    select * from public.post_customer_repayment(
      'a3000000-0000-0000-0000-000000000002',
      'a1000000-0000-0000-0000-000000000002',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000012'
    )
  $$,
  'P0001',
  'RPP_FORBIDDEN',
  'attendant cannot post outside the assigned station'
);

reset role;

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000008',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000013'
    )
  $$,
  'P0001',
  'RPP_FORBIDDEN',
  'revoked manager cannot post'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000005',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000014'
    )
  $$,
  'P0001',
  'RPP_FORBIDDEN',
  'customer cannot invoke station-side repayment posting'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000006',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000015'
    )
  $$,
  'P0001',
  'RPP_FORBIDDEN',
  'driver cannot invoke station-side repayment posting'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000007',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000016'
    )
  $$,
  'P0001',
  'RPP_FORBIDDEN',
  'unrelated authenticated user cannot post'
);

-- Owner principal-only repayment.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      20000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000001',
      null,
      null,
      null,
      'OWNER-PRINCIPAL',
      'CASH'
    )
  $$,
  'owner posts a principal-only repayment in the owned organization'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.customer_repayments as repayment
    join public.idempotency_keys as idempotency
      on idempotency.response_repayment_id = repayment.id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000001'
      and repayment.total_amount_paise = 20000
      and repayment.allocation_mode = 'PRINCIPAL_ONLY'
      and repayment.payment_method = 'CASH'
      and repayment.payer_type = 'CUSTOMER'
      and repayment.payer_driver_id is null
      and repayment.received_by =
        '10000000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'principal-only repayment stores server-derived actor and customer payer'
);

select is(
  (
    select count(*)::bigint
    from public.repayment_allocations as allocation
    join public.idempotency_keys as idempotency
      on idempotency.response_repayment_id = allocation.repayment_id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000001'
      and allocation.component = 'PRINCIPAL'
      and allocation.amount_paise = 20000
  ),
  1::bigint,
  'principal-only repayment creates one exact principal allocation'
);

select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000001'
      and (
        (
          entry.account_code = 'CASH_ON_HAND'
          and entry.direction = 'DEBIT'
          and entry.amount_paise = 20000
        )
        or (
          entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
          and entry.direction = 'CREDIT'
          and entry.amount_paise = 20000
        )
      )
  ),
  2::bigint,
  'principal-only repayment has one cash debit and one AR credit'
);

select is(
  (
    select outstanding_principal_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000001'
    )
  ),
  80000::bigint,
  'principal repayment reduces principal exactly'
);

select is(
  (
    select outstanding_interest_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000001'
    )
  ),
  0::bigint,
  'principal repayment leaves interest unchanged'
);

select is(
  (
    select available_credit_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000001'
    )
  ),
  120000::bigint,
  'principal repayment increases available credit'
);

select is(
  (
    select count(*)::bigint
    from public.audit_events
    where request_id = 'e1000000-0000-0000-0000-000000000001'
      and action = 'customer_repayment.posted'
      and actor_role = 'OWNER'
      and after_state @> jsonb_build_object(
        'principal_allocation_paise',
        20000
      )
  ),
  1::bigint,
  'principal repayment creates one immutable financial audit event'
);

-- Manager and attendant are authorized only at the assigned station.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000009',
      'a1000000-0000-0000-0000-000000000001',
      5000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000009'
    )
  $$,
  'assigned manager posts within the assigned station'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000004',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-00000000000a',
      'a1000000-0000-0000-0000-000000000001',
      5000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-00000000000a'
    )
  $$,
  'assigned attendant posts within the assigned station'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.customer_repayments
    where received_by =
      '10000000-0000-0000-0000-000000000003'
  ),
  1::bigint,
  'manager receipt records the authenticated manager'
);

select is(
  (
    select count(*)::bigint
    from public.customer_repayments
    where received_by =
      '10000000-0000-0000-0000-000000000004'
  ),
  1::bigint,
  'attendant receipt records the authenticated attendant'
);

-- Interest-only repayment.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000002',
      'a1000000-0000-0000-0000-000000000001',
      10000,
      'INTEREST_ONLY',
      'e1000000-0000-0000-0000-000000000002'
    )
  $$,
  'interest-only repayment succeeds against posted interest'
);

reset role;

select is(
  (
    select outstanding_interest_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000002'
    )
  ),
  40000::bigint,
  'interest-only repayment reduces interest exactly'
);

select is(
  (
    select outstanding_principal_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000002'
    )
  ),
  0::bigint,
  'interest-only repayment leaves principal unchanged'
);

select is(
  (
    select available_credit_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000002'
    )
  ),
  200000::bigint,
  'interest-only repayment does not change available credit'
);

select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000002'
      and (
        (
          entry.account_code = 'CASH_ON_HAND'
          and entry.direction = 'DEBIT'
          and entry.amount_paise = 10000
        )
        or (
          entry.account_code = 'CUSTOMER_INTEREST_RECEIVABLE'
          and entry.direction = 'CREDIT'
          and entry.amount_paise = 10000
        )
      )
  ),
  2::bigint,
  'interest-only repayment has one cash debit and one interest credit'
);

-- Explicit split repayment.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000003',
      'a1000000-0000-0000-0000-000000000001',
      50000,
      'SPLIT',
      'e1000000-0000-0000-0000-000000000003',
      30000,
      20000
    )
  $$,
  'explicit split repayment succeeds'
);

reset role;

select is(
  (
    select outstanding_principal_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000003'
    )
  ),
  70000::bigint,
  'split repayment reduces principal by its explicit component'
);

select is(
  (
    select outstanding_interest_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000003'
    )
  ),
  30000::bigint,
  'split repayment reduces interest by its explicit component'
);

select is(
  (
    select total_due_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000003'
    )
  ),
  100000::bigint,
  'split repayment reduces total due by the cash total'
);

select is(
  (
    select available_credit_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000003'
    )
  ),
  130000::bigint,
  'split repayment increases available credit only by principal'
);

select is(
  (
    select count(*)::bigint
    from public.repayment_allocations as allocation
    join public.idempotency_keys as idempotency
      on idempotency.response_repayment_id = allocation.repayment_id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000003'
  ),
  2::bigint,
  'split creates exactly two allocation rows'
);

select is(
  (
    select sum(allocation.amount_paise)::bigint
    from public.repayment_allocations as allocation
    join public.idempotency_keys as idempotency
      on idempotency.response_repayment_id = allocation.repayment_id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000003'
  ),
  50000::bigint,
  'split allocation sum exactly equals payment total'
);

select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000003'
  ),
  3::bigint,
  'split repayment creates exactly three ledger entries'
);

select is(
  (
    select
      (
        sum(entry.amount_paise) filter (
        where entry.direction = 'DEBIT'
        )
        - sum(entry.amount_paise) filter (
          where entry.direction = 'CREDIT'
        )
      )::bigint
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000003'
  ),
  0::bigint,
  'split repayment ledger balances'
);

-- Amount, allocation, account, method, and entity validation.
select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      0,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000020'
    )
  $$,
  'P0001',
  'RPP_INVALID_AMOUNT',
  'zero payment is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      -1,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000021'
    )
  $$,
  'P0001',
  'RPP_INVALID_AMOUNT',
  'negative payment is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      1.5,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000022'
    )
  $$,
  'P0001',
  'RPP_INVALID_AMOUNT',
  'fractional paise payment is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      9223372036854775808,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000023'
    )
  $$,
  'P0001',
  'RPP_OVERFLOW',
  'overflow payment is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'AUTOMATIC',
      'e1000000-0000-0000-0000-000000000024'
    )
  $$,
  'P0001',
  'RPP_INVALID_ALLOCATION_MODE',
  'automatic or unknown allocation mode is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      5000,
      'SPLIT',
      'e1000000-0000-0000-0000-000000000025',
      3000,
      1000
    )
  $$,
  'P0001',
  'RPP_ALLOCATION_MISMATCH',
  'split total mismatch is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      5000,
      'SPLIT',
      'e1000000-0000-0000-0000-000000000026',
      -1000,
      6000
    )
  $$,
  'P0001',
  'RPP_ALLOCATION_MISMATCH',
  'negative split component is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      5000,
      'SPLIT',
      'e1000000-0000-0000-0000-000000000027',
      0,
      5000
    )
  $$,
  'P0001',
  'RPP_ALLOCATION_MISMATCH',
  'zero split component is rejected as ambiguous'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      15000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000028'
    )
  $$,
  'P0001',
  'RPP_PRINCIPAL_EXCEEDS_DUE',
  'principal allocation above principal due is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      6000,
      'INTEREST_ONLY',
      'e1000000-0000-0000-0000-000000000029'
    )
  $$,
  'P0001',
  'RPP_INTEREST_EXCEEDS_DUE',
  'interest allocation above interest due is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000004',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-00000000002a'
    )
  $$,
  'P0001',
  'RPP_NOTHING_DUE',
  'payment when nothing is due is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000006',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-00000000002b'
    )
  $$,
  'P0001',
  'RPP_INACTIVE_CUSTOMER',
  'inactive customer is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000007',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-00000000002c'
    )
  $$,
  'P0001',
  'RPP_INACTIVE_ACCOUNT',
  'inactive account is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-00000000002d',
      null,
      null,
      null,
      null,
      'UPI'
    )
  $$,
  'P0001',
  'RPP_INVALID_PAYMENT_METHOD',
  'non-cash method is deferred and rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-00000000002e',
      null,
      null,
      null,
      'unsafe note with spaces',
      'CASH'
    )
  $$,
  'P0001',
  'RPP_INVALID_SOURCE_REFERENCE',
  'unsafe free-form source reference is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      null
    )
  $$,
  'P0001',
  'RPP_IDEMPOTENCY_KEY_REQUIRED',
  'idempotency key is required'
);

select is(
  (
    select count(*)::bigint
    from public.idempotency_keys
    where idempotency_key =
      'e1000000-0000-0000-0000-000000000028'
  ),
  0::bigint,
  'failed excessive repayment leaves no idempotency row'
);

select is(
  (
    select count(*)::bigint
    from public.customer_repayments
    where source_reference = 'OWNER-PRINCIPAL'
  ),
  1::bigint,
  'validation failures leave no unrelated partial repayment rows'
);

-- Driver attribution is physical-payer metadata only.
select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000008',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000030',
      null,
      null,
      'a4000000-0000-0000-0000-000000000001'
    )
  $$,
  'P0001',
  'RPP_INVALID_DRIVER',
  'driver belonging to another customer is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000008',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000031',
      null,
      null,
      'e4000000-0000-0000-0000-000000000002'
    )
  $$,
  'P0001',
  'RPP_DRIVER_REVOKED',
  'revoked linked driver is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000008',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000032',
      null,
      null,
      'e4000000-0000-0000-0000-000000000003'
    )
  $$,
  'P0001',
  'RPP_INVALID_DRIVER',
  'expired linked driver is rejected'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000008',
      'a1000000-0000-0000-0000-000000000001',
      1000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000033',
      null,
      null,
      'b4000000-0000-0000-0000-000000000001'
    )
  $$,
  'P0001',
  'RPP_INVALID_DRIVER',
  'cross-tenant driver is rejected without disclosure'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000008',
      'a1000000-0000-0000-0000-000000000001',
      5000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000008',
      null,
      null,
      'e4000000-0000-0000-0000-000000000001',
      'DRIVER-CASH',
      'CASH'
    )
  $$,
  'active linked driver may be recorded as physical payer'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.customer_repayments
    where payer_type = 'DRIVER'
      and payer_driver_id =
        'e4000000-0000-0000-0000-000000000001'
      and customer_id =
        'e2000000-0000-0000-0000-000000000008'
      and credit_account_id =
        'e3000000-0000-0000-0000-000000000008'
  ),
  1::bigint,
  'driver repayment remains attached only to the parent customer account'
);

select is(
  (
    select outstanding_principal_paise
    from app_private.calculate_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000008'
    )
  ),
  35000::bigint,
  'driver-delivered cash reduces only parent-customer principal'
);

select is(
  (
    select count(*)::bigint
    from public.credit_accounts
    where customer_id =
      'e2000000-0000-0000-0000-000000000008'
  ),
  1::bigint,
  'driver attribution creates no independent credit account'
);

-- Idempotent replay and material-payload conflicts.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (
    select idempotent_replay
    from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      20000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000001',
      null,
      null,
      null,
      'OWNER-PRINCIPAL',
      'CASH'
    )
  ),
  true,
  'same repayment key and payload returns original receipt'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.customer_repayments as repayment
    join public.idempotency_keys as idempotency
      on idempotency.response_repayment_id = repayment.id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'replay creates no duplicate repayment'
);

select is(
  (
    select count(*)::bigint
    from public.repayment_allocations as allocation
    join public.idempotency_keys as idempotency
      on idempotency.response_repayment_id = allocation.repayment_id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'replay creates no duplicate allocation'
);

select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
      'e1000000-0000-0000-0000-000000000001'
  ),
  2::bigint,
  'replay creates no duplicate ledger entries'
);

select is(
  (
    select count(*)::bigint
    from public.audit_events
    where request_id = 'e1000000-0000-0000-0000-000000000001'
      and action = 'customer_repayment.posted'
  ),
  1::bigint,
  'replay creates no duplicate audit event'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      19000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000001',
      null,
      null,
      null,
      'OWNER-PRINCIPAL',
      'CASH'
    )
  $$,
  'P0001',
  'RPP_IDEMPOTENCY_CONFLICT',
  'same key with changed amount conflicts'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000003',
      'a1000000-0000-0000-0000-000000000001',
      50000,
      'SPLIT',
      'e1000000-0000-0000-0000-000000000003',
      25000,
      25000
    )
  $$,
  'P0001',
  'RPP_IDEMPOTENCY_CONFLICT',
  'same key with changed allocation conflicts'
);

select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000008',
      'a1000000-0000-0000-0000-000000000001',
      5000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000008',
      null,
      null,
      null,
      'DRIVER-CASH',
      'CASH'
    )
  $$,
  'P0001',
  'RPP_IDEMPOTENCY_CONFLICT',
  'same key with changed payer driver conflicts'
);

-- Failed key is retryable after full rollback.
select throws_ok(
  $$
    set local role authenticated;
    select set_config(
      'request.jwt.claim.sub',
      '10000000-0000-0000-0000-000000000001',
      true
    );
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      15000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000005'
    )
  $$,
  'P0001',
  'RPP_PRINCIPAL_EXCEEDS_DUE',
  'failed excessive request rolls back'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select * from public.post_customer_repayment(
      'e3000000-0000-0000-0000-000000000005',
      'a1000000-0000-0000-0000-000000000001',
      5000,
      'PRINCIPAL_ONLY',
      'e1000000-0000-0000-0000-000000000005'
    )
  $$,
  'same key can be safely retried with a corrected payload after failure'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.idempotency_keys
    where idempotency_key =
      'e1000000-0000-0000-0000-000000000005'
      and status = 'COMPLETED'
  ),
  1::bigint,
  'corrected retry creates exactly one completed idempotency result'
);

-- Hard immutability and deferred invariants.
select throws_ok(
  $$
    update public.customer_repayments
    set total_amount_paise = total_amount_paise
    where id = (
      select response_repayment_id
      from public.idempotency_keys
      where idempotency_key =
        'e1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'posted repayment cannot be updated'
);

select throws_ok(
  $$
    delete from public.customer_repayments
    where id = (
      select response_repayment_id
      from public.idempotency_keys
      where idempotency_key =
        'e1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'posted repayment cannot be deleted'
);

select throws_ok(
  $$
    update public.repayment_allocations
    set amount_paise = amount_paise
    where repayment_id = (
      select response_repayment_id
      from public.idempotency_keys
      where idempotency_key =
        'e1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'repayment allocation cannot be updated'
);

select throws_ok(
  $$
    delete from public.repayment_allocations
    where repayment_id = (
      select response_repayment_id
      from public.idempotency_keys
      where idempotency_key =
        'e1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'repayment allocation cannot be deleted'
);

select throws_ok(
  $$
    update public.ledger_entries
    set amount_paise = amount_paise
    where transaction_id = (
      select response_transaction_id
      from public.idempotency_keys
      where idempotency_key =
        'e1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'repayment ledger entry remains immutable'
);

select throws_ok(
  $$
    update public.audit_events
    set action = action
    where request_id =
      'e1000000-0000-0000-0000-000000000001'
  $$,
  '42501',
  'audit events are append-only',
  'repayment audit event remains immutable'
);

select throws_ok(
  $$
    insert into public.idempotency_keys (
      id,
      organization_id,
      station_id,
      credit_account_id,
      operation,
      idempotency_key,
      request_fingerprint,
      amount_paise,
      status,
      created_by
    )
    values (
      'ef000000-0000-0000-0000-000000000001',
      'a0000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'e3000000-0000-0000-0000-000000000001',
      'CUSTOMER_REPAYMENT',
      'ef100000-0000-0000-0000-000000000001',
      repeat('a', 64),
      1000,
      'IN_PROGRESS',
      '10000000-0000-0000-0000-000000000001'
    );
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
      created_by
    )
    values (
      'ef200000-0000-0000-0000-000000000001',
      'a0000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'e3000000-0000-0000-0000-000000000001',
      'e2000000-0000-0000-0000-000000000001',
      'CUSTOMER_REPAYMENT',
      'POSTED',
      1000,
      'INR',
      '10000000-0000-0000-0000-000000000001'
    );
    insert into public.customer_repayments (
      id,
      organization_id,
      station_id,
      transaction_id,
      credit_account_id,
      customer_id,
      idempotency_id,
      total_amount_paise,
      allocation_mode,
      payment_method,
      payer_type,
      received_by
    )
    values (
      'ef300000-0000-0000-0000-000000000001',
      'a0000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'ef200000-0000-0000-0000-000000000001',
      'e3000000-0000-0000-0000-000000000001',
      'e2000000-0000-0000-0000-000000000001',
      'ef000000-0000-0000-0000-000000000001',
      1000,
      'SPLIT',
      'CASH',
      'CUSTOMER',
      '10000000-0000-0000-0000-000000000001'
    );
    insert into public.repayment_allocations (
      organization_id,
      repayment_id,
      credit_account_id,
      component,
      amount_paise
    )
    values (
      'a0000000-0000-0000-0000-000000000001',
      'ef300000-0000-0000-0000-000000000001',
      'e3000000-0000-0000-0000-000000000001',
      'PRINCIPAL',
      1000
    );
    set constraints customer_repayments_require_allocations immediate
  $$,
  '23514',
  'repayment allocations do not match repayment total',
  'deferred constraint rejects malformed split allocations'
);

-- Actual direct client mutation attempts fail.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    insert into public.customer_repayments (
      organization_id,
      station_id,
      transaction_id,
      credit_account_id,
      customer_id,
      idempotency_id,
      total_amount_paise,
      allocation_mode,
      payment_method,
      payer_type,
      received_by
    )
    values (
      'a0000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      gen_random_uuid(),
      'e3000000-0000-0000-0000-000000000001',
      'e2000000-0000-0000-0000-000000000001',
      gen_random_uuid(),
      1000,
      'PRINCIPAL_ONLY',
      'CASH',
      'CUSTOMER',
      '10000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'permission denied for table customer_repayments',
  'authenticated client cannot insert raw repayment'
);

select throws_ok(
  $$
    update public.customer_repayments
    set total_amount_paise = total_amount_paise
  $$,
  '42501',
  'permission denied for table customer_repayments',
  'authenticated client cannot update repayment'
);

select throws_ok(
  $$
    delete from public.repayment_allocations
  $$,
  '42501',
  'permission denied for table repayment_allocations',
  'authenticated client cannot delete allocation'
);

reset role;

-- Balance authorization, tenant isolation, and minimum RLS reads.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (
    select total_due_paise
    from public.get_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000003'
    )
  ),
  100000::bigint,
  'owner reads server-authoritative principal plus interest total'
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
  $$
    select * from public.get_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000003'
    )
  $$,
  'P0001',
  'BAL_ACCOUNT_NOT_FOUND_OR_FORBIDDEN',
  'cross-tenant owner cannot read obligations'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000004',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (
    select total_due_paise
    from public.get_credit_account_obligations(
      'e3000000-0000-0000-0000-000000000003'
    )
  ),
  100000::bigint,
  'assigned attendant can read exact account obligations before posting'
);

select throws_ok(
  $$
    select * from public.get_credit_account_obligations(
      'a3000000-0000-0000-0000-000000000002'
    )
  $$,
  'P0001',
  'BAL_ACCOUNT_NOT_FOUND_OR_FORBIDDEN',
  'attendant cannot read obligations outside the assigned station'
);

select ok(
  (select count(*) = 0 from public.customer_repayments)
  and (select count(*) = 0 from public.repayment_allocations),
  'attendant has no broad repayment-table read access'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select ok(
  (select count(*) > 0 from public.customer_repayments)
  and (select count(*) > 0 from public.repayment_allocations),
  'assigned manager can read repayment rows for the assigned station'
);

reset role;

select ok(
  (
    select not (
      event.after_state
      ?| array[
        'phone',
        'name',
        'source_reference',
        'request_fingerprint',
        'jwt',
        'token',
        'secret'
      ]
    )
    from public.audit_events as event
    where event.request_id =
      'e1000000-0000-0000-0000-000000000003'
  ),
  'repayment audit JSON excludes PII, source text, fingerprint, and secrets'
);

select * from finish();

rollback;
