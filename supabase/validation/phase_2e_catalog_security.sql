\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

begin;
set local statement_timeout = '30s';
set local lock_timeout = '5s';

do $phase_2e$
declare
  actual_tables text[];
  expected_tables constant text[] := array[
    'app_settings',
    'audit_events',
    'credit_accounts',
    'customer_account_settings',
    'customer_drivers',
    'customer_repayments',
    'customers',
    'driver_permissions',
    'financial_correction_events',
    'financial_correction_requests',
    'financial_reversals',
    'fuel_credit_correction_proposals',
    'fuel_credit_sales',
    'fuel_products',
    'idempotency_keys',
    'interest_accrual_components',
    'interest_accrual_runs',
    'interest_accruals',
    'interest_policies',
    'ledger_entries',
    'ledger_transactions',
    'organization_memberships',
    'organizations',
    'profiles',
    'qr_credentials',
    'repayment_allocations',
    'repayment_correction_proposals',
    'role_assignments',
    'station_memberships',
    'stations'
  ]::text[];
  finding text;
begin
  if to_regnamespace('app_private') is null
     or to_regnamespace('cron') is null then
    raise exception 'P2E_SCHEMA_MISSING';
  end if;

  if not exists (
    select 1
    from pg_extension e
    join pg_namespace n on n.oid = e.extnamespace
    where e.extname = 'btree_gist'
      and n.nspname = 'extensions'
  ) then
    raise exception 'P2E_BTREE_GIST_MISSING_OR_MISPLACED';
  end if;

  if not exists (
    select 1
    from pg_extension
    where extname = 'pg_cron'
  ) then
    raise exception 'P2E_PG_CRON_MISSING';
  end if;

  select array_agg(c.relname order by c.relname)
    into actual_tables
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p');

  if actual_tables is distinct from expected_tables then
    raise exception 'P2E_PUBLIC_TABLE_SET_MISMATCH';
  end if;

  select string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    into finding
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and (not c.relrowsecurity or not c.relforcerowsecurity);
  if finding is not null then
    raise exception 'P2E_RLS_NOT_ENABLED_AND_FORCED: %', finding;
  end if;

  select string_agg(format('%I.%I:%I', schemaname, tablename, policyname), ', ')
    into finding
  from pg_policies
  where schemaname = 'public'
    and (
      coalesce(qual, '') ~* '^\s*(true|\(true\))\s*$'
      or coalesce(with_check, '') ~* '^\s*(true|\(true\))\s*$'
    );
  if finding is not null then
    raise exception 'P2E_BROAD_RLS_POLICY: %', finding;
  end if;

  select string_agg(format('%I.%I', n.nspname, p.proname), ', ')
    into finding
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'app_private')
    and not exists (
      select 1
      from unnest(coalesce(p.proconfig, array[]::text[])) setting
      where setting = 'search_path=""'
         or setting = 'search_path='
    );
  if finding is not null then
    raise exception 'P2E_MUTABLE_FUNCTION_SEARCH_PATH: %', finding;
  end if;

  select string_agg(format('%I.%I', n.nspname, p.proname), ', ')
    into finding
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'app_private')
    and p.prosecdef
    and (
      exists (
        select 1
        from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) privilege
        where privilege.grantee = 0
          and privilege.privilege_type = 'EXECUTE'
      )
      or has_function_privilege('anon', p.oid, 'execute')
    );
  if finding is not null then
    raise exception 'P2E_DEFINER_EXECUTABLE_BY_PUBLIC_OR_ANON: %', finding;
  end if;

  select string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    into finding
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('v', 'm')
    and not (
      c.relkind = 'v'
      and coalesce(c.reloptions @> array['security_invoker=true'], false)
    );
  if finding is not null then
    raise exception 'P2E_VIEW_MAY_BYPASS_RLS: %', finding;
  end if;

  select string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    into finding
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in (
      'audit_events',
      'customer_repayments',
      'financial_correction_events',
      'financial_correction_requests',
      'financial_reversals',
      'fuel_credit_sales',
      'idempotency_keys',
      'interest_accrual_components',
      'interest_accrual_runs',
      'interest_accruals',
      'ledger_entries',
      'ledger_transactions',
      'repayment_allocations'
    )
    and (
      has_table_privilege('service_role', c.oid, 'insert')
      or has_table_privilege('service_role', c.oid, 'update')
      or has_table_privilege('service_role', c.oid, 'delete')
      or has_table_privilege('authenticated', c.oid, 'insert')
      or has_table_privilege('authenticated', c.oid, 'update')
      or has_table_privilege('authenticated', c.oid, 'delete')
      or has_table_privilege('anon', c.oid, 'insert')
      or has_table_privilege('anon', c.oid, 'update')
      or has_table_privilege('anon', c.oid, 'delete')
    );
  if finding is not null then
    raise exception 'P2E_RAW_FINANCIAL_MUTATION_GRANT: %', finding;
  end if;

  if has_schema_privilege('anon', 'app_private', 'usage')
     or has_schema_privilege('service_role', 'app_private', 'usage') then
    raise exception 'P2E_PRIVATE_SCHEMA_USAGE_GRANT';
  end if;

  if has_schema_privilege('anon', 'cron', 'usage')
     or has_schema_privilege('authenticated', 'cron', 'usage')
     or has_schema_privilege('service_role', 'cron', 'usage') then
    raise exception 'P2E_CRON_SCHEMA_USAGE_GRANT';
  end if;

  if (
    select count(*)
    from cron.job
    where jobname = 'credit-accounting-hourly-interest-accrual'
      and schedule = '7 * * * *'
      and command = 'select app_private.run_hourly_interest_accrual();'
      and active
  ) <> 1 then
    raise exception 'P2E_CRON_JOB_MISSING_DUPLICATE_OR_CHANGED';
  end if;

  if exists (
    select 1
    from cron.job
    where jobname = 'credit-accounting-hourly-interest-accrual'
      and command ~* '(https?://|authorization|bearer|apikey|secret|password)'
  ) then
    raise exception 'P2E_CRON_COMMAND_CONTAINS_CREDENTIAL_OR_HTTP';
  end if;
end
$phase_2e$;

select 'PASS: hosted catalog, RLS, grants, function search paths, and cron registration';
rollback;
