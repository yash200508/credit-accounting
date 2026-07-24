begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

-- Schema, grants, and policy structure.
select is(
  (
    select count(*)::bigint
    from pg_class as relation
    join pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relkind = 'r'
      and relation.relname = any (
        array[
          'fuel_products',
          'ledger_transactions',
          'ledger_entries',
          'fuel_credit_sales',
          'idempotency_keys'
        ]
      )
  ),
  5::bigint,
  'all Phase 2A protected tables exist'
);

select is(
  (
    select count(*)::bigint
    from pg_class as relation
    join pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relkind = 'r'
      and relation.relrowsecurity
      and relation.relforcerowsecurity
      and relation.relname = any (
        array[
          'fuel_products',
          'ledger_transactions',
          'ledger_entries',
          'fuel_credit_sales',
          'idempotency_keys'
        ]
      )
  ),
  5::bigint,
  'RLS is enabled and forced on all Phase 2A tables'
);

select is(
  (
    select count(distinct tablename)::bigint
    from pg_policies
    where schemaname = 'public'
      and tablename = any (
        array[
          'fuel_products',
          'ledger_transactions',
          'ledger_entries',
          'fuel_credit_sales',
          'idempotency_keys'
        ]
      )
  ),
  5::bigint,
  'every Phase 2A protected table has an explicit policy'
);

select ok(
  not has_table_privilege('anon', 'public.fuel_products', 'select')
  and not has_table_privilege('anon', 'public.ledger_transactions', 'select')
  and not has_table_privilege('anon', 'public.ledger_entries', 'select')
  and not has_table_privilege('anon', 'public.fuel_credit_sales', 'select')
  and not has_table_privilege('anon', 'public.idempotency_keys', 'select'),
  'anonymous has no Phase 2A table privileges'
);

select ok(
  not has_table_privilege('authenticated', 'public.fuel_products', 'insert')
  and not has_table_privilege('authenticated', 'public.fuel_products', 'update')
  and not has_table_privilege('authenticated', 'public.fuel_products', 'delete')
  and not has_table_privilege('authenticated', 'public.ledger_transactions', 'insert')
  and not has_table_privilege('authenticated', 'public.ledger_transactions', 'update')
  and not has_table_privilege('authenticated', 'public.ledger_transactions', 'delete')
  and not has_table_privilege('authenticated', 'public.ledger_entries', 'insert')
  and not has_table_privilege('authenticated', 'public.ledger_entries', 'update')
  and not has_table_privilege('authenticated', 'public.ledger_entries', 'delete')
  and not has_table_privilege('authenticated', 'public.fuel_credit_sales', 'insert')
  and not has_table_privilege('authenticated', 'public.idempotency_keys', 'insert'),
  'authenticated clients have no raw Phase 2A write privileges'
);

select ok(
  not has_table_privilege('service_role', 'public.fuel_products', 'insert')
  and not has_table_privilege('service_role', 'public.fuel_products', 'update')
  and not has_table_privilege('service_role', 'public.fuel_products', 'delete')
  and not has_table_privilege(
    'service_role',
    'public.ledger_transactions',
    'insert'
  )
  and not has_table_privilege(
    'service_role',
    'public.ledger_transactions',
    'update'
  )
  and not has_table_privilege(
    'service_role',
    'public.ledger_transactions',
    'delete'
  )
  and not has_table_privilege('service_role', 'public.ledger_entries', 'insert')
  and not has_table_privilege('service_role', 'public.ledger_entries', 'update')
  and not has_table_privilege('service_role', 'public.ledger_entries', 'delete')
  and not has_table_privilege(
    'service_role',
    'public.fuel_credit_sales',
    'insert'
  )
  and not has_table_privilege(
    'service_role',
    'public.idempotency_keys',
    'insert'
  ),
  'service role has no raw Phase 2A mutation capability'
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
          'create_customer_with_credit_account',
          'post_fuel_credit_transaction',
          'get_credit_account_balance',
          'calculate_credit_account_balance'
        ]
      )
      and procedure.prosecdef
      and coalesce(array_to_string(procedure.proconfig, ','), '')
        like '%search_path=%'
  ),
  4::bigint,
  'all Phase 2A privileged functions fix search_path'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.get_credit_account_balance(uuid)',
    'execute'
  )
  and has_function_privilege(
    'authenticated',
    'public.post_fuel_credit_transaction(uuid,uuid,uuid,numeric,uuid,text)',
    'execute'
  )
  and not has_function_privilege(
    'anon',
    'public.get_credit_account_balance(uuid)',
    'execute'
  )
  and not has_function_privilege(
    'anon',
    'public.post_fuel_credit_transaction(uuid,uuid,uuid,numeric,uuid,text)',
    'execute'
  ),
  'trusted financial functions are authenticated-only'
);

