create function public.create_customer_with_credit_account(
  p_station_id uuid,
  p_first_name text,
  p_last_name text,
  p_phone text,
  p_display_name text default null,
  p_alternate_phone text default null,
  p_address text default null,
  p_credit_limit_paise numeric default 0,
  p_default_annual_interest_rate numeric default 0.18000000,
  p_grace_days integer default 0,
  p_grace_policy public.interest_grace_policy_type default 'AFTER_GRACE_ONLY',
  p_due_days integer default 30,
  p_request_id uuid default null
)
returns table (
  customer_id uuid,
  credit_account_id uuid,
  organization_id uuid,
  station_id uuid,
  currency_code text,
  customer_status public.customer_status,
  credit_limit_paise bigint
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor_user_id uuid := (select auth.uid());
  actor_role public.app_role;
  target_organization_id uuid;
  normalized_first_name text;
  normalized_last_name text;
  normalized_display_name text;
  normalized_phone text;
  normalized_alternate_phone text;
  normalized_address text;
  checked_credit_limit_paise bigint;
  effective_request_id uuid := coalesce(p_request_id, gen_random_uuid());
  new_customer_id uuid := gen_random_uuid();
  new_credit_account_id uuid := gen_random_uuid();
  violated_constraint text;
begin
  if actor_user_id is null then
    raise exception 'CCC_AUTHENTICATION_REQUIRED'
      using errcode = 'P0001';
  end if;

  select station.organization_id
  into target_organization_id
  from public.stations as station
  join public.organizations as organization
    on organization.id = station.organization_id
  where station.id = p_station_id
    and station.is_active
    and organization.is_active;

  if not found then
    raise exception 'CCC_STATION_INVALID'
      using errcode = 'P0001';
  end if;

  if app_private.is_organization_owner(target_organization_id) then
    actor_role := 'OWNER';
  elsif app_private.is_station_manager(p_station_id) then
    actor_role := 'MANAGER';
  else
    raise exception 'CCC_FORBIDDEN'
      using errcode = 'P0001';
  end if;

  normalized_first_name := nullif(btrim(p_first_name), '');
  normalized_last_name := nullif(btrim(p_last_name), '');
  normalized_display_name := nullif(btrim(p_display_name), '');
  normalized_phone := nullif(btrim(p_phone), '');
  normalized_alternate_phone := nullif(btrim(p_alternate_phone), '');
  normalized_address := nullif(btrim(p_address), '');

  if normalized_first_name is null
     or char_length(normalized_first_name) > 100
     or normalized_last_name is null
     or char_length(normalized_last_name) > 100
     or (
       normalized_display_name is not null
       and char_length(normalized_display_name) > 200
     )
  then
    raise exception 'CCC_INVALID_NAME'
      using errcode = 'P0001';
  end if;

  if normalized_phone is null
     or normalized_phone !~ '^\+[1-9][0-9]{7,14}$'
     or (
       normalized_alternate_phone is not null
       and normalized_alternate_phone !~ '^\+[1-9][0-9]{7,14}$'
     )
     or normalized_alternate_phone is not distinct from normalized_phone
  then
    raise exception 'CCC_INVALID_PHONE'
      using errcode = 'P0001';
  end if;

  if normalized_address is not null
     and char_length(normalized_address) > 500
  then
    raise exception 'CCC_INVALID_ADDRESS'
      using errcode = 'P0001';
  end if;

  if p_credit_limit_paise is null
     or p_credit_limit_paise < 0
     or p_credit_limit_paise <> trunc(p_credit_limit_paise)
  then
    raise exception 'CCC_INVALID_CREDIT_LIMIT'
      using errcode = 'P0001';
  end if;

  if p_credit_limit_paise > 9223372036854775807::numeric then
    raise exception 'CCC_CREDIT_LIMIT_OVERFLOW'
      using errcode = 'P0001';
  end if;

  checked_credit_limit_paise := p_credit_limit_paise::bigint;

  if p_default_annual_interest_rate is null
     or p_default_annual_interest_rate < 0
     or p_default_annual_interest_rate > 1
     or p_default_annual_interest_rate
       <> round(p_default_annual_interest_rate, 8)
  then
    raise exception 'CCC_INVALID_INTEREST_RATE'
      using errcode = 'P0001';
  end if;

  if p_grace_days is null
     or p_grace_days not between 0 and 3650
     or p_grace_policy is null
  then
    raise exception 'CCC_INVALID_GRACE_POLICY'
      using errcode = 'P0001';
  end if;

  if p_due_days is null or p_due_days not between 0 and 3650 then
    raise exception 'CCC_INVALID_DUE_DAYS'
      using errcode = 'P0001';
  end if;

  if exists (
    select 1
    from public.customers as customer
    where customer.organization_id = target_organization_id
      and customer.phone = normalized_phone
  ) then
    raise exception 'CCC_DUPLICATE_PHONE'
      using errcode = 'P0001';
  end if;

  insert into public.customers (
    id,
    organization_id,
    home_station_id,
    auth_user_id,
    first_name,
    last_name,
    display_name,
    phone,
    alternate_phone,
    address,
    status,
    created_by,
    updated_by
  )
  values (
    new_customer_id,
    target_organization_id,
    p_station_id,
    null,
    normalized_first_name,
    normalized_last_name,
    normalized_display_name,
    normalized_phone,
    normalized_alternate_phone,
    normalized_address,
    'ACTIVE',
    actor_user_id,
    actor_user_id
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
    new_customer_id,
    target_organization_id,
    checked_credit_limit_paise,
    p_default_annual_interest_rate,
    p_grace_days,
    p_grace_policy,
    p_due_days,
    actor_user_id,
    actor_user_id
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
    new_credit_account_id,
    target_organization_id,
    new_customer_id,
    p_station_id,
    'INR',
    true,
    actor_user_id,
    actor_user_id
  );

  insert into public.audit_events (
    actor_user_id,
    actor_role,
    organization_id,
    station_id,
    action_category,
    action,
    entity_type,
    entity_id,
    before_state,
    after_state,
    request_id,
    source_application
  )
  values (
    actor_user_id,
    actor_role,
    target_organization_id,
    p_station_id,
    'CUSTOMER',
    'customer.credit_account.created',
    'customer',
    new_customer_id,
    null,
    jsonb_build_object(
      'customer_id', new_customer_id,
      'credit_account_id', new_credit_account_id,
      'credit_limit_paise', checked_credit_limit_paise,
      'currency_code', 'INR',
      'status', 'ACTIVE',
      'default_annual_interest_rate', p_default_annual_interest_rate,
      'grace_days', p_grace_days,
      'grace_policy', p_grace_policy,
      'due_days', p_due_days
    ),
    effective_request_id,
    'trusted-db-function'
  );

  return query
  select
    new_customer_id,
    new_credit_account_id,
    target_organization_id,
    p_station_id,
    'INR'::text,
    'ACTIVE'::public.customer_status,
    checked_credit_limit_paise;
exception
  when unique_violation then
    get stacked diagnostics violated_constraint = constraint_name;
    if violated_constraint = 'customers_organization_phone_unique' then
      raise exception 'CCC_DUPLICATE_PHONE'
        using errcode = 'P0001';
    end if;
    raise;
end;
$$;

comment on function public.create_customer_with_credit_account(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  numeric,
  integer,
  public.interest_grace_policy_type,
  integer,
  uuid
) is
  'Atomically creates an active customer, settings, INR credit account, and audit event.';

revoke all on function public.create_customer_with_credit_account(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  numeric,
  integer,
  public.interest_grace_policy_type,
  integer,
  uuid
) from public, anon, authenticated;

grant execute on function public.create_customer_with_credit_account(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  numeric,
  numeric,
  integer,
  public.interest_grace_policy_type,
  integer,
  uuid
) to authenticated;
