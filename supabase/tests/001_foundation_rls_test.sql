begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(64);

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
          'profiles',
          'organizations',
          'stations',
          'organization_memberships',
          'station_memberships',
          'role_assignments',
          'customers',
          'customer_account_settings',
          'credit_accounts',
          'customer_drivers',
          'driver_permissions',
          'qr_credentials',
          'interest_policies',
          'audit_events',
          'app_settings'
        ]
      )
  ),
  15::bigint,
  'all protected foundation tables exist'
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
      and relation.relname = any (
        array[
          'profiles',
          'organizations',
          'stations',
          'organization_memberships',
          'station_memberships',
          'role_assignments',
          'customers',
          'customer_account_settings',
          'credit_accounts',
          'customer_drivers',
          'driver_permissions',
          'qr_credentials',
          'interest_policies',
          'audit_events',
          'app_settings'
        ]
      )
  ),
  15::bigint,
  'RLS is enabled on every protected table'
);

select is(
  (
    select count(*)::bigint
    from pg_class as relation
    join pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relkind = 'r'
      and relation.relforcerowsecurity
      and relation.relname = any (
        array[
          'profiles',
          'organizations',
          'stations',
          'organization_memberships',
          'station_memberships',
          'role_assignments',
          'customers',
          'customer_account_settings',
          'credit_accounts',
          'customer_drivers',
          'driver_permissions',
          'qr_credentials',
          'interest_policies',
          'audit_events',
          'app_settings'
        ]
      )
  ),
  15::bigint,
  'RLS is forced on every protected table'
);

select is(
  (
    select count(*)::bigint
    from information_schema.tables as table_info
    where table_info.table_schema = 'public'
      and table_info.table_name = any (
        array[
          'profiles',
          'organizations',
          'stations',
          'organization_memberships',
          'station_memberships',
          'role_assignments',
          'customers',
          'customer_account_settings',
          'credit_accounts',
          'customer_drivers',
          'driver_permissions',
          'qr_credentials',
          'interest_policies',
          'audit_events',
          'app_settings'
        ]
      )
      and has_table_privilege(
        'anon',
        format('%I.%I', table_info.table_schema, table_info.table_name),
        'select'
      )
  ),
  0::bigint,
  'anonymous has no protected-table SELECT privileges'
);

select is(
  (
    select count(*)::bigint
    from pg_proc as procedure
    join pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where (
        namespace.nspname = 'app_private'
        or (
          namespace.nspname = 'public'
          and procedure.proname = 'get_my_driver_parent_account'
        )
      )
      and has_function_privilege('anon', procedure.oid, 'execute')
  ),
  0::bigint,
  'anonymous cannot execute privileged helpers'
);

select is(
  (
    select count(*)::bigint
    from pg_proc as procedure
    join pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where namespace.nspname in ('app_private', 'public')
      and procedure.prosecdef
      and coalesce(array_to_string(procedure.proconfig, ','), '')
        not like '%search_path=%'
  ),
  0::bigint,
  'every SECURITY DEFINER function fixes its search_path'
);

select is(
  (
    select count(distinct tablename)::bigint
    from pg_policies
    where schemaname = 'public'
      and tablename = any (
        array[
          'profiles',
          'organizations',
          'stations',
          'organization_memberships',
          'station_memberships',
          'role_assignments',
          'customers',
          'customer_account_settings',
          'credit_accounts',
          'customer_drivers',
          'driver_permissions',
          'qr_credentials',
          'interest_policies',
          'audit_events',
          'app_settings'
        ]
      )
  ),
  15::bigint,
  'every protected table has an explicit policy'
);

select is(
  (
    select count(*)::bigint
    from pg_policies
    where schemaname = 'public'
      and (
        lower(coalesce(qual, '')) ~ '(^|[^a-z_])true([^a-z_]|$)'
        or lower(coalesce(with_check, '')) ~ '(^|[^a-z_])true([^a-z_]|$)'
      )
  ),
  0::bigint,
  'no protected-table policy has an unconditional true expression'
);

select ok(
  not has_table_privilege('authenticated', 'public.role_assignments', 'insert')
  and not has_table_privilege('authenticated', 'public.role_assignments', 'update')
  and not has_table_privilege('authenticated', 'public.role_assignments', 'delete'),
  'authenticated users cannot write role assignments'
);

select ok(
  not has_table_privilege('authenticated', 'public.audit_events', 'update')
  and not has_table_privilege('authenticated', 'public.audit_events', 'delete'),
  'normal clients cannot update or delete audit events'
);

select is(
  (
    select count(*)::bigint
    from information_schema.columns
    where table_schema = 'public'
      and (
        (table_name = 'customer_account_settings' and column_name = 'credit_limit_paise')
        or (
          table_name = 'driver_permissions'
          and column_name in ('transaction_limit_paise', 'daily_limit_paise')
        )
      )
      and data_type = 'bigint'
  ),
  3::bigint,
  'all Phase 1 money-limit columns use BIGINT paise'
);