select is(
  (
    select count(*)::bigint
    from information_schema.columns
    where table_schema = 'public'
      and (
        (
          table_name = 'ledger_transactions'
          and column_name = 'amount_paise'
        )
        or (
          table_name = 'ledger_entries'
          and column_name = 'amount_paise'
        )
        or (
          table_name = 'fuel_credit_sales'
          and column_name = 'amount_paise'
        )
        or (
          table_name = 'idempotency_keys'
          and column_name in (
            'amount_paise',
            'response_outstanding_principal_paise',
            'response_available_credit_paise'
          )
        )
      )
      and data_type = 'bigint'
  ),
  6::bigint,
  'all stored Phase 2A money values use BIGINT paise'
);

select is(
  (
    select count(*)::bigint
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'fuel_credit_sales'
      and column_name = any (
        array[
          'litres',
          'liters',
          'price',
          'price_paise',
          'pump_id',
          'nozzle_id'
        ]
      )
  ),
  0::bigint,
  'fuel sales contain no deferred price, litre, pump, or nozzle fields'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Missing',
      'Identity',
      '+15550102000'
    )
  $$,
  'P0001',
  'CCC_AUTHENTICATION_REQUIRED',
  'customer creation rejects an authenticated role without an Auth identity'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000000'
    )
  $$,
  'P0001',
  'FCP_AUTHENTICATION_REQUIRED',
  'fuel posting rejects an authenticated role without an Auth identity'
);

reset role;

-- Trusted customer/account creation.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Owner',
      'Created',
      '+15550102001',
      'Owner Created Customer',
      '+15550102011',
      '501 Example Avenue',
      500000,
      0.12500000,
      5,
      'AFTER_GRACE_ONLY',
      30,
      'c0100000-0000-0000-0000-000000000001'
    )
  $$,
  'owner can atomically create a customer and credit account'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.customers
    where organization_id = 'a0000000-0000-0000-0000-000000000001'
      and phone = '+15550102001'
      and status = 'ACTIVE'
  ),
  1::bigint,
  'owner creation writes one active customer'
);

select is(
  (
    select count(*)::bigint
    from public.customer_account_settings as settings
    join public.customers as customer
      on customer.id = settings.customer_id
     and customer.organization_id = settings.organization_id
    where customer.phone = '+15550102001'
      and settings.credit_limit_paise = 500000
      and settings.default_annual_interest_rate = 0.12500000
  ),
  1::bigint,
  'owner creation writes exact account settings'
);

select is(
  (
    select count(*)::bigint
    from public.credit_accounts as account
    join public.customers as customer
      on customer.id = account.customer_id
     and customer.organization_id = account.organization_id
    where customer.phone = '+15550102001'
      and account.home_station_id =
        'a1000000-0000-0000-0000-000000000001'
      and account.currency_code = 'INR'
      and account.is_active
  ),
  1::bigint,
  'owner creation writes one active INR account at the server-derived station'
);

select is(
  (
    select count(*)::bigint
    from public.audit_events as event
    where event.request_id =
        'c0100000-0000-0000-0000-000000000001'
      and event.action = 'customer.credit_account.created'
      and event.actor_user_id =
        '10000000-0000-0000-0000-000000000001'
      and event.actor_role = 'OWNER'
      and event.organization_id =
        'a0000000-0000-0000-0000-000000000001'
      and event.station_id =
        'a1000000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'owner creation appends one derived audit event'
);

select ok(
  (
    select not (
      event.after_state
      ?| array['phone', 'alternate_phone', 'first_name', 'last_name', 'address']
    )
    from public.audit_events as event
    where event.request_id =
      'c0100000-0000-0000-0000-000000000001'
  ),
  'customer creation audit JSON excludes PII'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Manager',
      'Created',
      '+15550102002',
      null,
      null,
      null,
      250000,
      0.18000000,
      0,
      'AFTER_GRACE_ONLY',
      30,
      'c0100000-0000-0000-0000-000000000002'
    )
  $$,
  'assigned manager can create a customer and account'
);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000002',
      'Wrong',
      'Station',
      '+15550102003'
    )
  $$,
  'P0001',
  'CCC_FORBIDDEN',
  'manager cannot create a customer at another station'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.audit_events
    where request_id = 'c0100000-0000-0000-0000-000000000002'
      and actor_role = 'MANAGER'
      and station_id = 'a1000000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'manager creation records the derived manager and assigned station'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000002',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Cross',
      'Tenant',
      '+15550102004'
    )
  $$,
  'P0001',
  'CCC_FORBIDDEN',
  'another tenant owner cannot create at Organization A'
);

