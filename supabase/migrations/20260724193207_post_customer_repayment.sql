create function public.post_customer_repayment(
  p_credit_account_id uuid,
  p_station_id uuid,
  p_total_amount_paise numeric,
  p_allocation_mode text,
  p_idempotency_key uuid,
  p_principal_allocation_paise numeric default null,
  p_interest_allocation_paise numeric default null,
  p_payer_driver_id uuid default null,
  p_source_reference text default null,
  p_payment_method text default 'CASH'
)
returns table (
  transaction_id uuid,
  repayment_id uuid,
  credit_account_id uuid,
  customer_id uuid,
  payer_type public.repayment_payer_type,
  payer_driver_id uuid,
  total_amount_paise bigint,
  principal_allocation_paise bigint,
  interest_allocation_paise bigint,
  payment_method public.repayment_payment_method,
  currency_code text,
  outstanding_principal_paise bigint,
  outstanding_interest_paise bigint,
  total_due_paise bigint,
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
  normalized_allocation_mode text;
  checked_allocation_mode public.repayment_allocation_mode;
  normalized_payment_method text;
  checked_payment_method public.repayment_payment_method;
  normalized_source_reference text;
  checked_total_amount_paise bigint;
  checked_principal_allocation_paise bigint;
  checked_interest_allocation_paise bigint;
  checked_payer_type public.repayment_payer_type;
  driver_organization_id uuid;
  driver_customer_id uuid;
  target_driver_status public.driver_status;
  driver_permission_id uuid;
  driver_valid_from date;
  driver_expires_on date;
  request_fingerprint text;
  claimed_idempotency_id uuid;
  existing_idempotency public.idempotency_keys%rowtype;
  existing_repayment public.customer_repayments%rowtype;
  replay_principal_allocation bigint;
  replay_interest_allocation bigint;
  current_balance record;
  new_outstanding_principal_paise bigint;
  new_outstanding_interest_paise bigint;
  new_total_due_paise bigint;
  new_available_credit_paise bigint;
  calculated_value numeric;
  new_transaction_id uuid := gen_random_uuid();
  new_repayment_id uuid := gen_random_uuid();
  effective_posted_at timestamptz := statement_timestamp();
begin
  if actor_user_id is null then
    raise exception 'RPP_AUTH_REQUIRED'
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
    raise exception 'RPP_INVALID_STATION'
      using errcode = 'P0001';
  end if;

  if app_private.is_organization_owner(target_organization_id) then
    actor_role := 'OWNER';
  elsif app_private.is_station_manager(p_station_id) then
    actor_role := 'MANAGER';
  elsif app_private.is_station_attendant(p_station_id) then
    actor_role := 'ATTENDANT';
  else
    raise exception 'RPP_FORBIDDEN'
      using errcode = 'P0001';
  end if;

  if p_total_amount_paise is null
     or p_total_amount_paise <= 0
     or p_total_amount_paise <> trunc(p_total_amount_paise)
  then
    raise exception 'RPP_INVALID_AMOUNT'
      using errcode = 'P0001';
  end if;

  if p_total_amount_paise > 9223372036854775807::numeric then
    raise exception 'RPP_OVERFLOW'
      using errcode = 'P0001';
  end if;

  checked_total_amount_paise := p_total_amount_paise::bigint;
  normalized_allocation_mode :=
    upper(btrim(coalesce(p_allocation_mode, '')));

  if normalized_allocation_mode not in (
    'PRINCIPAL_ONLY',
    'INTEREST_ONLY',
    'SPLIT'
  ) then
    raise exception 'RPP_INVALID_ALLOCATION_MODE'
      using errcode = 'P0001';
  end if;

  checked_allocation_mode :=
    normalized_allocation_mode::public.repayment_allocation_mode;

  if p_principal_allocation_paise is not null
     and p_principal_allocation_paise > 9223372036854775807::numeric
     or p_interest_allocation_paise is not null
     and p_interest_allocation_paise > 9223372036854775807::numeric
  then
    raise exception 'RPP_OVERFLOW'
      using errcode = 'P0001';
  end if;

  if checked_allocation_mode = 'PRINCIPAL_ONLY' then
    if (
      p_principal_allocation_paise is not null
      and (
        p_principal_allocation_paise <> trunc(p_principal_allocation_paise)
        or p_principal_allocation_paise <> checked_total_amount_paise
      )
    )
    or (
      p_interest_allocation_paise is not null
      and p_interest_allocation_paise <> 0
    )
    then
      raise exception 'RPP_ALLOCATION_MISMATCH'
        using errcode = 'P0001';
    end if;

    checked_principal_allocation_paise := checked_total_amount_paise;
    checked_interest_allocation_paise := 0;
  elsif checked_allocation_mode = 'INTEREST_ONLY' then
    if (
      p_interest_allocation_paise is not null
      and (
        p_interest_allocation_paise <> trunc(p_interest_allocation_paise)
        or p_interest_allocation_paise <> checked_total_amount_paise
      )
    )
    or (
      p_principal_allocation_paise is not null
      and p_principal_allocation_paise <> 0
    )
    then
      raise exception 'RPP_ALLOCATION_MISMATCH'
        using errcode = 'P0001';
    end if;

    checked_principal_allocation_paise := 0;
    checked_interest_allocation_paise := checked_total_amount_paise;
  else
    if p_principal_allocation_paise is null
       or p_interest_allocation_paise is null
       or p_principal_allocation_paise <= 0
       or p_interest_allocation_paise <= 0
       or p_principal_allocation_paise
         <> trunc(p_principal_allocation_paise)
       or p_interest_allocation_paise
         <> trunc(p_interest_allocation_paise)
       or (
         p_principal_allocation_paise
         + p_interest_allocation_paise
       ) <> checked_total_amount_paise
    then
      raise exception 'RPP_ALLOCATION_MISMATCH'
        using errcode = 'P0001';
    end if;

    checked_principal_allocation_paise :=
      p_principal_allocation_paise::bigint;
    checked_interest_allocation_paise :=
      p_interest_allocation_paise::bigint;
  end if;

  normalized_payment_method :=
    upper(btrim(coalesce(p_payment_method, '')));

  if normalized_payment_method <> 'CASH' then
    raise exception 'RPP_INVALID_PAYMENT_METHOD'
      using errcode = 'P0001';
  end if;

  checked_payment_method :=
    normalized_payment_method::public.repayment_payment_method;

  if p_idempotency_key is null then
    raise exception 'RPP_IDEMPOTENCY_KEY_REQUIRED'
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
    raise exception 'RPP_INVALID_SOURCE_REFERENCE'
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
    raise exception 'RPP_INVALID_ACCOUNT'
      using errcode = 'P0001';
  end if;

  if account_organization_id <> target_organization_id then
    raise exception 'RPP_FORBIDDEN'
      using errcode = 'P0001';
  end if;

  if account_home_station_id is distinct from p_station_id then
    raise exception 'RPP_INVALID_STATION'
      using errcode = 'P0001';
  end if;

  if not account_active then
    raise exception 'RPP_INACTIVE_ACCOUNT'
      using errcode = 'P0001';
  end if;

  if target_customer_status <> 'ACTIVE' then
    raise exception 'RPP_INACTIVE_CUSTOMER'
      using errcode = 'P0001';
  end if;

  if account_currency_code <> 'INR' then
    raise exception 'RPP_INVALID_ACCOUNT'
      using errcode = 'P0001';
  end if;

  if p_payer_driver_id is null then
    checked_payer_type := 'CUSTOMER';
  else
    select
      driver.organization_id,
      driver.customer_id,
      driver.status,
      permission.driver_id,
      permission.valid_from,
      permission.expires_on
    into
      driver_organization_id,
      driver_customer_id,
      target_driver_status,
      driver_permission_id,
      driver_valid_from,
      driver_expires_on
    from public.customer_drivers as driver
    left join public.driver_permissions as permission
      on permission.driver_id = driver.id
     and permission.customer_id = driver.customer_id
     and permission.organization_id = driver.organization_id
    where driver.id = p_payer_driver_id;

    if not found
       or driver_organization_id <> target_organization_id
       or driver_customer_id <> target_customer_id
    then
      raise exception 'RPP_INVALID_DRIVER'
        using errcode = 'P0001';
    end if;

    if target_driver_status = 'REVOKED' then
      raise exception 'RPP_DRIVER_REVOKED'
        using errcode = 'P0001';
    end if;

    if target_driver_status <> 'ACTIVE'
       or driver_permission_id is null
       or (now() at time zone 'UTC')::date < driver_valid_from
       or (
         driver_expires_on is not null
         and (now() at time zone 'UTC')::date > driver_expires_on
       )
    then
      raise exception 'RPP_INVALID_DRIVER'
        using errcode = 'P0001';
    end if;

    checked_payer_type := 'DRIVER';
  end if;

  request_fingerprint := encode(
    sha256(
      convert_to(
        jsonb_build_object(
          'credit_account_id', p_credit_account_id,
          'station_id', p_station_id,
          'total_amount_paise', checked_total_amount_paise,
          'allocation_mode', checked_allocation_mode,
          'principal_allocation_paise',
            checked_principal_allocation_paise,
          'interest_allocation_paise',
            checked_interest_allocation_paise,
          'payer_type', checked_payer_type,
          'payer_driver_id', p_payer_driver_id,
          'payment_method', checked_payment_method,
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
    null,
    'CUSTOMER_REPAYMENT',
    p_idempotency_key,
    request_fingerprint,
    checked_total_amount_paise,
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
      and idempotency.operation = 'CUSTOMER_REPAYMENT'
      and idempotency.idempotency_key = p_idempotency_key
    for update;

    if not found then
      raise exception 'RPP_IDEMPOTENCY_RETRY'
        using errcode = 'P0001';
    end if;

    if existing_idempotency.request_fingerprint <> request_fingerprint then
      raise exception 'RPP_IDEMPOTENCY_CONFLICT'
        using errcode = 'P0001';
    end if;

    if existing_idempotency.status <> 'COMPLETED'
       or existing_idempotency.response_repayment_id is null
    then
      raise exception 'RPP_IDEMPOTENCY_RETRY'
        using errcode = 'P0001';
    end if;

    select repayment.*
    into existing_repayment
    from public.customer_repayments as repayment
    where repayment.id = existing_idempotency.response_repayment_id;

    if not found then
      raise exception 'RPP_IDEMPOTENCY_RETRY'
        using errcode = 'P0001';
    end if;

    select
      coalesce(sum(allocation.amount_paise) filter (
        where allocation.component = 'PRINCIPAL'
      ), 0)::bigint,
      coalesce(sum(allocation.amount_paise) filter (
        where allocation.component = 'INTEREST'
      ), 0)::bigint
    into
      replay_principal_allocation,
      replay_interest_allocation
    from public.repayment_allocations as allocation
    where allocation.repayment_id = existing_repayment.id;

    return query
    select
      existing_idempotency.response_transaction_id,
      existing_repayment.id,
      existing_repayment.credit_account_id,
      existing_repayment.customer_id,
      existing_repayment.payer_type,
      existing_repayment.payer_driver_id,
      existing_repayment.total_amount_paise,
      replay_principal_allocation,
      replay_interest_allocation,
      existing_repayment.payment_method,
      existing_repayment.currency_code,
      existing_idempotency.response_outstanding_principal_paise,
      existing_idempotency.response_outstanding_interest_paise,
      existing_idempotency.response_total_due_paise,
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
    raise exception 'RPP_ACCOUNT_CHANGED'
      using errcode = 'P0001';
  end if;

  if not account_active then
    raise exception 'RPP_INACTIVE_ACCOUNT'
      using errcode = 'P0001';
  end if;

  if target_customer_status <> 'ACTIVE' then
    raise exception 'RPP_INACTIVE_CUSTOMER'
      using errcode = 'P0001';
  end if;

  if p_payer_driver_id is not null then
    select
      driver.organization_id,
      driver.customer_id,
      driver.status,
      permission.driver_id,
      permission.valid_from,
      permission.expires_on
    into
      driver_organization_id,
      driver_customer_id,
      target_driver_status,
      driver_permission_id,
      driver_valid_from,
      driver_expires_on
    from public.customer_drivers as driver
    join public.driver_permissions as permission
      on permission.driver_id = driver.id
     and permission.customer_id = driver.customer_id
     and permission.organization_id = driver.organization_id
    where driver.id = p_payer_driver_id
    for key share of driver, permission;

    if not found
       or driver_organization_id <> target_organization_id
       or driver_customer_id <> target_customer_id
    then
      raise exception 'RPP_INVALID_DRIVER'
        using errcode = 'P0001';
    end if;

    if target_driver_status = 'REVOKED' then
      raise exception 'RPP_DRIVER_REVOKED'
        using errcode = 'P0001';
    end if;

    if target_driver_status <> 'ACTIVE'
       or (now() at time zone 'UTC')::date < driver_valid_from
       or (
         driver_expires_on is not null
         and (now() at time zone 'UTC')::date > driver_expires_on
       )
    then
      raise exception 'RPP_INVALID_DRIVER'
        using errcode = 'P0001';
    end if;
  end if;

  begin
    select *
    into current_balance
    from app_private.calculate_credit_account_obligations(
      p_credit_account_id
    );
  exception
    when raise_exception then
      if sqlerrm in (
        'BALANCE_OVERFLOW',
        'BALANCE_NEGATIVE_OBLIGATION'
      ) then
        raise exception 'RPP_OVERFLOW'
          using errcode = 'P0001';
      end if;
      raise;
  end;

  if not found then
    raise exception 'RPP_INVALID_ACCOUNT'
      using errcode = 'P0001';
  end if;

  if current_balance.total_due_paise = 0 then
    raise exception 'RPP_NOTHING_DUE'
      using errcode = 'P0001';
  end if;

  if checked_principal_allocation_paise
       > current_balance.outstanding_principal_paise
  then
    raise exception 'RPP_PRINCIPAL_EXCEEDS_DUE'
      using errcode = 'P0001';
  end if;

  if checked_interest_allocation_paise
       > current_balance.outstanding_interest_paise
  then
    raise exception 'RPP_INTEREST_EXCEEDS_DUE'
      using errcode = 'P0001';
  end if;

  calculated_value :=
    current_balance.outstanding_principal_paise::numeric
    - checked_principal_allocation_paise;
  if calculated_value not between 0 and 9223372036854775807::numeric then
    raise exception 'RPP_OVERFLOW'
      using errcode = 'P0001';
  end if;
  new_outstanding_principal_paise := calculated_value::bigint;

  calculated_value :=
    current_balance.outstanding_interest_paise::numeric
    - checked_interest_allocation_paise;
  if calculated_value not between 0 and 9223372036854775807::numeric then
    raise exception 'RPP_OVERFLOW'
      using errcode = 'P0001';
  end if;
  new_outstanding_interest_paise := calculated_value::bigint;

  calculated_value :=
    new_outstanding_principal_paise::numeric
    + new_outstanding_interest_paise;
  if calculated_value not between 0 and 9223372036854775807::numeric then
    raise exception 'RPP_OVERFLOW'
      using errcode = 'P0001';
  end if;
  new_total_due_paise := calculated_value::bigint;

  calculated_value :=
    current_balance.available_credit_paise::numeric
    + checked_principal_allocation_paise;
  if calculated_value
       not between -9223372036854775808::numeric
       and 9223372036854775807::numeric
  then
    raise exception 'RPP_OVERFLOW'
      using errcode = 'P0001';
  end if;
  new_available_credit_paise := calculated_value::bigint;

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
    'CUSTOMER_REPAYMENT',
    'POSTED',
    checked_total_amount_paise,
    'INR',
    effective_posted_at,
    actor_user_id,
    effective_posted_at
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
    payer_driver_id,
    received_by,
    source_reference,
    currency_code,
    created_at
  )
  values (
    new_repayment_id,
    target_organization_id,
    p_station_id,
    new_transaction_id,
    p_credit_account_id,
    target_customer_id,
    claimed_idempotency_id,
    checked_total_amount_paise,
    checked_allocation_mode,
    checked_payment_method,
    checked_payer_type,
    p_payer_driver_id,
    actor_user_id,
    normalized_source_reference,
    'INR',
    effective_posted_at
  );

  if checked_principal_allocation_paise > 0 then
    insert into public.repayment_allocations (
      organization_id,
      repayment_id,
      credit_account_id,
      component,
      amount_paise,
      created_at
    )
    values (
      target_organization_id,
      new_repayment_id,
      p_credit_account_id,
      'PRINCIPAL',
      checked_principal_allocation_paise,
      effective_posted_at
    );
  end if;

  if checked_interest_allocation_paise > 0 then
    insert into public.repayment_allocations (
      organization_id,
      repayment_id,
      credit_account_id,
      component,
      amount_paise,
      created_at
    )
    values (
      target_organization_id,
      new_repayment_id,
      p_credit_account_id,
      'INTEREST',
      checked_interest_allocation_paise,
      effective_posted_at
    );
  end if;

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
    target_organization_id,
    new_transaction_id,
    'CASH_ON_HAND',
    'DEBIT',
    checked_total_amount_paise,
    'INR',
    effective_posted_at
  );

  if checked_principal_allocation_paise > 0 then
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
      target_organization_id,
      new_transaction_id,
      'CUSTOMER_ACCOUNTS_RECEIVABLE',
      'CREDIT',
      checked_principal_allocation_paise,
      'INR',
      effective_posted_at
    );
  end if;

  if checked_interest_allocation_paise > 0 then
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
      target_organization_id,
      new_transaction_id,
      'CUSTOMER_INTEREST_RECEIVABLE',
      'CREDIT',
      checked_interest_allocation_paise,
      'INR',
      effective_posted_at
    );
  end if;

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
    'customer_repayment.posted',
    'customer_repayment',
    new_repayment_id,
    null,
    jsonb_build_object(
      'repayment_id', new_repayment_id,
      'transaction_id', new_transaction_id,
      'customer_id', target_customer_id,
      'credit_account_id', p_credit_account_id,
      'total_amount_paise', checked_total_amount_paise,
      'principal_allocation_paise',
        checked_principal_allocation_paise,
      'interest_allocation_paise',
        checked_interest_allocation_paise,
      'payer_type', checked_payer_type,
      'payer_driver_id', p_payer_driver_id,
      'payment_method', checked_payment_method,
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
    response_repayment_id = new_repayment_id,
    response_outstanding_principal_paise =
      new_outstanding_principal_paise,
    response_outstanding_interest_paise =
      new_outstanding_interest_paise,
    response_total_due_paise = new_total_due_paise,
    response_available_credit_paise = new_available_credit_paise,
    response_posted_at = effective_posted_at,
    completed_at = effective_posted_at
  where id = claimed_idempotency_id;

  return query
  select
    new_transaction_id,
    new_repayment_id,
    p_credit_account_id,
    target_customer_id,
    checked_payer_type,
    p_payer_driver_id,
    checked_total_amount_paise,
    checked_principal_allocation_paise,
    checked_interest_allocation_paise,
    checked_payment_method,
    'INR'::text,
    new_outstanding_principal_paise,
    new_outstanding_interest_paise,
    new_total_due_paise,
    new_available_credit_paise,
    false,
    effective_posted_at;
end;
$$;

comment on function public.post_customer_repayment(
  uuid,
  uuid,
  numeric,
  text,
  uuid,
  numeric,
  numeric,
  uuid,
  text,
  text
) is
  'Atomically posts one explicitly allocated, idempotent INR cash repayment.';

revoke all on function public.post_customer_repayment(
  uuid,
  uuid,
  numeric,
  text,
  uuid,
  numeric,
  numeric,
  uuid,
  text,
  text
) from public, anon, authenticated, service_role;