select is(
  (
    select count(*)::bigint
    from information_schema.columns
    where table_schema = 'public'
      and (
        (table_name = 'customer_account_settings' and column_name = 'default_annual_interest_rate')
        or (table_name = 'interest_policies' and column_name = 'annual_rate')
      )
      and data_type = 'numeric'
  ),
  2::bigint,
  'interest rates use exact NUMERIC storage'
);

select ok(
  (
    select is_nullable = 'NO'
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'customer_drivers'
      and column_name = 'customer_id'
  ),
  'a driver must belong to one customer'
);

select is(
  (
    select count(*)::bigint
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'customer_drivers'
      and column_name = 'credit_account_id'
  ),
  0::bigint,
  'a driver has no independent credit account'
);

select ok(
  exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'qr_credentials'
      and column_name = 'token_hash'
      and is_nullable = 'NO'
  ),
  'QR credentials require a token hash'
);

select is(
  (
    select count(*)::bigint
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'qr_credentials'
      and column_name in ('token', 'raw_token', 'secret', 'payload')
  ),
  0::bigint,
  'QR credentials expose no raw token or payload column'
);

select is(
  (
    select count(*)::bigint
    from pg_constraint
    where convalidated
      and conname = any (
        array[
          'customer_account_settings_credit_limit_non_negative',
          'customer_account_settings_rate_range',
          'customer_account_settings_grace_days_range',
          'customer_account_settings_due_days_range',
          'driver_permissions_transaction_limit_non_negative',
          'driver_permissions_daily_limit_non_negative',
          'driver_permissions_valid_dates',
          'qr_credentials_exactly_one_subject',
          'qr_credentials_hash_format',
          'qr_credentials_expiration_after_issue',
          'qr_credentials_revocation_state',
          'qr_credentials_rotation_state',
          'qr_credentials_last_used_after_issue',
          'interest_policies_rate_range',
          'interest_policies_grace_days_range',
          'interest_policies_effective_dates'
        ]
      )
  ),
  16::bigint,
  'required financial, driver, QR, and interest constraints are validated'
);

select is(
  (
    with foreign_keys as (
      select
        constraint_definition.conrelid,
        constraint_definition.conkey[1] as first_key
      from pg_constraint as constraint_definition
      join pg_class as relation
        on relation.oid = constraint_definition.conrelid
      join pg_namespace as namespace
        on namespace.oid = relation.relnamespace
      where constraint_definition.contype = 'f'
        and namespace.nspname = 'public'
    )
    select count(*)::bigint
    from foreign_keys
    where not exists (
      select 1
      from pg_index as index_definition
      where index_definition.indrelid = foreign_keys.conrelid
        and index_definition.indisvalid
        and index_definition.indkey[0] = foreign_keys.first_key
    )
  ),
  0::bigint,
  'every public foreign key has a usable leading-column index'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000001',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::bigint from public.organizations),
  1::bigint,
  'Owner A sees one organization'
);

select is(
  (select id from public.organizations order by id limit 1),
  'a0000000-0000-0000-0000-000000000001'::uuid,
  'Owner A sees Organization A'
);