select lives_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'b1000000-0000-0000-0000-000000000001',
      'Same',
      'Phone Other Tenant',
      '+15550102001',
      null,
      null,
      null,
      100000,
      0.18000000,
      0,
      'AFTER_GRACE_ONLY',
      30,
      'c0100000-0000-0000-0000-000000000003'
    )
  $$,
  'the same phone may be used in another organization'
);

reset role;

select is(
  (
    select count(distinct organization_id)::bigint
    from public.customers
    where phone = '+15550102001'
  ),
  2::bigint,
  'phone uniqueness is tenant-scoped rather than global'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000004',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Attendant',
      'Denied',
      '+15550102005'
    )
  $$,
  'P0001',
  'CCC_FORBIDDEN',
  'attendant cannot create a customer'
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
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Customer',
      'Denied',
      '+15550102006'
    )
  $$,
  'P0001',
  'CCC_FORBIDDEN',
  'customer cannot create another customer'
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
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Driver',
      'Denied',
      '+15550102007'
    )
  $$,
  'P0001',
  'CCC_FORBIDDEN',
  'driver cannot create a customer'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000007',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Unrelated',
      'Denied',
      '+15550102008'
    )
  $$,
  'P0001',
  'CCC_FORBIDDEN',
  'unrelated authenticated user cannot create a customer'
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
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Revoked',
      'Denied',
      '+15550102009'
    )
  $$,
  'P0001',
  'CCC_FORBIDDEN',
  'revoked manager cannot create a customer'
);

reset role;

select ok(
  not has_function_privilege(
    'anon',
    (
      select procedure.oid
      from pg_proc as procedure
      join pg_namespace as namespace
        on namespace.oid = procedure.pronamespace
      where namespace.nspname = 'public'
        and procedure.proname = 'create_customer_with_credit_account'
    ),
    'execute'
  ),
  'anonymous cannot execute customer creation'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Invalid',
      'Negative Limit',
      '+15550102020',
      null,
      null,
      null,
      -1
    )
  $$,
  'P0001',
  'CCC_INVALID_CREDIT_LIMIT',
  'negative credit limit is rejected'
);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Invalid',
      'Fractional Limit',
      '+15550102021',
      null,
      null,
      null,
      100.5
    )
  $$,
  'P0001',
  'CCC_INVALID_CREDIT_LIMIT',
  'fractional paise credit limit is rejected'
);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Invalid',
      'Overflow Limit',
      '+15550102022',
      null,
      null,
      null,
      9223372036854775808
    )
  $$,
  'P0001',
  'CCC_CREDIT_LIMIT_OVERFLOW',
  'credit limit beyond BIGINT is rejected with a stable error'
);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Invalid',
      'Phone',
      '555-0100'
    )
  $$,
  'P0001',
  'CCC_INVALID_PHONE',
  'customer phone must follow the documented MVP E.164 rule'
);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Invalid',
      'Rate',
      '+15550102023',
      null,
      null,
      null,
      1000,
      1.1
    )
  $$,
  'P0001',
  'CCC_INVALID_INTEREST_RATE',
  'interest rate outside the exact allowed range is rejected'
);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Invalid',
      'Grace',
      '+15550102024',
      null,
      null,
      null,
      1000,
      0.18,
      3651
    )
  $$,
  'P0001',
  'CCC_INVALID_GRACE_POLICY',
  'out-of-range grace days are rejected'
);

select throws_ok(
  $$
    select *
    from public.create_customer_with_credit_account(
      'a1000000-0000-0000-0000-000000000001',
      'Duplicate',
      'Phone',
      '+15550102001'
    )
  $$,
  'P0001',
  'CCC_DUPLICATE_PHONE',
  'duplicate phone in the same organization is rejected'
);

