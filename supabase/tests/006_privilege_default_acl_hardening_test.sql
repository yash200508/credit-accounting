begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select no_plan();

-- Interest evidence remains readable through RLS, never directly writable.
select ok(
  has_table_privilege(
    'authenticated',
    'public.interest_accrual_components',
    'select'
  )
  and has_table_privilege(
    'authenticated',
    'public.interest_accrual_runs',
    'select'
  )
  and has_table_privilege(
    'authenticated',
    'public.interest_accruals',
    'select'
  ),
  'authenticated retains read-only access to all interest evidence'
);

select ok(
  not exists (
    select 1
    from unnest(
      array[
        'public.interest_accrual_components',
        'public.interest_accrual_runs',
        'public.interest_accruals'
      ]::text[]
    ) as target(table_name)
    cross join unnest(
      array['insert', 'update', 'delete', 'truncate']::text[]
    ) as requested(privilege_name)
    where has_table_privilege(
      'authenticated',
      target.table_name,
      requested.privilege_name
    )
  ),
  'authenticated cannot insert, update, delete, or truncate interest evidence'
);

select ok(
  (
    select bool_and(relation.relrowsecurity and relation.relforcerowsecurity)
    from pg_class relation
    join pg_namespace namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relname in (
        'interest_accrual_components',
        'interest_accrual_runs',
        'interest_accruals'
      )
  )
  and (
    select count(*) = 3
    from pg_policies
    where schemaname = 'public'
      and tablename in (
        'interest_accrual_components',
        'interest_accrual_runs',
        'interest_accruals'
      )
      and cmd = 'SELECT'
      and 'authenticated' = any(roles::text[])
      and coalesce(qual, '') !~* '^\s*(true|\(true\))\s*$'
  ),
  'authenticated interest reads remain constrained by forced scoped RLS'
);

-- The public service-role allowlist is intentionally empty.
select ok(
  not exists (
    select 1
    from unnest(
      array[
        'select',
        'insert',
        'update',
        'delete',
        'truncate',
        'references',
        'trigger',
        'maintain'
      ]::text[]
    ) as requested(privilege_name)
    where has_table_privilege(
      'service_role',
      'public.audit_events',
      requested.privilege_name
    )
  ),
  'service_role has no access to immutable audit events'
);

select ok(
  not exists (
    select 1
    from pg_class relation
    join pg_namespace namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relkind in ('r', 'p')
      and (
        has_table_privilege('service_role', relation.oid, 'select')
        or has_table_privilege('service_role', relation.oid, 'insert')
        or has_table_privilege('service_role', relation.oid, 'update')
        or has_table_privilege('service_role', relation.oid, 'delete')
        or has_table_privilege('service_role', relation.oid, 'truncate')
        or has_table_privilege('service_role', relation.oid, 'references')
        or has_table_privilege('service_role', relation.oid, 'trigger')
        or has_table_privilege('service_role', relation.oid, 'maintain')
        or has_any_column_privilege(
          'service_role',
          relation.oid,
          'select'
        )
        or has_any_column_privilege(
          'service_role',
          relation.oid,
          'insert'
        )
        or has_any_column_privilege(
          'service_role',
          relation.oid,
          'update'
        )
        or has_any_column_privilege(
          'service_role',
          relation.oid,
          'references'
        )
      )
  ),
  'service_role has no current public table or column privileges'
);

select ok(
  not exists (
    select 1
    from pg_proc function
    join pg_namespace namespace
      on namespace.oid = function.pronamespace
    where namespace.nspname = 'public'
      and has_function_privilege(
        'service_role',
        function.oid,
        'execute'
      )
  ),
  'service_role has no public RPC execution grant'
);

-- Default privileges keep all future public objects private.
select is(
  (
    select count(*)::bigint
    from pg_default_acl default_acl
    join pg_namespace namespace
      on namespace.oid = default_acl.defaclnamespace
    cross join lateral aclexplode(default_acl.defaclacl) privilege
    left join pg_roles grantee on grantee.oid = privilege.grantee
    where default_acl.defaclrole = (
        select oid from pg_roles where rolname = 'postgres'
      )
      and namespace.nspname = 'public'
      and default_acl.defaclobjtype = 'r'
      and (
        privilege.grantee = 0
        or grantee.rolname in ('anon', 'authenticated', 'service_role')
      )
  ),
  0::bigint,
  'future public tables receive no automatic API-role privilege'
);

