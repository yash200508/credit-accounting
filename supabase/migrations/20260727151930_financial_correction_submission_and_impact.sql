create function public.submit_financial_correction_request(
  p_original_transaction_id uuid,
  p_action text,
  p_reason_category text,
  p_explanation text,
  p_submission_idempotency_key uuid,
  p_replacement_fuel_product_id uuid,
  p_replacement_fuel_amount_paise numeric,
  p_replacement_fuel_source_reference text,
  p_replacement_repayment_amount_paise numeric,
  p_replacement_allocation_mode text,
  p_replacement_principal_allocation_paise numeric,
  p_replacement_interest_allocation_paise numeric,
  p_replacement_payer_driver_id uuid,
  p_replacement_source_reference text,
  p_replacement_payment_method text
)
returns table (
  request_id uuid,
  status public.financial_correction_status,
  version integer,
  correlation_id uuid,
  idempotent_replay boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  actor_role public.app_role;
  original_row public.ledger_transactions%rowtype;
  checked_action public.financial_correction_action;
  checked_reason public.financial_correction_reason_category;
  checked_repayment_mode public.repayment_allocation_mode;
  checked_payment_method public.repayment_payment_method;
  normalized_explanation text := btrim(p_explanation);
  normalized_fuel_reference text :=
    nullif(btrim(p_replacement_fuel_source_reference), '');
  normalized_repayment_reference text :=
    nullif(btrim(p_replacement_source_reference), '');
  checked_fuel_amount bigint;
  checked_repayment_amount bigint;
  checked_principal_amount bigint;
  checked_interest_amount bigint;
  original_fingerprint text;
  request_fingerprint text;
  inserted_request_id uuid;
  existing_request public.financial_correction_requests%rowtype;
  generated_correlation_id uuid := gen_random_uuid();
  generated_replacement_key uuid;
begin
  if actor_id is null then
    raise exception 'COR_AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  if p_original_transaction_id is null
     or p_action is null
     or p_reason_category is null
     or p_submission_idempotency_key is null
     or substring(p_submission_idempotency_key::text, 15, 1) <> '4'
     or substring(p_submission_idempotency_key::text, 20, 1)
       not in ('8', '9', 'a', 'b')
  then
    raise exception 'COR_INVALID_REQUEST' using errcode = 'P0001';
  end if;

  begin
    checked_action := p_action::public.financial_correction_action;
    checked_reason :=
      p_reason_category::public.financial_correction_reason_category;
  exception
    when invalid_text_representation then
      raise exception 'COR_INVALID_REQUEST' using errcode = 'P0001';
  end;

  if not app_private.is_safe_correction_text(
    normalized_explanation,
    20,
    500
  ) then
    raise exception 'COR_INVALID_REASON' using errcode = 'P0001';
  end if;

  if checked_reason = 'WRONG_CUSTOMER_SELECTION'
     and checked_action <> 'REVERSAL_ONLY'
  then
    raise exception 'COR_REPLACEMENT_INVALID' using errcode = 'P0001';
  end if;

  select transaction.*
  into original_row
  from public.ledger_transactions as transaction
  where transaction.id = p_original_transaction_id
    and transaction.status = 'POSTED';

  if not found
     or original_row.transaction_type not in (
       'FUEL_CREDIT',
       'CUSTOMER_REPAYMENT',
       'INTEREST_CHARGE'
     )
  then
    raise exception 'COR_INVALID_ORIGINAL_TRANSACTION'
      using errcode = 'P0001';
  end if;

  if app_private.is_organization_owner(original_row.organization_id) then
    actor_role := 'OWNER';
  elsif app_private.is_station_manager(original_row.station_id) then
    actor_role := 'MANAGER';
  else
    raise exception 'COR_FORBIDDEN' using errcode = 'P0001';
  end if;

  if checked_action = 'REVERSAL_ONLY' then
    if p_replacement_fuel_product_id is not null
       or p_replacement_fuel_amount_paise is not null
       or p_replacement_fuel_source_reference is not null
       or p_replacement_repayment_amount_paise is not null
       or p_replacement_allocation_mode is not null
       or p_replacement_principal_allocation_paise is not null
       or p_replacement_interest_allocation_paise is not null
       or p_replacement_payer_driver_id is not null
       or p_replacement_source_reference is not null
       or p_replacement_payment_method is not null
    then
      raise exception 'COR_REPLACEMENT_INVALID' using errcode = 'P0001';
    end if;
  elsif original_row.transaction_type = 'FUEL_CREDIT' then
    if p_replacement_fuel_product_id is null
       or p_replacement_fuel_amount_paise is null
       or p_replacement_fuel_amount_paise <> trunc(
         p_replacement_fuel_amount_paise
       )
       or p_replacement_fuel_amount_paise <= 0
       or p_replacement_fuel_amount_paise > 9223372036854775807::numeric
       or p_replacement_repayment_amount_paise is not null
       or p_replacement_allocation_mode is not null
       or p_replacement_principal_allocation_paise is not null
       or p_replacement_interest_allocation_paise is not null
       or p_replacement_payer_driver_id is not null
       or p_replacement_source_reference is not null
       or p_replacement_payment_method is not null
    then
      raise exception 'COR_REPLACEMENT_INVALID' using errcode = 'P0001';
    end if;

    checked_fuel_amount := p_replacement_fuel_amount_paise::bigint;

    if normalized_fuel_reference is not null
       and not app_private.is_safe_correction_text(
         normalized_fuel_reference,
         1,
         120
       )
    then
      raise exception 'COR_REPLACEMENT_INVALID' using errcode = 'P0001';
    end if;
  elsif original_row.transaction_type = 'CUSTOMER_REPAYMENT' then
    if p_replacement_repayment_amount_paise is null
       or p_replacement_allocation_mode is null
       or p_replacement_principal_allocation_paise is null
       or p_replacement_interest_allocation_paise is null
       or p_replacement_repayment_amount_paise
         <> trunc(p_replacement_repayment_amount_paise)
       or p_replacement_principal_allocation_paise
         <> trunc(p_replacement_principal_allocation_paise)
       or p_replacement_interest_allocation_paise
         <> trunc(p_replacement_interest_allocation_paise)
       or p_replacement_repayment_amount_paise <= 0
       or p_replacement_repayment_amount_paise
         > 9223372036854775807::numeric
       or p_replacement_principal_allocation_paise < 0
       or p_replacement_interest_allocation_paise < 0
       or p_replacement_principal_allocation_paise
         > 9223372036854775807::numeric
       or p_replacement_interest_allocation_paise
         > 9223372036854775807::numeric
       or p_replacement_fuel_product_id is not null
       or p_replacement_fuel_amount_paise is not null
       or p_replacement_fuel_source_reference is not null
    then
      raise exception 'COR_REPLACEMENT_ALLOCATION_INVALID'
        using errcode = 'P0001';
    end if;

    begin
      checked_repayment_mode :=
        p_replacement_allocation_mode::public.repayment_allocation_mode;
      checked_payment_method := coalesce(
        p_replacement_payment_method,
        'CASH'
      )::public.repayment_payment_method;
    exception
      when invalid_text_representation then
        raise exception 'COR_REPLACEMENT_ALLOCATION_INVALID'
          using errcode = 'P0001';
    end;

    checked_repayment_amount :=
      p_replacement_repayment_amount_paise::bigint;
    checked_principal_amount :=
      p_replacement_principal_allocation_paise::bigint;
    checked_interest_amount :=
      p_replacement_interest_allocation_paise::bigint;

    if checked_principal_amount + checked_interest_amount
         <> checked_repayment_amount
       or (
         checked_repayment_mode = 'PRINCIPAL_ONLY'
         and (
           checked_principal_amount <> checked_repayment_amount
           or checked_interest_amount <> 0
         )
       )
       or (
         checked_repayment_mode = 'INTEREST_ONLY'
         and (
           checked_principal_amount <> 0
           or checked_interest_amount <> checked_repayment_amount
         )
       )
       or (
         checked_repayment_mode = 'SPLIT'
         and (
           checked_principal_amount <= 0
           or checked_interest_amount <= 0
         )
       )
    then
      raise exception 'COR_REPLACEMENT_ALLOCATION_INVALID'
        using errcode = 'P0001';
    end if;

    if normalized_repayment_reference is not null
       and not app_private.is_safe_correction_text(
         normalized_repayment_reference,
         1,
         120
       )
    then
      raise exception 'COR_REPLACEMENT_INVALID' using errcode = 'P0001';
    end if;

    if p_replacement_payer_driver_id is not null
       and not exists (
         select 1
         from public.customer_drivers as driver
         where driver.id = p_replacement_payer_driver_id
           and driver.organization_id = original_row.organization_id
           and driver.customer_id = original_row.customer_id
           and driver.status = 'ACTIVE'
       )
    then
      raise exception 'COR_INVALID_DRIVER' using errcode = 'P0001';
    end if;
  else
    raise exception 'COR_INTEREST_REVERSAL_UNSUPPORTED'
      using errcode = 'P0001';
  end if;

  original_fingerprint :=
    app_private.financial_transaction_fingerprint(original_row.id);

  if original_fingerprint is null then
    raise exception 'COR_INVALID_ORIGINAL_TRANSACTION'
      using errcode = 'P0001';
  end if;

  request_fingerprint := encode(
    sha256(
      convert_to(
        jsonb_build_object(
          'original_transaction_id', original_row.id,
          'action', checked_action,
          'reason_category', checked_reason,
          'explanation', normalized_explanation,
          'fuel_product_id', p_replacement_fuel_product_id,
          'fuel_amount_paise', checked_fuel_amount,
          'fuel_source_reference', normalized_fuel_reference,
          'repayment_amount_paise', checked_repayment_amount,
          'allocation_mode', checked_repayment_mode,
          'principal_allocation_paise', checked_principal_amount,
          'interest_allocation_paise', checked_interest_amount,
          'payer_driver_id', p_replacement_payer_driver_id,
          'repayment_source_reference', normalized_repayment_reference,
          'payment_method', checked_payment_method
        )::text,
        'UTF8'
      )
    ),
    'hex'
  );

  select request.*
  into existing_request
  from public.financial_correction_requests as request
  where request.organization_id = original_row.organization_id
    and request.submission_idempotency_key =
      p_submission_idempotency_key;

  if found then
    if existing_request.request_fingerprint <> request_fingerprint then
      raise exception 'COR_IDEMPOTENCY_CONFLICT'
        using errcode = 'P0001';
    end if;

    return query select
      existing_request.id,
      existing_request.status,
      existing_request.version,
      existing_request.correlation_id,
      true;
    return;
  end if;

  if exists (
    select 1
    from public.financial_reversals as reversal
    where reversal.original_transaction_id = original_row.id
  ) then
    raise exception 'COR_ALREADY_REVERSED' using errcode = 'P0001';
  end if;

  if checked_action = 'REVERSE_AND_REPLACE' then
    generated_replacement_key := gen_random_uuid();
  end if;

  insert into public.financial_correction_requests (
    organization_id,
    station_id,
    original_transaction_id,
    original_transaction_type,
    credit_account_id,
    customer_id,
    currency_code,
    action,
    reason_category,
    explanation,
    requester_id,
    requester_role,
    correlation_id,
    submission_idempotency_key,
    request_fingerprint,
    original_fingerprint,
    replacement_idempotency_key
  )
  values (
    original_row.organization_id,
    original_row.station_id,
    original_row.id,
    original_row.transaction_type,
    original_row.credit_account_id,
    original_row.customer_id,
    original_row.currency_code,
    checked_action,
    checked_reason,
    normalized_explanation,
    actor_id,
    actor_role,
    generated_correlation_id,
    p_submission_idempotency_key,
    request_fingerprint,
    original_fingerprint,
    generated_replacement_key
  )
  on conflict do nothing
  returning id into inserted_request_id;

  if inserted_request_id is null then
    select request.*
    into existing_request
    from public.financial_correction_requests as request
    where request.organization_id = original_row.organization_id
      and request.submission_idempotency_key =
        p_submission_idempotency_key;

    if found then
      if existing_request.request_fingerprint <> request_fingerprint then
        raise exception 'COR_IDEMPOTENCY_CONFLICT'
          using errcode = 'P0001';
      end if;

      return query select
        existing_request.id,
        existing_request.status,
        existing_request.version,
        existing_request.correlation_id,
        true;
      return;
    end if;

    raise exception 'COR_INVALID_REQUEST' using errcode = 'P0001';
  end if;

  if checked_action = 'REVERSE_AND_REPLACE'
     and original_row.transaction_type = 'FUEL_CREDIT'
  then
    insert into public.fuel_credit_correction_proposals (
      request_id,
      organization_id,
      station_id,
      credit_account_id,
      customer_id,
      fuel_product_id,
      amount_paise,
      source_reference
    )
    values (
      inserted_request_id,
      original_row.organization_id,
      original_row.station_id,
      original_row.credit_account_id,
      original_row.customer_id,
      p_replacement_fuel_product_id,
      checked_fuel_amount,
      normalized_fuel_reference
    );
  elsif checked_action = 'REVERSE_AND_REPLACE'
        and original_row.transaction_type = 'CUSTOMER_REPAYMENT'
  then
    insert into public.repayment_correction_proposals (
      request_id,
      organization_id,
      station_id,
      credit_account_id,
      customer_id,
      total_amount_paise,
      allocation_mode,
      principal_allocation_paise,
      interest_allocation_paise,
      payer_driver_id,
      payment_method,
      source_reference
    )
    values (
      inserted_request_id,
      original_row.organization_id,
      original_row.station_id,
      original_row.credit_account_id,
      original_row.customer_id,
      checked_repayment_amount,
      checked_repayment_mode,
      checked_principal_amount,
      checked_interest_amount,
      p_replacement_payer_driver_id,
      checked_payment_method,
      normalized_repayment_reference
    );
  end if;

  insert into public.financial_correction_events (
    request_id,
    organization_id,
    event_type,
    previous_status,
    new_status,
    actor_user_id,
    actor_role,
    reason,
    correlation_id
  )
  values (
    inserted_request_id,
    original_row.organization_id,
    'SUBMITTED',
    null,
    'PENDING_REVIEW',
    actor_id,
    actor_role,
    normalized_explanation,
    generated_correlation_id
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
    reason,
    before_state,
    after_state,
    request_id,
    source_application
  )
  values (
    actor_id,
    actor_role,
    original_row.organization_id,
    original_row.station_id,
    'FINANCIAL',
    'financial_correction.submitted',
    'financial_correction_request',
    inserted_request_id,
    normalized_explanation,
    null,
    jsonb_build_object(
      'status', 'PENDING_REVIEW',
      'action', checked_action,
      'reason_category', checked_reason,
      'original_transaction_id', original_row.id,
      'original_transaction_type', original_row.transaction_type,
      'original_amount_paise', original_row.amount_paise,
      'correlation_id', generated_correlation_id
    ),
    generated_correlation_id,
    'financial-correction-rpc'
  );

  return query select
    inserted_request_id,
    'PENDING_REVIEW'::public.financial_correction_status,
    1,
    generated_correlation_id,
    false;
end;
$$;

create function app_private.calculate_financial_correction_impact(
  target_request_id uuid
)
returns table (
  original_transaction_type public.ledger_transaction_type,
  original_amount_paise bigint,
  reversal_eligible boolean,
  current_principal_paise bigint,
  current_interest_paise bigint,
  current_total_due_paise bigint,
  current_available_credit_paise bigint,
  simulated_principal_paise bigint,
  simulated_interest_paise bigint,
  simulated_available_credit_paise bigint,
  dependent_repayments bigint,
  dependent_fuel_purchases bigint,
  dependent_interest_accruals bigint,
  applied_principal_lot_consumption_paise bigint,
  applied_interest_payments_paise bigint,
  replacement_valid boolean,
  blocking_error_codes text[],
  warnings text[]
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  request_row public.financial_correction_requests%rowtype;
  original_row public.ledger_transactions%rowtype;
  station_time_zone text;
  current_business_date date;
  credit_limit bigint;
  current_principal bigint;
  current_interest bigint;
  current_total bigint;
  current_available bigint;
  original_principal_allocation bigint := 0;
  original_interest_allocation bigint := 0;
  source_remaining_principal bigint;
  principal_consumed bigint := 0;
  interest_payments bigint := 0;
  repayment_count bigint := 0;
  fuel_count bigint := 0;
  accrual_count bigint := 0;
  simulated_principal bigint;
  simulated_interest bigint;
  simulated_available bigint;
  proposed_fuel public.fuel_credit_correction_proposals%rowtype;
  proposed_repayment public.repayment_correction_proposals%rowtype;
  driver_valid boolean := true;
  proposal_found boolean := false;
  replacement_is_valid boolean := true;
  blockers text[] := array[]::text[];
  impact_warnings text[] :=
    array['COR_CURRENT_DATE_REVERSAL']::text[];
begin
  select request.*
  into request_row
  from public.financial_correction_requests as request
  where request.id = target_request_id;

  if not found then
    raise exception 'COR_INVALID_REQUEST' using errcode = 'P0001';
  end if;

  select transaction.*
  into original_row
  from public.ledger_transactions as transaction
  where transaction.id = request_row.original_transaction_id
    and transaction.organization_id = request_row.organization_id;

  select station.time_zone_name
  into station_time_zone
  from public.stations as station
  where station.id = request_row.station_id
    and station.organization_id = request_row.organization_id;

  current_business_date :=
    (statement_timestamp() at time zone station_time_zone)::date;

  select
    obligation.credit_limit_paise,
    obligation.outstanding_principal_paise,
    obligation.outstanding_interest_paise,
    obligation.total_due_paise,
    obligation.available_credit_paise
  into
    credit_limit,
    current_principal,
    current_interest,
    current_total,
    current_available
  from app_private.calculate_credit_account_obligations(
    request_row.credit_account_id
  ) as obligation;

  if request_row.original_transaction_type = 'CUSTOMER_REPAYMENT' then
    select
      coalesce(sum(allocation.amount_paise) filter (
        where allocation.component = 'PRINCIPAL'
      ), 0)::bigint,
      coalesce(sum(allocation.amount_paise) filter (
        where allocation.component = 'INTEREST'
      ), 0)::bigint
    into original_principal_allocation, original_interest_allocation
    from public.customer_repayments as repayment
    join public.repayment_allocations as allocation
      on allocation.repayment_id = repayment.id
     and allocation.organization_id = repayment.organization_id
    where repayment.transaction_id = original_row.id;
  end if;

  select count(*)::bigint
  into repayment_count
  from public.ledger_transactions as transaction
  where transaction.credit_account_id = request_row.credit_account_id
    and transaction.transaction_type = 'CUSTOMER_REPAYMENT'
    and transaction.status = 'POSTED'
    and (
      transaction.business_date > original_row.business_date
      or (
        transaction.business_date = original_row.business_date
        and transaction.occurred_at > original_row.occurred_at
      )
    );

  select count(*)::bigint
  into fuel_count
  from public.ledger_transactions as transaction
  where transaction.credit_account_id = request_row.credit_account_id
    and transaction.transaction_type = 'FUEL_CREDIT'
    and transaction.status = 'POSTED'
    and (
      transaction.business_date > original_row.business_date
      or (
        transaction.business_date = original_row.business_date
        and transaction.occurred_at > original_row.occurred_at
      )
    );

  if request_row.original_transaction_type = 'FUEL_CREDIT' then
    select lot.source_remaining_principal_paise
    into source_remaining_principal
    from app_private.principal_lots_as_of(
      request_row.credit_account_id,
      current_business_date
    ) as lot
    where lot.source_transaction_id = original_row.id;

    principal_consumed := greatest(
      0,
      original_row.amount_paise - coalesce(source_remaining_principal, 0)
    );

    select count(*)::bigint
    into accrual_count
    from public.interest_accrual_components as component
    where component.source_transaction_id = original_row.id;

    simulated_principal := current_principal - original_row.amount_paise;
    simulated_interest := current_interest;

    if principal_consumed > 0 then
      blockers := array_append(
        blockers,
        'COR_PRINCIPAL_ALREADY_REPAID'
      );
    end if;
    if accrual_count > 0 then
      blockers := array_append(
        blockers,
        'COR_DEPENDENT_INTEREST_EXISTS'
      );
    end if;
  elsif request_row.original_transaction_type = 'CUSTOMER_REPAYMENT' then
    select count(*)::bigint
    into accrual_count
    from public.interest_accruals as accrual
    where accrual.credit_account_id = request_row.credit_account_id
      and (
        accrual.business_date > original_row.business_date
        or (
          accrual.business_date = original_row.business_date
          and accrual.created_at > original_row.created_at
        )
      );

    simulated_principal :=
      current_principal + original_principal_allocation;
    simulated_interest :=
      current_interest + original_interest_allocation;

    if simulated_principal > credit_limit then
      blockers := array_append(
        blockers,
        'COR_REVERSAL_EXCEEDS_CREDIT_LIMIT'
      );
    end if;
    if original_principal_allocation > 0 and accrual_count > 0 then
      blockers := array_append(
        blockers,
        'COR_DEPENDENT_INTEREST_EXISTS'
      );
    end if;
  else
    select coalesce(sum(allocation.amount_paise), 0)::bigint
    into interest_payments
    from public.customer_repayments as repayment
    join public.repayment_allocations as allocation
      on allocation.repayment_id = repayment.id
     and allocation.organization_id = repayment.organization_id
     and allocation.component = 'INTEREST'
    join public.ledger_transactions as transaction
      on transaction.id = repayment.transaction_id
     and transaction.organization_id = repayment.organization_id
    where repayment.credit_account_id = request_row.credit_account_id
      and transaction.business_date >= original_row.business_date;

    select count(*)::bigint
    into accrual_count
    from public.interest_accruals as accrual
    where accrual.credit_account_id = request_row.credit_account_id
      and accrual.business_date > original_row.business_date;

    simulated_principal := current_principal;
    simulated_interest := current_interest - original_row.amount_paise;
    if interest_payments > 0 then
      blockers := array_append(blockers, 'COR_INTEREST_ALREADY_PAID');
    end if;
    if accrual_count > 0 then
      blockers := array_append(
        blockers,
        'COR_LATER_ACCRUAL_DEPENDS_ON_CHARGE'
      );
    end if;
    blockers := array_append(
      blockers,
      'COR_INTEREST_REVERSAL_UNSUPPORTED'
    );
    impact_warnings := array_append(
      impact_warnings,
      'COR_INTEREST_CARRY_REQUIRES_FUTURE_ADJUSTMENT_MODEL'
    );
  end if;

  if exists (
    select 1
    from public.financial_reversals as reversal
    where reversal.original_transaction_id = original_row.id
  ) then
    blockers := array_append(blockers, 'COR_ALREADY_REVERSED');
  end if;

  if app_private.financial_transaction_fingerprint(original_row.id)
       <> request_row.original_fingerprint
  then
    blockers := array_append(blockers, 'COR_ORIGINAL_CHANGED');
  end if;

  if simulated_principal < 0 or simulated_interest < 0 then
    blockers := array_append(blockers, 'COR_INVALID_REQUEST');
  end if;

  simulated_available := credit_limit - simulated_principal;

  if request_row.action = 'REVERSE_AND_REPLACE'
     and request_row.original_transaction_type = 'FUEL_CREDIT'
  then
    select proposal.*
    into proposed_fuel
    from public.fuel_credit_correction_proposals as proposal
    where proposal.request_id = request_row.id;
    proposal_found := found;

    replacement_is_valid := proposal_found
      and exists (
        select 1
        from public.fuel_products as product
        where product.id = proposed_fuel.fuel_product_id
          and product.organization_id = request_row.organization_id
          and product.is_active
          and (
            product.station_id is null
            or product.station_id = request_row.station_id
          )
          and product.currency_code = request_row.currency_code
      )
      and proposed_fuel.amount_paise <= simulated_available;

    if not replacement_is_valid then
      if proposal_found
         and proposed_fuel.amount_paise > simulated_available
      then
        blockers := array_append(
          blockers,
          'COR_REPLACEMENT_CREDIT_LIMIT'
        );
      else
        blockers := array_append(blockers, 'COR_REPLACEMENT_INVALID');
      end if;
    end if;
  elsif request_row.action = 'REVERSE_AND_REPLACE'
        and request_row.original_transaction_type = 'CUSTOMER_REPAYMENT'
  then
    select proposal.*
    into proposed_repayment
    from public.repayment_correction_proposals as proposal
    where proposal.request_id = request_row.id;
    proposal_found := found;

    if proposal_found
       and proposed_repayment.payer_driver_id is not null
    then
      select exists (
        select 1
        from public.customer_drivers as driver
        where driver.id = proposed_repayment.payer_driver_id
          and driver.organization_id = request_row.organization_id
          and driver.customer_id = request_row.customer_id
          and driver.status = 'ACTIVE'
      ) into driver_valid;
    end if;

    replacement_is_valid := proposal_found
      and driver_valid
      and proposed_repayment.principal_allocation_paise
        <= simulated_principal
      and proposed_repayment.interest_allocation_paise
        <= simulated_interest;

    if not driver_valid then
      blockers := array_append(blockers, 'COR_INVALID_DRIVER');
    elsif not replacement_is_valid then
      blockers := array_append(
        blockers,
        'COR_REPLACEMENT_ALLOCATION_INVALID'
      );
    end if;
  elsif request_row.action = 'REVERSE_AND_REPLACE' then
    replacement_is_valid := false;
    blockers := array_append(
      blockers,
      'COR_INTEREST_REVERSAL_UNSUPPORTED'
    );
  end if;

  return query select
    original_row.transaction_type,
    original_row.amount_paise,
    cardinality(blockers) = 0,
    current_principal,
    current_interest,
    current_total,
    current_available,
    simulated_principal,
    simulated_interest,
    simulated_available,
    repayment_count,
    fuel_count,
    accrual_count,
    principal_consumed,
    interest_payments,
    replacement_is_valid,
    blockers,
    impact_warnings;
end;
$$;

create function public.get_financial_correction_impact(
  p_request_id uuid
)
returns table (
  original_transaction_type public.ledger_transaction_type,
  original_amount_paise bigint,
  reversal_eligible boolean,
  current_principal_paise bigint,
  current_interest_paise bigint,
  current_total_due_paise bigint,
  current_available_credit_paise bigint,
  simulated_principal_paise bigint,
  simulated_interest_paise bigint,
  simulated_available_credit_paise bigint,
  dependent_repayments bigint,
  dependent_fuel_purchases bigint,
  dependent_interest_accruals bigint,
  applied_principal_lot_consumption_paise bigint,
  applied_interest_payments_paise bigint,
  replacement_valid boolean,
  blocking_error_codes text[],
  warnings text[]
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  request_row public.financial_correction_requests%rowtype;
begin
  if actor_id is null then
    raise exception 'COR_AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select request.*
  into request_row
  from public.financial_correction_requests as request
  where request.id = p_request_id;

  if not found then
    raise exception 'COR_INVALID_REQUEST' using errcode = 'P0001';
  end if;

  if not (
    app_private.is_organization_owner(request_row.organization_id)
    or app_private.is_station_manager(request_row.station_id)
  ) then
    raise exception 'COR_FORBIDDEN' using errcode = 'P0001';
  end if;

  return query
  select *
  from app_private.calculate_financial_correction_impact(p_request_id);
end;
$$;

comment on function public.submit_financial_correction_request(
  uuid,
  text,
  text,
  text,
  uuid,
  uuid,
  numeric,
  text,
  numeric,
  text,
  numeric,
  numeric,
  uuid,
  text,
  text
) is
  'Submits one typed, maker-scoped correction request with idempotent replay.';

comment on function public.get_financial_correction_impact(uuid) is
  'Returns a non-authoritative correction preview; execution recalculates it under locks.';

revoke all on function public.submit_financial_correction_request(
  uuid,
  text,
  text,
  text,
  uuid,
  uuid,
  numeric,
  text,
  numeric,
  text,
  numeric,
  numeric,
  uuid,
  text,
  text
) from public, anon, authenticated, service_role;
revoke all on function public.get_financial_correction_impact(uuid)
  from public, anon, authenticated, service_role;
revoke all on function
  app_private.calculate_financial_correction_impact(uuid)
  from public, anon, authenticated, service_role;