reset role;

select ok(
  not exists (
    select 1
    from public.customers
    where phone = any (
      array[
        '+15550102020',
        '+15550102021',
        '+15550102022',
        '+15550102023',
        '+15550102024'
      ]
    )
  )
  and not exists (
    select 1
    from public.audit_events
    where request_id = any (
      array[
        'c0100000-0000-0000-0000-000000000020'::uuid,
        'c0100000-0000-0000-0000-000000000021'::uuid,
        'c0100000-0000-0000-0000-000000000022'::uuid
      ]
    )
  ),
  'failed customer creation leaves no customer or audit rows'
);

-- Authorized fuel-credit posting.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      10000,
      'c1000000-0000-0000-0000-000000000001',
      'OWNER-POST-1'
    )
  $$,
  'owner can post a valid fuel-credit transaction'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.audit_events
    where request_id = 'c1000000-0000-0000-0000-000000000001'
      and actor_role = 'OWNER'
      and action = 'fuel_credit.posted'
  ),
  1::bigint,
  'owner posting records the derived owner role'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000002',
      11000,
      'c1000000-0000-0000-0000-000000000002',
      'MANAGER-POST-1'
    )
  $$,
  'assigned manager can post a valid fuel-credit transaction'
);

reset role;

select is(
  (
    select actor_role
    from public.audit_events
    where request_id = 'c1000000-0000-0000-0000-000000000002'
  ),
  'MANAGER'::public.app_role,
  'manager posting records the derived manager role'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000004',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      12000,
      'c1000000-0000-0000-0000-000000000003',
      'ATTENDANT-POST-1'
    )
  $$,
  'assigned attendant can post a valid fuel-credit transaction'
);

reset role;

select is(
  (
    select actor_role
    from public.audit_events
    where request_id = 'c1000000-0000-0000-0000-000000000003'
  ),
  'ATTENDANT'::public.app_role,
  'attendant posting records the derived attendant role'
);

-- Denied role, tenant, station, and entity-state cases.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000003',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000002',
      'a1000000-0000-0000-0000-000000000002',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000010'
    )
  $$,
  'P0001',
  'FCP_FORBIDDEN',
  'manager cannot post at an unassigned station'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'b3000000-0000-0000-0000-000000000001',
      'b1000000-0000-0000-0000-000000000001',
      'bf100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000011'
    )
  $$,
  'P0001',
  'FCP_FORBIDDEN',
  'owner cannot post inside another tenant'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'bf100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000012'
    )
  $$,
  'P0001',
  'FCP_TENANT_MISMATCH',
  'cross-tenant product is rejected'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000002',
      'a1000000-0000-0000-0000-000000000002',
      'af100000-0000-0000-0000-000000000002',
      1000,
      'c1000000-0000-0000-0000-000000000013'
    )
  $$,
  'P0001',
  'FCP_STATION_MISMATCH',
  'station-scoped product cannot be used at another station'
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
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000014'
    )
  $$,
  'P0001',
  'FCP_FORBIDDEN',
  'revoked manager cannot post'
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
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000015'
    )
  $$,
  'P0001',
  'FCP_FORBIDDEN',
  'customer cannot post fuel credit'
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
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000016'
    )
  $$,
  'P0001',
  'FCP_FORBIDDEN',
  'driver cannot post fuel credit'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000007',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000017'
    )
  $$,
  'P0001',
  'FCP_FORBIDDEN',
  'unrelated authenticated user cannot post'
);

reset role;

select ok(
  not has_function_privilege(
    'anon',
    'public.post_fuel_credit_transaction(uuid,uuid,uuid,numeric,uuid,text)',
    'execute'
  ),
  'anonymous cannot post fuel credit'
);

update public.customers
set status = 'INACTIVE'
where id = 'a2000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000018'
    )
  $$,
  'P0001',
  'FCP_CUSTOMER_INACTIVE',
  'inactive customer is rejected'
);

reset role;
update public.customers
set status = 'ACTIVE'
where id = 'a2000000-0000-0000-0000-000000000001';

update public.credit_accounts
set is_active = false
where id = 'a3000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000019'
    )
  $$,
  'P0001',
  'FCP_ACCOUNT_INACTIVE',
  'inactive credit account is rejected'
);

