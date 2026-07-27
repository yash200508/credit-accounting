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
  expected_authenticated_public_definers oid[] := array[
    to_regprocedure(
      'public.approve_and_execute_financial_correction(uuid,integer)'
    ),
    to_regprocedure(
      'public.cancel_financial_correction_request(uuid,integer,text)'
    ),
    to_regprocedure(
      'public.create_customer_with_credit_account(uuid,text,text,text,text,text,text,numeric,numeric,integer,public.interest_grace_policy_type,integer,uuid)'
    ),
    to_regprocedure('public.get_credit_account_balance(uuid)'),
    to_regprocedure('public.get_credit_account_obligations(uuid)'),
    to_regprocedure('public.get_financial_correction_impact(uuid)'),
    to_regprocedure('public.get_my_driver_parent_account()'),
    to_regprocedure(
      'public.post_customer_repayment(uuid,uuid,numeric,text,uuid,numeric,numeric,uuid,text,text)'
    ),
    to_regprocedure(
      'public.post_fuel_credit_transaction(uuid,uuid,uuid,numeric,uuid,text)'
    ),
    to_regprocedure(
      'public.reject_financial_correction_request(uuid,integer,text)'
    ),
    to_regprocedure(
      'public.submit_financial_correction_request(uuid,text,text,text,uuid,uuid,numeric,text,numeric,text,numeric,numeric,uuid,text,text)'
    )
  ]::oid[];
  expected_authenticated_private_definers oid[] := array[
    to_regprocedure('app_private.can_access_organization(uuid)'),
    to_regprocedure('app_private.can_access_station(uuid)'),
    to_regprocedure('app_private.can_read_audit_event(uuid,uuid)'),
    to_regprocedure('app_private.can_read_customer(uuid)'),
    to_regprocedure('app_private.can_read_customer_repayment(uuid)'),
    to_regprocedure('app_private.can_read_driver(uuid)'),
    to_regprocedure('app_private.can_read_financial_station(uuid,uuid)'),
    to_regprocedure('app_private.can_read_fuel_product(uuid,uuid)'),
    to_regprocedure('app_private.can_read_interest_policy(uuid,uuid)'),
    to_regprocedure('app_private.can_read_ledger_transaction(uuid)'),
    to_regprocedure('app_private.is_customer(uuid)'),
    to_regprocedure('app_private.is_driver_linked_to_customer(uuid)'),
    to_regprocedure('app_private.is_organization_owner(uuid)'),
    to_regprocedure('app_private.is_station_attendant(uuid)'),
    to_regprocedure('app_private.is_station_manager(uuid)')
  ]::oid[];
  expected_authenticated_definers oid[];
  actual_authenticated_definers oid[];
  actual_authenticated_public_definers oid[];
  actual_cron_public_relation_acl text[];
  actual_cron_public_function_acl text[];
  finding text;