select is(
  (
    select count(*)::bigint
    from pg_default_acl default_acl
    join pg_namespace namespace
      on namespace.oid = default_acl.defaclnamespace
    cross join lateral aclexplode(default_acl.defaclacl) privilege
    left join pg_roles grantee on grantee.oid = privilege.grantee
    where default_acl.defaclrole = (
        select oid from pg_roles where rolname = 'postgres'
      )
      and namespace.nspname = 'public'
      and default_acl.defaclobjtype = 'S'
      and (
        privilege.grantee = 0
        or grantee.rolname in ('anon', 'authenticated', 'service_role')
      )
  ),
  0::bigint,
  'future public sequences receive no automatic API-role privilege'
);

select is(
  (
    select count(*)::bigint
    from pg_default_acl default_acl
    left join pg_namespace namespace
      on namespace.oid = default_acl.defaclnamespace
    cross join lateral aclexplode(default_acl.defaclacl) privilege
    left join pg_roles grantee on grantee.oid = privilege.grantee
    where default_acl.defaclrole = (
        select oid from pg_roles where rolname = 'postgres'
      )
      and (
        default_acl.defaclnamespace = 0
        or namespace.nspname = 'public'
      )
      and default_acl.defaclobjtype = 'f'
      and privilege.privilege_type = 'EXECUTE'
      and (
        privilege.grantee = 0
        or grantee.rolname in ('anon', 'authenticated', 'service_role')
      )
  ),
  0::bigint,
  'future public functions receive no automatic API-role execution'
);

create table public.phase_2e_default_acl_table_probe (
  id bigint primary key
);
create sequence public.phase_2e_default_acl_sequence_probe;
create function public.phase_2e_default_acl_function_probe()
returns integer
language sql
set search_path = ''
as $$
  select 1;
$$;

select ok(
  not exists (
    select 1
    from pg_class relation
    join pg_namespace namespace
      on namespace.oid = relation.relnamespace
    cross join lateral aclexplode(
      coalesce(relation.relacl, acldefault('r', relation.relowner))
    ) privilege
    left join pg_roles grantee on grantee.oid = privilege.grantee
    where namespace.nspname = 'public'
      and relation.relname = 'phase_2e_default_acl_table_probe'
      and (
        privilege.grantee = 0
        or grantee.rolname in ('anon', 'authenticated', 'service_role')
      )
  ),
  'a newly created public table is not auto-exposed'
);

select ok(
  not has_sequence_privilege(
    'anon',
    'public.phase_2e_default_acl_sequence_probe',
    'usage'
  )
  and not has_sequence_privilege(
    'authenticated',
    'public.phase_2e_default_acl_sequence_probe',
    'usage'
  )
  and not has_sequence_privilege(
    'service_role',
    'public.phase_2e_default_acl_sequence_probe',
    'usage'
  ),
  'a newly created public sequence is not auto-exposed'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.phase_2e_default_acl_function_probe()',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'public.phase_2e_default_acl_function_probe()',
    'execute'
  )
  and not has_function_privilege(
    'service_role',
    'public.phase_2e_default_acl_function_probe()',
    'execute'
  ),
  'a newly created public function has no automatic execution grant'
);

-- Cron remains owner-only and unchanged.
select is(
  (
    select count(*)::bigint
    from cron.job
    where jobname = 'credit-accounting-hourly-interest-accrual'
      and schedule = '7 * * * *'
      and command = 'select app_private.run_hourly_interest_accrual();'
      and username = 'postgres'
      and active
  ),
  1::bigint,
  'the internal hourly cron job remains registered exactly once'
);

select ok(
  not has_schema_privilege('anon', 'cron', 'usage')
  and not has_schema_privilege('authenticated', 'cron', 'usage')
  and not has_schema_privilege('service_role', 'cron', 'usage'),
  'API roles cannot use the cron schema'
);