reset role;
update public.credit_accounts
set is_active = true
where id = 'a3000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000003',
      1000,
      'c1000000-0000-0000-0000-000000000020'
    )
  $$,
  'P0001',
  'FCP_PRODUCT_INACTIVE',
  'inactive fuel product is rejected'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      0,
      'c1000000-0000-0000-0000-000000000021'
    )
  $$,
  'P0001',
  'FCP_INVALID_AMOUNT',
  'zero posting is rejected'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      -1,
      'c1000000-0000-0000-0000-000000000022'
    )
  $$,
  'P0001',
  'FCP_INVALID_AMOUNT',
  'negative posting is rejected'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1.5,
      'c1000000-0000-0000-0000-000000000023'
    )
  $$,
  'P0001',
  'FCP_INVALID_AMOUNT',
  'fractional paise posting is rejected'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      9223372036854775808,
      'c1000000-0000-0000-0000-000000000024'
    )
  $$,
  'P0001',
  'FCP_AMOUNT_OVERFLOW',
  'posting beyond BIGINT is rejected with a stable overflow error'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      null
    )
  $$,
  'P0001',
  'FCP_IDEMPOTENCY_KEY_REQUIRED',
  'posting requires a high-entropy client UUID idempotency key'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000028',
      'contains spaces'
    )
  $$,
  'P0001',
  'FCP_INVALID_SOURCE_REFERENCE',
  'posting rejects an unsafe free-form source reference'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'ee000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000029'
    )
  $$,
  'P0001',
  'FCP_ACCOUNT_INVALID',
  'posting rejects an unknown credit account with a stable error'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'ee000000-0000-0000-0000-000000000002',
      1000,
      'c1000000-0000-0000-0000-000000000030'
    )
  $$,
  'P0001',
  'FCP_PRODUCT_INVALID',
  'posting rejects an unknown fuel product with a stable error'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'ee000000-0000-0000-0000-000000000003',
      'af100000-0000-0000-0000-000000000001',
      1000,
      'c1000000-0000-0000-0000-000000000031'
    )
  $$,
  'P0001',
  'FCP_STATION_INVALID',
  'posting rejects an unknown or inactive station with a stable error'
);

-- Exact-limit and insufficient-credit behavior on the ₹1,000 fixture.
select lives_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000002',
      'a1000000-0000-0000-0000-000000000002',
      'af100000-0000-0000-0000-000000000001',
      100000,
      'c1000000-0000-0000-0000-000000000025',
      'EXACT-LIMIT-1'
    )
  $$,
  'posting exactly the available credit succeeds'
);

select is(
  (
    select available_credit_paise
    from public.get_credit_account_balance(
      'a3000000-0000-0000-0000-000000000002'
    )
  ),
  0::bigint,
  'exact-limit posting leaves zero available credit'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000002',
      'a1000000-0000-0000-0000-000000000002',
      'af100000-0000-0000-0000-000000000001',
      1,
      'c1000000-0000-0000-0000-000000000026',
      'OVER-LIMIT-1'
    )
  $$,
  'P0001',
  'FCP_INSUFFICIENT_CREDIT',
  'posting above available credit is rejected'
);

reset role;

select ok(
  not exists (
    select 1
    from public.idempotency_keys
    where idempotency_key =
      'c1000000-0000-0000-0000-000000000026'
  )
  and not exists (
    select 1
    from public.audit_events
    where request_id =
      'c1000000-0000-0000-0000-000000000026'
  )
  and not exists (
    select 1
    from public.fuel_credit_sales
    where source_reference = 'OVER-LIMIT-1'
  ),
  'insufficient-credit failure leaves no idempotency, audit, or sale rows'
);

-- A failed key is reusable after correcting the amount.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      3000000,
      'c1000000-0000-0000-0000-000000000027',
      'RETRY-AFTER-FAILURE'
    )
  $$,
  'P0001',
  'FCP_INSUFFICIENT_CREDIT',
  'insufficient request fails before committing its idempotency key'
);

select lives_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      13000,
      'c1000000-0000-0000-0000-000000000027',
      'RETRY-AFTER-FAILURE'
    )
  $$,
  'the same key can be retried after a rolled-back failure'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.idempotency_keys
    where idempotency_key =
      'c1000000-0000-0000-0000-000000000027'
      and status = 'COMPLETED'
  ),
  1::bigint,
  'corrected retry commits one completed idempotency row'
);

