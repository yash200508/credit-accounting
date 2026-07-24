create function app_private.calculate_credit_account_balance(
  target_credit_account_id uuid
)
returns table (
  credit_limit_paise bigint,
  outstanding_principal_paise bigint,
  available_credit_paise bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  calculated_credit_limit_paise bigint;
  calculated_outstanding_principal numeric;
  calculated_available_credit numeric;
begin
  select
    settings.credit_limit_paise,
    coalesce(
      sum(
        case
          when entry.direction = 'DEBIT' then entry.amount_paise
          when entry.direction = 'CREDIT' then -entry.amount_paise
          else 0
        end
      ) filter (
        where transaction.status = 'POSTED'
          and entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
      ),
      0
    )
  into
    calculated_credit_limit_paise,
    calculated_outstanding_principal
  from public.credit_accounts as account
  join public.customer_account_settings as settings
    on settings.customer_id = account.customer_id
   and settings.organization_id = account.organization_id
  left join public.ledger_transactions as transaction
    on transaction.credit_account_id = account.id
   and transaction.organization_id = account.organization_id
  left join public.ledger_entries as entry
    on entry.transaction_id = transaction.id
   and entry.organization_id = transaction.organization_id
  where account.id = target_credit_account_id
  group by settings.credit_limit_paise;

  if not found then
    return;
  end if;

  calculated_available_credit :=
    calculated_credit_limit_paise::numeric
    - calculated_outstanding_principal;

  if calculated_outstanding_principal
       not between -9223372036854775808::numeric
       and 9223372036854775807::numeric
     or calculated_available_credit
       not between -9223372036854775808::numeric
       and 9223372036854775807::numeric
  then
    raise exception 'BALANCE_OVERFLOW'
      using errcode = 'P0001';
  end if;

  return query
  select
    calculated_credit_limit_paise,
    calculated_outstanding_principal::bigint,
    calculated_available_credit::bigint;
end;
$$;

create function public.get_credit_account_balance(
  p_credit_account_id uuid
)
returns table (
  credit_account_id uuid,
  customer_id uuid,
  organization_id uuid,
  currency_code text,
  credit_limit_paise bigint,
  outstanding_principal_paise bigint,
  available_credit_paise bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_user_id uuid := (select auth.uid());
  target_customer_id uuid;
  target_organization_id uuid;
  target_currency_code text;
  calculated_balance record;
begin
  if actor_user_id is null then
    raise exception 'BAL_AUTHENTICATION_REQUIRED'
      using errcode = 'P0001';
  end if;

  select
    account.customer_id,
    account.organization_id,
    account.currency_code
  into
    target_customer_id,
    target_organization_id,
    target_currency_code
  from public.credit_accounts as account
  where account.id = p_credit_account_id
    and (
      app_private.is_organization_owner(account.organization_id)
      or (
        account.home_station_id is not null
        and app_private.is_station_manager(account.home_station_id)
      )
      or app_private.is_customer(account.customer_id)
    );

  if not found then
    raise exception 'BAL_ACCOUNT_NOT_FOUND_OR_FORBIDDEN'
      using errcode = 'P0001';
  end if;

  select *
  into calculated_balance
  from app_private.calculate_credit_account_balance(p_credit_account_id);

  if not found then
    raise exception 'BAL_ACCOUNT_NOT_FOUND_OR_FORBIDDEN'
      using errcode = 'P0001';
  end if;

  return query
  select
    p_credit_account_id,
    target_customer_id,
    target_organization_id,
    target_currency_code,
    calculated_balance.credit_limit_paise,
    calculated_balance.outstanding_principal_paise,
    calculated_balance.available_credit_paise;
end;
$$;

create function public.post_fuel_credit_transaction(
  p_credit_account_id uuid,
  p_station_id uuid,
  p_fuel_product_id uuid,
  p_amount_paise numeric,
  p_idempotency_key uuid,
  p_source_reference text default null
)
returns table (
  transaction_id uuid,
  sale_id uuid,
  credit_account_id uuid,
  customer_id uuid,
  amount_paise bigint,
  currency_code text,
  outstanding_principal_paise bigint,
  available_credit_paise bigint,
  idempotent_replay boolean,
  posted_at timestamptz
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
  account_organization_id uuid;
  target_customer_id uuid;
  account_home_station_id uuid;
  account_active boolean;
  account_currency_code text;
  target_customer_status public.customer_status;
  product_organization_id uuid;
  product_station_id uuid;
  product_active boolean;
  product_currency_code text;
  normalized_source_reference text;
  checked_amount_paise bigint;
  request_fingerprint text;
  claimed_idempotency_id uuid;
  existing_idempotency public.idempotency_keys%rowtype;
  current_balance record;
  new_outstanding_principal_paise bigint;
  new_available_credit_paise bigint;
  new_transaction_id uuid := gen_random_uuid();
  new_sale_id uuid := gen_random_uuid();
  effective_posted_at timestamptz := statement_timestamp();
begin
  if actor_user_id is null then
    raise exception 'FCP_AUTHENTICATION_REQUIRED'
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
    raise exception 'FCP_STATION_INVALID'
      using errcode = 'P0001';
  end if;

  if app_private.is_organization_owner(target_organization_id) then
    actor_role := 'OWNER';
  elsif app_private.is_station_manager(p_station_id) then
    actor_role := 'MANAGER';
  elsif app_private.is_station_attendant(p_station_id) then
    actor_role := 'ATTENDANT';
  else
    raise exception 'FCP_FORBIDDEN'
      using errcode = 'P0001';
  end if;

  if p_amount_paise is null
     or p_amount_paise <= 0
     or p_amount_paise <> trunc(p_amount_paise)
  then
    raise exception 'FCP_INVALID_AMOUNT'
      using errcode = 'P0001';
  end if;

  if p_amount_paise > 9223372036854775807::numeric then
    raise exception 'FCP_AMOUNT_OVERFLOW'
      using errcode = 'P0001';
  end if;

  checked_amount_paise := p_amount_paise::bigint;

  if p_idempotency_key is null then
    raise exception 'FCP_IDEMPOTENCY_KEY_REQUIRED'
      using errcode = 'P0001';
  end if;

  normalized_source_reference := nullif(btrim(p_source_reference), '');

  if normalized_source_reference is not null
     and (
       char_length(normalized_source_reference) > 100
       or normalized_source_reference
         !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}$'
     )
  then
    raise exception 'FCP_INVALID_SOURCE_REFERENCE'
      using errcode = 'P0001';
  end if;

  select
    account.organization_id,
    account.customer_id,
    account.home_station_id,
    account.is_active,
    account.currency_code,
    customer.status
  into
    account_organization_id,
    target_customer_id,
    account_home_station_id,
    account_active,
    account_currency_code,
    target_customer_status
  from public.credit_accounts as account
  join public.customers as customer
    on customer.id = account.customer_id
   and customer.organization_id = account.organization_id
  where account.id = p_credit_account_id;

  if not found then
    raise exception 'FCP_ACCOUNT_INVALID'
      using errcode = 'P0001';
  end if;

  if account_organization_id <> target_organization_id then
    raise exception 'FCP_TENANT_MISMATCH'
      using errcode = 'P0001';
  end if;

  if account_home_station_id is distinct from p_station_id then
    raise exception 'FCP_STATION_MISMATCH'
      using errcode = 'P0001';
  end if;

  if not account_active then
    raise exception 'FCP_ACCOUNT_INACTIVE'
      using errcode = 'P0001';
  end if;

  if target_customer_status <> 'ACTIVE' then
    raise exception 'FCP_CUSTOMER_INACTIVE'
      using errcode = 'P0001';
  end if;

  if account_currency_code <> 'INR' then
    raise exception 'FCP_CURRENCY_MISMATCH'
      using errcode = 'P0001';
  end if;

  select
    product.organization_id,
    product.station_id,
    product.is_active,
    product.currency_code
  into
    product_organization_id,
    product_station_id,
    product_active,
    product_currency_code
  from public.fuel_products as product
  where product.id = p_fuel_product_id;

  if not found then
    raise exception 'FCP_PRODUCT_INVALID'
      using errcode = 'P0001';
  end if;

  if product_organization_id <> target_organization_id then
    raise exception 'FCP_TENANT_MISMATCH'
      using errcode = 'P0001';
  end if;

  if product_station_id is not null
     and product_station_id <> p_station_id
  then
    raise exception 'FCP_STATION_MISMATCH'
      using errcode = 'P0001';
  end if;

  if not product_active then
    raise exception 'FCP_PRODUCT_INACTIVE'
      using errcode = 'P0001';
  end if;

  if product_currency_code <> account_currency_code then
    raise exception 'FCP_CURRENCY_MISMATCH'
      using errcode = 'P0001';
  end if;

  request_fingerprint := encode(
    sha256(
      convert_to(
        jsonb_build_object(
          'credit_account_id', p_credit_account_id,
          'station_id', p_station_id,
          'fuel_product_id', p_fuel_product_id,
          'amount_paise', checked_amount_paise,
          'source_reference', normalized_source_reference
        )::text,
        'UTF8'
      )
    ),
    'hex'
  );

  insert into public.idempotency_keys (
    organization_id,
    station_id,
    credit_account_id,
    fuel_product_id,
    operation,
    idempotency_key,
    request_fingerprint,
    amount_paise,
    status,
    created_by
  )
  values (
    target_organization_id,
    p_station_id,
    p_credit_account_id,
    p_fuel_product_id,
    'FUEL_CREDIT_POSTING',
    p_idempotency_key,
    request_fingerprint,
    checked_amount_paise,
    'IN_PROGRESS',
    actor_user_id
  )
  on conflict (organization_id, operation, idempotency_key)
  do nothing
  returning id into claimed_idempotency_id;

  if claimed_idempotency_id is null then
    select idempotency.*
    into existing_idempotency
    from public.idempotency_keys as idempotency
    where idempotency.organization_id = target_organization_id
      and idempotency.operation = 'FUEL_CREDIT_POSTING'
      and idempotency.idempotency_key = p_idempotency_key
    for update;

    if not found then
      raise exception 'FCP_IDEMPOTENCY_RETRY'
        using errcode = 'P0001';
    end if;

    if existing_idempotency.request_fingerprint <> request_fingerprint then
      raise exception 'FCP_IDEMPOTENCY_CONFLICT'
        using errcode = 'P0001';
    end if;

    if existing_idempotency.status <> 'COMPLETED' then
      raise exception 'FCP_IDEMPOTENCY_RETRY'
        using errcode = 'P0001';
    end if;

    return query
    select
      existing_idempotency.response_transaction_id,
      existing_idempotency.response_sale_id,
      existing_idempotency.credit_account_id,
      (
        select account.customer_id
        from public.credit_accounts as account
        where account.id = existing_idempotency.credit_account_id
      ),
      existing_idempotency.amount_paise,
      'INR'::text,
      existing_idempotency.response_outstanding_principal_paise,
      existing_idempotency.response_available_credit_paise,
      true,
      existing_idempotency.response_posted_at;
    return;
  end if;

  select
    account.organization_id,
    account.customer_id,
    account.home_station_id,
    account.is_active,
    account.currency_code,
    customer.status
  into
    account_organization_id,
    target_customer_id,
    account_home_station_id,
    account_active,
    account_currency_code,
    target_customer_status
  from public.credit_accounts as account
  join public.customers as customer
    on customer.id = account.customer_id
   and customer.organization_id = account.organization_id
  where account.id = p_credit_account_id
  for update of account;

  if not found
     or account_organization_id <> target_organization_id
     or account_home_station_id is distinct from p_station_id
  then
    raise exception 'FCP_ACCOUNT_CHANGED'
      using errcode = 'P0001';
  end if;

  if not account_active then
    raise exception 'FCP_ACCOUNT_INACTIVE'
      using errcode = 'P0001';
  end if;

  if target_customer_status <> 'ACTIVE' then
    raise exception 'FCP_CUSTOMER_INACTIVE'
      using errcode = 'P0001';
  end if;

  select *
  into current_balance
  from app_private.calculate_credit_account_balance(p_credit_account_id);

  if not found then
    raise exception 'FCP_ACCOUNT_INVALID'
      using errcode = 'P0001';
  end if;

  if checked_amount_paise > current_balance.available_credit_paise then
    raise exception 'FCP_INSUFFICIENT_CREDIT'
      using errcode = 'P0001';
  end if;

  new_outstanding_principal_paise :=
    (
      current_balance.outstanding_principal_paise::numeric
      + checked_amount_paise
    )::bigint;
  new_available_credit_paise :=
    (
      current_balance.available_credit_paise::numeric
      - checked_amount_paise
    )::bigint;

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
    new_transaction_id,
    target_organization_id,
    p_station_id,
    p_credit_account_id,
    target_customer_id,
    'FUEL_CREDIT',
    'POSTED',
    checked_amount_paise,
    'INR',
    effective_posted_at,
    actor_user_id,
    effective_posted_at
  );

  insert into public.fuel_credit_sales (
    id,
    organization_id,
    station_id,
    transaction_id,
    credit_account_id,
    customer_id,
    fuel_product_id,
    amount_paise,
    currency_code,
    source_reference,
    created_by,
    created_at
  )
  values (
    new_sale_id,
    target_organization_id,
    p_station_id,
    new_transaction_id,
    p_credit_account_id,
    target_customer_id,
    p_fuel_product_id,
    checked_amount_paise,
    'INR',
    normalized_source_reference,
    actor_user_id,
    effective_posted_at
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
      target_organization_id,
      new_transaction_id,
      'CUSTOMER_ACCOUNTS_RECEIVABLE',
      'DEBIT',
      checked_amount_paise,
      'INR',
      effective_posted_at
    ),
    (
      target_organization_id,
      new_transaction_id,
      'FUEL_SALES_REVENUE',
      'CREDIT',
      checked_amount_paise,
      'INR',
      effective_posted_at
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
    source_application,
    occurred_at
  )
  values (
    actor_user_id,
    actor_role,
    target_organization_id,
    p_station_id,
    'FINANCIAL',
    'fuel_credit.posted',
    'ledger_transaction',
    new_transaction_id,
    null,
    jsonb_build_object(
      'transaction_id', new_transaction_id,
      'sale_id', new_sale_id,
      'customer_id', target_customer_id,
      'credit_account_id', p_credit_account_id,
      'fuel_product_id', p_fuel_product_id,
      'amount_paise', checked_amount_paise,
      'currency_code', 'INR',
      'idempotency_key', p_idempotency_key
    ),
    p_idempotency_key,
    'trusted-db-function',
    effective_posted_at
  );

  update public.idempotency_keys
  set
    status = 'COMPLETED',
    response_transaction_id = new_transaction_id,
    response_sale_id = new_sale_id,
    response_outstanding_principal_paise =
      new_outstanding_principal_paise,
    response_available_credit_paise = new_available_credit_paise,
    response_posted_at = effective_posted_at,
    completed_at = effective_posted_at
  where id = claimed_idempotency_id;

  return query
  select
    new_transaction_id,
    new_sale_id,
    p_credit_account_id,
    target_customer_id,
    checked_amount_paise,
    'INR'::text,
    new_outstanding_principal_paise,
    new_available_credit_paise,
    false,
    effective_posted_at;
end;
$$;

comment on function public.get_credit_account_balance(uuid) is
  'Returns the authorized account limit, posted AR principal, and available credit.';

comment on function public.post_fuel_credit_transaction(
  uuid,
  uuid,
  uuid,
  numeric,
  uuid,
  text
) is
  'Atomically posts one idempotent INR fuel-credit sale with balanced ledger and audit rows.';

revoke all on function app_private.calculate_credit_account_balance(uuid)
  from public, anon, authenticated;
revoke all on function public.get_credit_account_balance(uuid)
  from public, anon, authenticated;
revoke all on function public.post_fuel_credit_transaction(
  uuid,
  uuid,
  uuid,
  numeric,
  uuid,
  text
) from public, anon, authenticated;

grant execute on function public.get_credit_account_balance(uuid)
  to authenticated;
grant execute on function public.post_fuel_credit_transaction(
  uuid,
  uuid,
  uuid,
  numeric,
  uuid,
  text
) to authenticated;