begin
  expected_authenticated_definers :=
    expected_authenticated_private_definers
    || expected_authenticated_public_definers;

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

  if array_position(expected_authenticated_definers, null) is not null then
    raise exception 'P2E_AUTHENTICATED_DEFINER_ALLOWLIST_OBJECT_MISSING';
  end if;

  select array_agg(
    p.oid
    order by n.nspname, p.proname, pg_catalog.oidvectortypes(p.proargtypes)
  )
    into actual_authenticated_definers
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'app_private')
    and p.prosecdef
    and has_function_privilege('authenticated', p.oid, 'execute');

  if actual_authenticated_definers
       is distinct from expected_authenticated_definers then
    raise exception 'P2E_AUTHENTICATED_DEFINER_ALLOWLIST_MISMATCH';
  end if;

  select array_agg(
    p.oid
    order by p.proname, pg_catalog.oidvectortypes(p.proargtypes)
  )
    into actual_authenticated_public_definers
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and has_function_privilege('authenticated', p.oid, 'execute');

  if actual_authenticated_public_definers
       is distinct from expected_authenticated_public_definers then
    raise exception 'P2E_AUTHENTICATED_PUBLIC_RPC_ALLOWLIST_MISMATCH';
  end if;

  select string_agg(p.oid::regprocedure::text, ', ')
    into finding
  from pg_proc p
  where p.oid = any(expected_authenticated_public_definers)
    and (
      not p.prosecdef
      or not exists (
        select 1
        from unnest(coalesce(p.proconfig, array[]::text[])) setting
        where setting = 'search_path=""'
           or setting = 'search_path='
      )
      or pg_get_functiondef(p.oid)
           !~ 'auth[.]uid[[:space:]]*[(][[:space:]]*[)]'
      or (
        p.proname <> 'get_my_driver_parent_account'
        and pg_get_functiondef(p.oid)
              !~ 'app_private[.](is_|can_)'
      )
      or pg_get_functiondef(p.oid) ~* '\mexecute\M'
      or pg_get_function_identity_arguments(p.oid) ~* (
        '\m(p_)?(actor|organization|requester|approver|executed_by|'
        || 'created_by|updated_by|user)_id\M'
      )
      or not exists (
        select 1
        from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner)))
          privilege
        where privilege.grantee = (
          select oid
          from pg_roles
          where rolname = 'authenticated'
        )
          and privilege.privilege_type = 'EXECUTE'
      )
      or exists (
        select 1
        from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner)))
          privilege
        left join pg_roles grantee on grantee.oid = privilege.grantee
        where privilege.privilege_type = 'EXECUTE'
          and (
            privilege.grantee = 0
            or grantee.rolname = 'anon'
          )
      )
    );
  if finding is not null then
    raise exception 'P2E_AUTHENTICATED_PUBLIC_RPC_HARDENING: %', finding;
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
      'fuel_credit_correction_proposals',
      'fuel_credit_sales',
      'idempotency_keys',
      'interest_accrual_components',
      'interest_accrual_runs',
      'interest_accruals',
      'ledger_entries',
      'ledger_transactions',
      'repayment_allocations',
      'repayment_correction_proposals'
    )
    and (
      has_table_privilege('service_role', c.oid, 'insert')
      or has_table_privilege('service_role', c.oid, 'update')
      or has_table_privilege('service_role', c.oid, 'delete')
      or has_table_privilege('service_role', c.oid, 'truncate')
      or has_table_privilege('authenticated', c.oid, 'insert')
      or has_table_privilege('authenticated', c.oid, 'update')
      or has_table_privilege('authenticated', c.oid, 'delete')
      or has_table_privilege('authenticated', c.oid, 'truncate')
      or has_table_privilege('anon', c.oid, 'insert')
      or has_table_privilege('anon', c.oid, 'update')
      or has_table_privilege('anon', c.oid, 'delete')
      or has_table_privilege('anon', c.oid, 'truncate')
    );
  if finding is not null then
    raise exception 'P2E_RAW_FINANCIAL_MUTATION_GRANT: %', finding;
  end if;

  select string_agg(c.relname, ', ' order by c.relname)
    into finding
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and (
      has_table_privilege('service_role', c.oid, 'select')
      or has_table_privilege('service_role', c.oid, 'insert')
      or has_table_privilege('service_role', c.oid, 'update')
      or has_table_privilege('service_role', c.oid, 'delete')
      or has_table_privilege('service_role', c.oid, 'truncate')
      or has_table_privilege('service_role', c.oid, 'references')
      or has_table_privilege('service_role', c.oid, 'trigger')
      or has_table_privilege('service_role', c.oid, 'maintain')
      or has_any_column_privilege('service_role', c.oid, 'select')
      or has_any_column_privilege('service_role', c.oid, 'insert')
      or has_any_column_privilege('service_role', c.oid, 'update')
      or has_any_column_privilege('service_role', c.oid, 'references')
    );
  if finding is not null then
    raise exception 'P2E_SERVICE_ROLE_TABLE_ALLOWLIST: %', finding;
  end if;

  if has_table_privilege('service_role', 'public.audit_events', 'select')
     or has_table_privilege('service_role', 'public.audit_events', 'insert')
     or has_table_privilege('service_role', 'public.audit_events', 'update')
     or has_table_privilege('service_role', 'public.audit_events', 'delete')
     or has_table_privilege('service_role', 'public.audit_events', 'truncate')
     or has_table_privilege('service_role', 'public.audit_events', 'references')
     or has_table_privilege('service_role', 'public.audit_events', 'trigger')
     or has_table_privilege('service_role', 'public.audit_events', 'maintain')
  then
    raise exception 'P2E_SERVICE_ROLE_AUDIT_EVENTS_PRIVILEGE';
  end if;

  select string_agg(p.oid::regprocedure::text, ', ')
    into finding
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and has_function_privilege('service_role', p.oid, 'execute');
  if finding is not null then
    raise exception 'P2E_SERVICE_ROLE_RPC_ALLOWLIST: %', finding;
  end if;

  select string_agg(
    coalesce(grantee.rolname, 'PUBLIC') || ':' || privilege.privilege_type,
    ', '
  )
    into finding
  from pg_default_acl default_acl
  join pg_namespace n on n.oid = default_acl.defaclnamespace
  cross join lateral aclexplode(default_acl.defaclacl) privilege
  left join pg_roles grantee on grantee.oid = privilege.grantee
  where default_acl.defaclrole = (
      select oid from pg_roles where rolname = 'postgres'
    )
    and n.nspname = 'public'
    and default_acl.defaclobjtype = 'r'
    and (
      privilege.grantee = 0
      or grantee.rolname in ('anon', 'authenticated', 'service_role')
    );
  if finding is not null then
    raise exception 'P2E_UNSAFE_DEFAULT_TABLE_PRIVILEGE: %', finding;
  end if;

  select string_agg(
    coalesce(grantee.rolname, 'PUBLIC') || ':' || privilege.privilege_type,
    ', '
  )
    into finding
  from pg_default_acl default_acl
  join pg_namespace n on n.oid = default_acl.defaclnamespace
  cross join lateral aclexplode(default_acl.defaclacl) privilege
  left join pg_roles grantee on grantee.oid = privilege.grantee
  where default_acl.defaclrole = (
      select oid from pg_roles where rolname = 'postgres'
    )
    and n.nspname = 'public'
    and default_acl.defaclobjtype = 'S'
    and (
      privilege.grantee = 0
      or grantee.rolname in ('anon', 'authenticated', 'service_role')
    );
  if finding is not null then
    raise exception 'P2E_UNSAFE_DEFAULT_SEQUENCE_PRIVILEGE: %', finding;
  end if;

  select string_agg(
    coalesce(grantee.rolname, 'PUBLIC') || ':' || privilege.privilege_type,
    ', '
  )
    into finding
  from pg_default_acl default_acl
  left join pg_namespace n on n.oid = default_acl.defaclnamespace
  cross join lateral aclexplode(default_acl.defaclacl) privilege
  left join pg_roles grantee on grantee.oid = privilege.grantee
  where default_acl.defaclrole = (
      select oid from pg_roles where rolname = 'postgres'
    )
    and (
      default_acl.defaclnamespace = 0
      or n.nspname = 'public'
    )
    and default_acl.defaclobjtype = 'f'
    and privilege.privilege_type = 'EXECUTE'
    and (
      privilege.grantee = 0
      or grantee.rolname in ('anon', 'authenticated', 'service_role')
    );
  if finding is not null then
    raise exception 'P2E_UNSAFE_DEFAULT_FUNCTION_EXECUTE: %', finding;
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

  select string_agg(
    format(
      '%I.%I:%s:%s',
      n.nspname,
      c.relname,
      coalesce(grantee.rolname, 'PUBLIC'),
      privilege.privilege_type
    ),
    ', '
  )
    into finding
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(
    coalesce(c.relacl, acldefault('r', c.relowner))
  ) privilege
  left join pg_roles grantee on grantee.oid = privilege.grantee
  where n.nspname = 'cron'
    and grantee.rolname in ('anon', 'authenticated', 'service_role');
  if finding is not null then
    raise exception 'P2E_CRON_DIRECT_API_RELATION_PRIVILEGE: %', finding;
  end if;

  select array_agg(
    c.relname || ':' || privilege.privilege_type
    order by c.relname, privilege.privilege_type
  )
    into actual_cron_public_relation_acl
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(
    coalesce(c.relacl, acldefault('r', c.relowner))
  ) privilege
  where n.nspname = 'cron'
    and privilege.grantee = 0;

  if actual_cron_public_relation_acl is distinct from array[
    'job:SELECT',
    'job_run_details:DELETE',
    'job_run_details:SELECT'
  ]::text[] then
    raise exception 'P2E_CRON_EXTENSION_RELATION_ACL_DRIFT';
  end if;

  select string_agg(
    format(
      '%I.%I:%s:%s',
      n.nspname,
      p.proname,
      coalesce(grantee.rolname, 'PUBLIC'),
      privilege.privilege_type
    ),
    ', '
  )
    into finding
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join lateral aclexplode(
    coalesce(p.proacl, acldefault('f', p.proowner))
  ) privilege
  left join pg_roles grantee on grantee.oid = privilege.grantee
  where n.nspname = 'cron'
    and privilege.privilege_type = 'EXECUTE'
    and grantee.rolname in ('anon', 'authenticated', 'service_role');
  if finding is not null then
    raise exception 'P2E_CRON_DIRECT_API_FUNCTION_PRIVILEGE: %', finding;
  end if;

  select array_agg(
    format(
      '%s(%s):%s',
      p.proname,
      pg_get_function_identity_arguments(p.oid),
      privilege.privilege_type
    )
    order by
      p.proname,
      pg_get_function_identity_arguments(p.oid),
      privilege.privilege_type
  )
    into actual_cron_public_function_acl
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join lateral aclexplode(
    coalesce(p.proacl, acldefault('f', p.proowner))
  ) privilege
  where n.nspname = 'cron'
    and privilege.grantee = 0
    and privilege.privilege_type = 'EXECUTE';

  if actual_cron_public_function_acl is distinct from array[
    'job_cache_invalidate():EXECUTE',
    'schedule(job_name text, schedule text, command text):EXECUTE',
    'schedule(schedule text, command text):EXECUTE',
    'unschedule(job_id bigint):EXECUTE',
    'unschedule(job_name text):EXECUTE'
  ]::text[] then
    raise exception 'P2E_CRON_EXTENSION_FUNCTION_ACL_DRIFT';
  end if;

  if (
    select count(*)
    from cron.job
    where jobname = 'credit-accounting-hourly-interest-accrual'
      and schedule = '7 * * * *'
      and command = 'select app_private.run_hourly_interest_accrual();'
      and username = 'postgres'
      and active
  ) <> 1 then
    raise exception 'P2E_CRON_JOB_MISSING_DUPLICATE_OR_CHANGED';
  end if;

  if not has_function_privilege(
    'postgres',
    'app_private.run_hourly_interest_accrual()',
    'execute'
  ) then
    raise exception 'P2E_CRON_OWNER_CANNOT_EXECUTE_ENTRYPOINT';
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