-- Ledger shape, balance effect, audit privacy, and hard immutability.
select is(
  (
    select count(*)::bigint
    from public.ledger_transactions as transaction
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = transaction.id
    where idempotency.idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
      and transaction.transaction_type = 'FUEL_CREDIT'
      and transaction.status = 'POSTED'
      and transaction.amount_paise = 10000
  ),
  1::bigint,
  'fuel posting creates one correctly typed posted transaction header'
);

select is(
  (
    select count(*)::bigint
    from public.fuel_credit_sales as sale
    join public.idempotency_keys as idempotency
      on idempotency.response_sale_id = sale.id
    where idempotency.idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
      and sale.amount_paise = 10000
      and sale.fuel_product_id =
        'af100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'fuel posting creates one product-linked sale detail'
);

select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
      'c1000000-0000-0000-0000-000000000001'
  ),
  2::bigint,
  'fuel posting creates exactly two ledger entries'
);

select is(
  (
    select
      sum(entry.amount_paise) filter (where entry.direction = 'DEBIT')
      - sum(entry.amount_paise) filter (where entry.direction = 'CREDIT')
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
      'c1000000-0000-0000-0000-000000000001'
  ),
  0::numeric,
  'fuel posting debits equal credits'
);

select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
      and entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
      and entry.direction = 'DEBIT'
      and entry.amount_paise = 10000
  ),
  1::bigint,
  'fuel posting debits customer accounts receivable'
);

select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
      and entry.account_code = 'FUEL_SALES_REVENUE'
      and entry.direction = 'CREDIT'
      and entry.amount_paise = 10000
  ),
  1::bigint,
  'fuel posting credits fuel-sales revenue'
);

select is(
  (
    select outstanding_principal_paise
    from app_private.calculate_credit_account_balance(
      'a3000000-0000-0000-0000-000000000001'
    )
  ),
  46000::bigint,
  'multiple successful postings derive the expected principal'
);

select is(
  (
    select available_credit_paise
    from app_private.calculate_credit_account_balance(
      'a3000000-0000-0000-0000-000000000001'
    )
  ),
  2454000::bigint,
  'available credit equals limit minus derived principal'
);

select ok(
  (
    select not (
      event.after_state
      ?| array[
        'phone',
        'name',
        'address',
        'source_reference',
        'jwt',
        'token',
        'secret'
      ]
    )
    from public.audit_events as event
    where event.request_id =
      'c1000000-0000-0000-0000-000000000001'
  ),
  'financial audit JSON excludes PII, source text, and secrets'
);