select ok(
  not exists (
    select 1
    from pg_class relation
    join pg_namespace namespace
      on namespace.oid = relation.relnamespace
    cross join lateral aclexplode(
      coalesce(relation.relacl, acldefault('r', relation.relowner))
    ) privilege
    left join pg_roles grantee on grantee.oid = privilege.grantee
    where namespace.nspname = 'cron'
      and grantee.rolname in ('anon', 'authenticated', 'service_role')
  )
  and (
    select array_agg(
      relation.relname || ':' || privilege.privilege_type
      order by relation.relname, privilege.privilege_type
    )
    from pg_class relation
    join pg_namespace namespace
      on namespace.oid = relation.relnamespace
    cross join lateral aclexplode(
      coalesce(relation.relacl, acldefault('r', relation.relowner))
    ) privilege
    where namespace.nspname = 'cron'
      and privilege.grantee = 0
  ) is not distinct from array[
    'job:SELECT',
    'job_run_details:DELETE',
    'job_run_details:SELECT'
  ]::text[],
  'cron relations expose only the pinned dormant extension-owned PUBLIC ACL'
);

select ok(
  not exists (
    select 1
    from pg_proc function
    join pg_namespace namespace
      on namespace.oid = function.pronamespace
    cross join lateral aclexplode(
      coalesce(
        function.proacl,
        acldefault('f', function.proowner)
      )
    ) privilege
    left join pg_roles grantee on grantee.oid = privilege.grantee
    where namespace.nspname = 'cron'
      and privilege.privilege_type = 'EXECUTE'
      and grantee.rolname in ('anon', 'authenticated', 'service_role')
  )
  and (
    select array_agg(
      format(
        '%s(%s):%s',
        function.proname,
        pg_get_function_identity_arguments(function.oid),
        privilege.privilege_type
      )
      order by
        function.proname,
        pg_get_function_identity_arguments(function.oid),
        privilege.privilege_type
    )
    from pg_proc function
    join pg_namespace namespace
      on namespace.oid = function.pronamespace
    cross join lateral aclexplode(
      coalesce(
        function.proacl,
        acldefault('f', function.proowner)
      )
    ) privilege
    where namespace.nspname = 'cron'
      and privilege.grantee = 0
      and privilege.privilege_type = 'EXECUTE'
  ) is not distinct from array[
    'job_cache_invalidate():EXECUTE',
    'schedule(job_name text, schedule text, command text):EXECUTE',
    'schedule(schedule text, command text):EXECUTE',
    'unschedule(job_id bigint):EXECUTE',
    'unschedule(job_name text):EXECUTE'
  ]::text[],
  'cron functions expose only the pinned dormant extension-owned PUBLIC ACL'
);

select ok(
  has_function_privilege(
    'postgres',
    'app_private.run_hourly_interest_accrual()',
    'execute'
  ),
  'the database owner can still execute the fixed cron entry point'
);

-- Security Advisor 0029 allowlist: exactly 11 authenticated public RPCs.
select is(
  (
    select array_agg(
      function.oid
      order by
        function.proname,
        pg_catalog.oidvectortypes(function.proargtypes)
    )
    from pg_proc function
    join pg_namespace namespace
      on namespace.oid = function.pronamespace
    where namespace.nspname = 'public'
      and function.prosecdef
      and has_function_privilege(
        'authenticated',
        function.oid,
        'execute'
      )
  ),
  array[
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
  ]::oid[],
  'authenticated public SECURITY DEFINER RPCs match the 11-function allowlist'
);

select ok(
  not exists (
    select 1
    from pg_proc function
    where function.oid = any(
      array[
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
      ]::oid[]
    )
    and (
      not function.prosecdef
      or not exists (
        select 1
        from unnest(
          coalesce(function.proconfig, array[]::text[])
        ) setting
        where setting = 'search_path=""'
           or setting = 'search_path='
      )
      or pg_get_functiondef(function.oid)
           !~ 'auth[.]uid[[:space:]]*[(][[:space:]]*[)]'
      or (
        function.proname <> 'get_my_driver_parent_account'
        and pg_get_functiondef(function.oid)
              !~ 'app_private[.](is_|can_)'
      )
      or pg_get_functiondef(function.oid) ~* '\mexecute\M'
      or pg_get_function_identity_arguments(function.oid) ~* (
        '\m(p_)?(actor|organization|requester|approver|executed_by|'
        || 'created_by|updated_by|user)_id\M'
      )
      or not exists (
        select 1
        from aclexplode(
          coalesce(
            function.proacl,
            acldefault('f', function.proowner)
          )
        ) privilege
        where privilege.grantee = (
          select oid from pg_roles where rolname = 'authenticated'
        )
          and privilege.privilege_type = 'EXECUTE'
      )
      or has_function_privilege('anon', function.oid, 'execute')
    )
  ),
  'all 11 authenticated definer RPCs satisfy the hardening contract'
);

select * from finish();

rollback;