select is(
  (
    select count(*)::bigint
    from public.organizations
    where id = 'b0000000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Owner A cannot access Organization B'
);

select is(
  (select count(*)::bigint from public.stations),
  2::bigint,
  'Owner A sees both stations in owned organization'
);

select is(
  (select count(*)::bigint from public.customers),
  2::bigint,
  'Owner A sees only customers in owned organization'
);

select is(
  (select count(*)::bigint from public.audit_events),
  1::bigint,
  'Owner A can read owned audit events'
);

select is(
  (select count(*)::bigint from public.qr_credentials),
  2::bigint,
  'Owner A can read owned QR credential metadata'
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
  (select count(*)::bigint from public.organizations),
  1::bigint,
  'manager sees the organization containing the assignment'
);

select is(
  (select id from public.stations order by id limit 1),
  'a1000000-0000-0000-0000-000000000001'::uuid,
  'manager sees the assigned station'
);

select is(
  (select count(*)::bigint from public.stations),
  1::bigint,
  'manager cannot see unassigned stations'
);

select is(
  (select id from public.customers order by id limit 1),
  'a2000000-0000-0000-0000-000000000001'::uuid,
  'manager sees the customer at the assigned station'
);

select is(
  (select count(*)::bigint from public.customers),
  1::bigint,
  'manager cannot browse another station customer'
);

select is(
  (select count(*)::bigint from public.app_settings),
  1::bigint,
  'manager sees only non-protected assigned-station settings'
);

select is(
  (select count(*)::bigint from public.audit_events),
  1::bigint,
  'manager sees audit events only at the assigned station'
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
  (select count(*)::bigint from public.stations),
  1::bigint,
  'attendant sees the assigned station'
);

select is(
  (select count(*)::bigint from public.customers),
  0::bigint,
  'attendant cannot broadly browse customers'
);

select is(
  (select count(*)::bigint from public.customer_account_settings),
  0::bigint,
  'attendant cannot read credit limits'
);

select ok(
  not has_column_privilege(
    'authenticated',
    'public.customer_account_settings',
    'credit_limit_paise',
    'update'
  ),
  'attendant cannot change credit limits'
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
  (select id from public.customers order by id limit 1),
  'a2000000-0000-0000-0000-000000000001'::uuid,
  'customer sees their own customer row'
);

select is(
  (select count(*)::bigint from public.customers),
  1::bigint,
  'customer cannot read other customer rows'
);

select is(
  (select count(*)::bigint from public.customer_account_settings),
  1::bigint,
  'customer sees only their account settings'
);

select is(
  (select count(*)::bigint from public.credit_accounts),
  1::bigint,
  'customer sees only their credit account'
);

select is(
  (select count(*)::bigint from public.customer_drivers),
  2::bigint,
  'customer can see drivers attached to their account'
);

select is(
  (select count(*)::bigint from public.organizations),
  1::bigint,
  'customer sees only their linked organization'
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
  (select count(*)::bigint from public.customers),
  0::bigint,
  'driver cannot directly browse parent customer PII'
);

select is(
  (select id from public.customer_drivers order by id limit 1),
  'a4000000-0000-0000-0000-000000000001'::uuid,
  'driver sees only their active driver record'
);

select is(
  (select count(*)::bigint from public.driver_permissions),
  1::bigint,
  'driver sees only their permissions'
);

select is(
  (select count(*)::bigint from public.get_my_driver_parent_account()),
  1::bigint,
  'driver receives one minimal parent-account projection'
);

select is(
  (
    select credit_limit_paise
    from public.get_my_driver_parent_account()
  ),
  2500000::bigint,
  'driver parent-account projection contains the permitted credit limit'
);

select is(
  app_private.is_organization_owner(
    'a0000000-0000-0000-0000-000000000001'::uuid
  ),
  false,
  'driver cannot spoof organization ownership through a helper argument'
);

select is(
  (select count(*)::bigint from public.qr_credentials),
  0::bigint,
  'driver cannot read QR hashes'
);

select is(
  (select count(*)::bigint from public.profiles),
  1::bigint,
  'driver can read only their own profile'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.role_assignments',
    'update'
  ),
  'a user cannot modify their own role'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.organizations',
    'update'
  ),
  'a user cannot spoof organization ownership'
);

select ok(
  not has_table_privilege(
    'authenticated',
    'public.stations',
    'update'
  ),
  'a user cannot spoof station ownership'
);

select ok(
  not has_column_privilege(
    'authenticated',
    'public.app_settings',
    'organization_id',
    'update'
  )
  and not has_column_privilege(
    'authenticated',
    'public.app_settings',
    'station_id',
    'update'
  ),
  'setting writers cannot move a setting across tenant or station scope'
);

reset role;

select throws_ok(
  $$
    update public.audit_events
    set action = 'fixture.tampered'
    where id = 'a9000000-0000-0000-0000-000000000001'
  $$,
  '42501',
  'audit events are append-only',
  'audit trigger rejects privileged updates'
);

select throws_ok(
  $$
    delete from public.audit_events
    where id = 'a9000000-0000-0000-0000-000000000001'
  $$,
  '42501',
  'audit events are append-only',
  'audit trigger rejects privileged deletes'
);

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000008',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::bigint from public.organizations),
  0::bigint,
  'revoked membership loses organization access'
);

select is(
  (select count(*)::bigint from public.stations),
  0::bigint,
  'revoked membership loses station access'
);

select is(
  (select count(*)::bigint from public.customers),
  0::bigint,
  'revoked membership loses customer access'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000009',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::bigint from public.customer_drivers),
  0::bigint,
  'revoked driver cannot read a driver record'
);

select is(
  (select count(*)::bigint from public.driver_permissions),
  0::bigint,
  'revoked driver cannot read permissions'
);

select is(
  (select count(*)::bigint from public.get_my_driver_parent_account()),
  0::bigint,
  'revoked driver cannot access parent-account details'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '10000000-0000-0000-0000-000000000007',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::bigint from public.organizations),
  0::bigint,
  'unrelated authenticated user sees no organization'
);

select is(
  (select count(*)::bigint from public.customers),
  0::bigint,
  'unrelated authenticated user sees no customer'
);

reset role;

select * from finish();

rollback;