select throws_ok(
  $$
    update public.ledger_transactions
    set amount_paise = amount_paise
    where id = (
      select response_transaction_id
      from public.idempotency_keys
      where idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'hard trigger rejects posted transaction update'
);

select throws_ok(
  $$
    delete from public.ledger_transactions
    where id = (
      select response_transaction_id
      from public.idempotency_keys
      where idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'hard trigger rejects posted transaction delete'
);

select throws_ok(
  $$
    update public.ledger_entries
    set amount_paise = amount_paise
    where transaction_id = (
      select response_transaction_id
      from public.idempotency_keys
      where idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'hard trigger rejects ledger entry update'
);

select throws_ok(
  $$
    delete from public.ledger_entries
    where transaction_id = (
      select response_transaction_id
      from public.idempotency_keys
      where idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'hard trigger rejects ledger entry delete'
);

select throws_ok(
  $$
    update public.fuel_credit_sales
    set amount_paise = amount_paise
    where id = (
      select response_sale_id
      from public.idempotency_keys
      where idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'hard trigger rejects fuel sale update'
);

select throws_ok(
  $$
    delete from public.fuel_credit_sales
    where id = (
      select response_sale_id
      from public.idempotency_keys
      where idempotency_key =
        'c1000000-0000-0000-0000-000000000001'
    )
  $$,
  '42501',
  'financial records are append-only',
  'hard trigger rejects fuel sale delete'
);

select throws_ok(
  $$
    update public.idempotency_keys
    set amount_paise = amount_paise
    where idempotency_key =
      'c1000000-0000-0000-0000-000000000001'
  $$,
  '42501',
  'idempotency records are immutable',
  'completed idempotency row cannot be updated'
);

select throws_ok(
  $$
    delete from public.idempotency_keys
    where idempotency_key =
      'c1000000-0000-0000-0000-000000000001'
  $$,
  '42501',
  'idempotency records are immutable',
  'completed idempotency row cannot be deleted'
);

select throws_ok(
  $$
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
      'ce000000-0000-0000-0000-000000000001',
      'a0000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a2000000-0000-0000-0000-000000000001',
      'FUEL_CREDIT',
      'POSTED',
      1000,
      'INR',
      '10000000-0000-0000-0000-000000000001'
    );
    set constraints ledger_transactions_require_balanced_entries immediate
  $$,
  '23514',
  'ledger transaction is not balanced',
  'deferred constraint rejects a posted header without entries'
);

select throws_ok(
  $$
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
      'ce000000-0000-0000-0000-000000000002',
      'a0000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'a3000000-0000-0000-0000-000000000001',
      'a2000000-0000-0000-0000-000000000001',
      'FUEL_CREDIT',
      'POSTED',
      1000,
      'INR',
      '10000000-0000-0000-0000-000000000001'
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
        'ce000000-0000-0000-0000-000000000002',
        'CUSTOMER_ACCOUNTS_RECEIVABLE',
        'DEBIT',
        1000,
        'INR'
      ),
      (
        'a0000000-0000-0000-0000-000000000001',
        'ce000000-0000-0000-0000-000000000002',
        'FUEL_SALES_REVENUE',
        'CREDIT',
        999,
        'INR'
      );
    set constraints all immediate
  $$,
  '23514',
  'ledger transaction is not balanced',
  'deferred constraint rejects unequal debit and credit entries'
);

-- Client raw-write denial.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$insert into public.ledger_transactions default values$$,
  '42501',
  'permission denied for table ledger_transactions',
  'authenticated client cannot insert transaction headers'
);

select throws_ok(
  $$insert into public.ledger_entries default values$$,
  '42501',
  'permission denied for table ledger_entries',
  'authenticated client cannot insert ledger entries'
);

select throws_ok(
  $$insert into public.fuel_credit_sales default values$$,
  '42501',
  'permission denied for table fuel_credit_sales',
  'authenticated client cannot insert fuel sales'
);

select throws_ok(
  $$insert into public.idempotency_keys default values$$,
  '42501',
  'permission denied for table idempotency_keys',
  'authenticated client cannot insert idempotency rows'
);

select throws_ok(
  $$insert into public.audit_events default values$$,
  '42501',
  'permission denied for table audit_events',
  'authenticated client cannot insert audit events'
);

reset role;

-- Balance authorization and tenant isolation.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000002',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (
    select outstanding_principal_paise
    from public.get_credit_account_balance(
      'b3000000-0000-0000-0000-000000000001'
    )
  ),
  0::bigint,
  'untouched account has zero outstanding principal'
);

select throws_ok(
  $$
    select *
    from public.get_credit_account_balance(
      'a3000000-0000-0000-0000-000000000001'
    )
  $$,
  'P0001',
  'BAL_ACCOUNT_NOT_FOUND_OR_FORBIDDEN',
  'owner cannot read another tenant balance'
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
    select *
    from public.get_credit_account_balance(
      'a3000000-0000-0000-0000-000000000002'
    )
  $$,
  'P0001',
  'BAL_ACCOUNT_NOT_FOUND_OR_FORBIDDEN',
  'manager cannot read an unassigned-station balance'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000005',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (
    select outstanding_principal_paise
    from public.get_credit_account_balance(
      'a3000000-0000-0000-0000-000000000001'
    )
  ),
  46000::bigint,
  'customer can read only the balance linked to their Auth identity'
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
    select *
    from public.get_credit_account_balance(
      'a3000000-0000-0000-0000-000000000001'
    )
  $$,
  'P0001',
  'BAL_ACCOUNT_NOT_FOUND_OR_FORBIDDEN',
  'attendant cannot broadly query account balances'
);

reset role;

-- Idempotent replay and conflicts.
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
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      10000,
      'c1000000-0000-0000-0000-000000000001',
      'OWNER-POST-1'
    )
  ),
  true,
  'same key and same payload returns an idempotent replay'
);

reset role;

select is(
  (
    select count(*)::bigint
    from public.ledger_transactions as transaction
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = transaction.id
    where idempotency.idempotency_key =
      'c1000000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'same-payload replay creates no duplicate transaction'
);

select is(
  (
    select count(*)::bigint
    from public.ledger_entries as entry
    join public.idempotency_keys as idempotency
      on idempotency.response_transaction_id = entry.transaction_id
    where idempotency.idempotency_key =
      'c1000000-0000-0000-0000-000000000001'
  ),
  2::bigint,
  'same-payload replay creates no duplicate entries'
);

select is(
  (
    select count(*)::bigint
    from public.fuel_credit_sales as sale
    join public.idempotency_keys as idempotency
      on idempotency.response_sale_id = sale.id
    where idempotency.idempotency_key =
      'c1000000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'same-payload replay creates no duplicate sale'
);

select is(
  (
    select count(*)::bigint
    from public.audit_events
    where request_id = 'c1000000-0000-0000-0000-000000000001'
      and action = 'fuel_credit.posted'
  ),
  1::bigint,
  'same-payload replay creates no duplicate audit event'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000001',
      10001,
      'c1000000-0000-0000-0000-000000000001',
      'OWNER-POST-1'
    )
  $$,
  'P0001',
  'FCP_IDEMPOTENCY_CONFLICT',
  'same key with changed amount is a deterministic conflict'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000002',
      'a1000000-0000-0000-0000-000000000002',
      'af100000-0000-0000-0000-000000000001',
      10000,
      'c1000000-0000-0000-0000-000000000001',
      'OWNER-POST-1'
    )
  $$,
  'P0001',
  'FCP_IDEMPOTENCY_CONFLICT',
  'same key with changed account is a deterministic conflict'
);

select throws_ok(
  $$
    select *
    from public.post_fuel_credit_transaction(
      'a3000000-0000-0000-0000-000000000001',
      'a1000000-0000-0000-0000-000000000001',
      'af100000-0000-0000-0000-000000000002',
      10000,
      'c1000000-0000-0000-0000-000000000001',
      'OWNER-POST-1'
    )
  $$,
  'P0001',
  'FCP_IDEMPOTENCY_CONFLICT',
  'same key with changed product is a deterministic conflict'
);

reset role;

-- Direct-read RLS by role and station.
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::bigint from public.fuel_products),
  3::bigint,
  'Owner A sees only Organization A fuel products'
);

select is(
  (select count(*)::bigint from public.ledger_transactions),
  5::bigint,
  'Owner A sees only Organization A posted transactions'
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
  (select count(*)::bigint from public.fuel_products),
  3::bigint,
  'manager sees organization-wide and assigned-station products'
);

select is(
  (select count(*)::bigint from public.ledger_transactions),
  4::bigint,
  'manager sees financial rows only at the assigned station'
);

select is(
  (select count(*)::bigint from public.ledger_entries),
  8::bigint,
  'manager sees entries only for assigned-station transactions'
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
  (select count(*)::bigint from public.fuel_products),
  3::bigint,
  'attendant sees applicable products at the assigned station'
);

select ok(
  (select count(*) = 0 from public.ledger_transactions)
  and (select count(*) = 0 from public.ledger_entries)
  and (select count(*) = 0 from public.fuel_credit_sales)
  and (select count(*) = 0 from public.idempotency_keys),
  'attendant has no broad financial-row read access'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000002',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::bigint from public.fuel_products),
  1::bigint,
  'Owner B sees only Organization B fuel products'
);

select is(
  (select count(*)::bigint from public.ledger_transactions),
  0::bigint,
  'Owner B sees no Organization A financial rows'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000005',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select ok(
  (select count(*) = 0 from public.fuel_products)
  and (select count(*) = 0 from public.ledger_transactions)
  and (select count(*) = 0 from public.ledger_entries),
  'customer has no direct product or ledger browse access'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000006',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select ok(
  (select count(*) = 0 from public.fuel_products)
  and (select count(*) = 0 from public.ledger_transactions)
  and (select count(*) = 0 from public.ledger_entries),
  'driver has no direct product or ledger browse access'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000008',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select ok(
  (select count(*) = 0 from public.fuel_products)
  and (select count(*) = 0 from public.ledger_transactions)
  and (select count(*) = 0 from public.ledger_entries),
  'revoked manager has no Phase 2A read access'
);

reset role;

select * from finish();

rollback;
