create function public.approve_and_execute_financial_correction(
  p_request_id uuid,
  p_expected_version integer
)
returns table (
  request_id uuid,
  status public.financial_correction_status,
  version integer,
  reversal_transaction_id uuid,
  replacement_transaction_id uuid,
  outstanding_principal_paise bigint,
  outstanding_interest_paise bigint,
  total_due_paise bigint,
  available_credit_paise bigint,
  idempotent_replay boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  request_row public.financial_correction_requests%rowtype;
  original_row public.ledger_transactions%rowtype;
  impact record;
  reversal_id uuid := gen_random_uuid();
  replacement_id uuid;
  reversal_business_date date;
  fuel_proposal public.fuel_credit_correction_proposals%rowtype;
  repayment_proposal public.repayment_correction_proposals%rowtype;
  fuel_result record;
  repayment_result record;
  obligation record;
  replacement_amount bigint;
  caught_message text;
begin
  if actor_id is null then
    raise exception 'COR_AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select request.*
  into request_row
  from public.financial_correction_requests as request
  where request.id = p_request_id
  for update;

  if not found then
    raise exception 'COR_INVALID_REQUEST' using errcode = 'P0001';
  end if;

  if not app_private.is_organization_owner(request_row.organization_id) then
    raise exception 'COR_FORBIDDEN' using errcode = 'P0001';
  end if;

  if request_row.requester_id = actor_id then
    raise exception 'COR_SELF_APPROVAL_FORBIDDEN'
      using errcode = 'P0001';
  end if;

  if request_row.status = 'APPROVED_AND_EXECUTED' then
    select *
    into obligation
    from app_private.calculate_credit_account_obligations(
      request_row.credit_account_id
    );

    return query select
      request_row.id,
      request_row.status,
      request_row.version,
      request_row.reversal_transaction_id,
      request_row.replacement_transaction_id,
      obligation.outstanding_principal_paise,
      obligation.outstanding_interest_paise,
      obligation.total_due_paise,
      obligation.available_credit_paise,
      true;
    return;
  end if;

  if request_row.status <> 'PENDING_REVIEW' then
    raise exception 'COR_REQUEST_NOT_PENDING' using errcode = 'P0001';
  end if;

  if p_expected_version is null
     or request_row.version <> p_expected_version
  then
    raise exception 'COR_VERSION_CONFLICT' using errcode = 'P0001';
  end if;

  select transaction.*
  into original_row
  from public.ledger_transactions as transaction
  where transaction.id = request_row.original_transaction_id
    and transaction.organization_id = request_row.organization_id
  for update;

  if not found
     or original_row.status <> 'POSTED'
     or original_row.transaction_type <> request_row.original_transaction_type
     or original_row.transaction_type = 'FINANCIAL_REVERSAL'
  then
    raise exception 'COR_INVALID_ORIGINAL_TRANSACTION'
      using errcode = 'P0001';
  end if;

  perform 1
  from public.credit_accounts as account
  where account.id = request_row.credit_account_id
    and account.organization_id = request_row.organization_id
  for update;

  if not found then
    raise exception 'COR_INVALID_ORIGINAL_TRANSACTION'
      using errcode = 'P0001';
  end if;

  if app_private.financial_transaction_fingerprint(original_row.id)
       <> request_row.original_fingerprint
  then
    raise exception 'COR_ORIGINAL_CHANGED' using errcode = 'P0001';
  end if;

  select *
  into impact
  from app_private.calculate_financial_correction_impact(request_row.id);

  if cardinality(impact.blocking_error_codes) > 0 then
    raise exception using
      message = impact.blocking_error_codes[1],
      errcode = 'P0001';
  end if;

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
    created_by
  )
  values (
    reversal_id,
    original_row.organization_id,
    original_row.station_id,
    original_row.credit_account_id,
    original_row.customer_id,
    'FINANCIAL_REVERSAL',
    'POSTED',
    original_row.amount_paise,
    original_row.currency_code,
    statement_timestamp(),
    actor_id
  )
  returning business_date into reversal_business_date;

  insert into public.ledger_entries (
    organization_id,
    transaction_id,
    account_code,
    direction,
    amount_paise,
    currency_code
  )
  select
    entry.organization_id,
    reversal_id,
    entry.account_code,
    case entry.direction
      when 'DEBIT' then 'CREDIT'::public.ledger_entry_direction
      else 'DEBIT'::public.ledger_entry_direction
    end,
    entry.amount_paise,
    entry.currency_code
  from public.ledger_entries as entry
  where entry.transaction_id = original_row.id
  order by entry.id;

  if request_row.action = 'REVERSE_AND_REPLACE'
     and request_row.original_transaction_type = 'FUEL_CREDIT'
  then
    select proposal.*
    into strict fuel_proposal
    from public.fuel_credit_correction_proposals as proposal
    where proposal.request_id = request_row.id;

    begin
      select *
      into strict fuel_result
      from public.post_fuel_credit_transaction(
        request_row.credit_account_id,
        request_row.station_id,
        fuel_proposal.fuel_product_id,
        fuel_proposal.amount_paise,
        request_row.replacement_idempotency_key,
        fuel_proposal.source_reference
      );
      replacement_id := fuel_result.transaction_id;
      replacement_amount := fuel_proposal.amount_paise;
    exception
      when sqlstate 'P0001' then
        get stacked diagnostics caught_message = message_text;
        if caught_message = 'FCP_INSUFFICIENT_CREDIT' then
          raise exception 'COR_REPLACEMENT_CREDIT_LIMIT'
            using errcode = 'P0001';
        elsif caught_message = 'FCP_AMOUNT_OVERFLOW' then
          raise exception 'COR_OVERFLOW' using errcode = 'P0001';
        else
          raise exception 'COR_REPLACEMENT_INVALID'
            using errcode = 'P0001';
        end if;
    end;
  elsif request_row.action = 'REVERSE_AND_REPLACE'
        and request_row.original_transaction_type = 'CUSTOMER_REPAYMENT'
  then
    select proposal.*
    into strict repayment_proposal
    from public.repayment_correction_proposals as proposal
    where proposal.request_id = request_row.id;

    begin
      select *
      into strict repayment_result
      from public.post_customer_repayment(
        request_row.credit_account_id,
        request_row.station_id,
        repayment_proposal.total_amount_paise,
        repayment_proposal.allocation_mode::text,
        request_row.replacement_idempotency_key,
        repayment_proposal.principal_allocation_paise,
        repayment_proposal.interest_allocation_paise,
        repayment_proposal.payer_driver_id,
        repayment_proposal.source_reference,
        repayment_proposal.payment_method::text
      );
      replacement_id := repayment_result.transaction_id;
      replacement_amount := repayment_proposal.total_amount_paise;
    exception
      when sqlstate 'P0001' then
        get stacked diagnostics caught_message = message_text;
        if caught_message in ('RPP_INVALID_DRIVER', 'RPP_DRIVER_REVOKED') then
          raise exception 'COR_INVALID_DRIVER' using errcode = 'P0001';
        elsif caught_message = 'RPP_OVERFLOW' then
          raise exception 'COR_OVERFLOW' using errcode = 'P0001';
        elsif caught_message in (
          'RPP_ALLOCATION_MISMATCH',
          'RPP_PRINCIPAL_EXCEEDS_DUE',
          'RPP_INTEREST_EXCEEDS_DUE',
          'RPP_NOTHING_DUE'
        ) then
          raise exception 'COR_REPLACEMENT_ALLOCATION_INVALID'
            using errcode = 'P0001';
        else
          raise exception 'COR_REPLACEMENT_INVALID'
            using errcode = 'P0001';
        end if;
    end;
  elsif request_row.action = 'REVERSE_AND_REPLACE' then
    raise exception 'COR_INTEREST_REVERSAL_UNSUPPORTED'
      using errcode = 'P0001';
  end if;

  insert into public.financial_reversals (
    request_id,
    organization_id,
    station_id,
    credit_account_id,
    customer_id,
    original_transaction_id,
    reversal_transaction_id,
    replacement_transaction_id,
    currency_code,
    original_business_date,
    reversal_business_date,
    original_amount_paise,
    reversal_amount_paise,
    executed_by,
    correlation_id
  )
  values (
    request_row.id,
    request_row.organization_id,
    request_row.station_id,
    request_row.credit_account_id,
    request_row.customer_id,
    original_row.id,
    reversal_id,
    replacement_id,
    original_row.currency_code,
    original_row.business_date,
    reversal_business_date,
    original_row.amount_paise,
    original_row.amount_paise,
    actor_id,
    request_row.correlation_id
  );

  update public.financial_correction_requests as target
  set
    status = 'APPROVED_AND_EXECUTED',
    version = target.version + 1,
    decided_by = actor_id,
    decision_reason = null,
    decided_at = statement_timestamp(),
    reversal_transaction_id = reversal_id,
    replacement_transaction_id = replacement_id,
    updated_at = statement_timestamp()
  where target.id = request_row.id;

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
  values
    (
      request_row.id,
      request_row.organization_id,
      'APPROVED_AND_EXECUTED',
      'PENDING_REVIEW',
      'APPROVED_AND_EXECUTED',
      actor_id,
      'OWNER',
      'Approved by an independent organization owner',
      request_row.correlation_id
    ),
    (
      request_row.id,
      request_row.organization_id,
      'REVERSAL_EXECUTED',
      'PENDING_REVIEW',
      'APPROVED_AND_EXECUTED',
      actor_id,
      'OWNER',
      'Exact compensating transaction executed',
      request_row.correlation_id
    );

  if replacement_id is not null then
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
      request_row.id,
      request_row.organization_id,
      'REPLACEMENT_POSTED',
      'PENDING_REVIEW',
      'APPROVED_AND_EXECUTED',
      actor_id,
      'OWNER',
      'Typed corrected replacement posted atomically',
      request_row.correlation_id
    );
  end if;

  select *
  into obligation
  from app_private.calculate_credit_account_obligations(
    request_row.credit_account_id
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
  values
    (
      actor_id,
      'OWNER',
      request_row.organization_id,
      request_row.station_id,
      'FINANCIAL',
      'financial_correction.approved',
      'financial_correction_request',
      request_row.id,
      request_row.explanation,
      jsonb_build_object(
        'status', request_row.status,
        'version', request_row.version
      ),
      jsonb_build_object(
        'status', 'APPROVED_AND_EXECUTED',
        'version', request_row.version + 1,
        'original_transaction_id', original_row.id,
        'reversal_transaction_id', reversal_id,
        'replacement_transaction_id', replacement_id,
        'correlation_id', request_row.correlation_id
      ),
      request_row.correlation_id,
      'financial-correction-rpc'
    ),
    (
      actor_id,
      'OWNER',
      request_row.organization_id,
      request_row.station_id,
      'FINANCIAL',
      'financial_correction.reversal_executed',
      'ledger_transaction',
      reversal_id,
      request_row.explanation,
      jsonb_build_object(
        'original_transaction_id', original_row.id,
        'original_transaction_type', original_row.transaction_type,
        'original_business_date', original_row.business_date,
        'original_amount_paise', original_row.amount_paise
      ),
      jsonb_build_object(
        'reversal_transaction_id', reversal_id,
        'reversal_business_date', reversal_business_date,
        'reversal_amount_paise', original_row.amount_paise,
        'outstanding_principal_paise',
          obligation.outstanding_principal_paise,
        'outstanding_interest_paise',
          obligation.outstanding_interest_paise,
        'available_credit_paise', obligation.available_credit_paise,
        'correlation_id', request_row.correlation_id
      ),
      request_row.correlation_id,
      'financial-correction-rpc'
    );

  if replacement_id is not null then
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
      'OWNER',
      request_row.organization_id,
      request_row.station_id,
      'FINANCIAL',
      'financial_correction.replacement_posted',
      'ledger_transaction',
      replacement_id,
      request_row.explanation,
      jsonb_build_object(
        'original_transaction_id', original_row.id,
        'reversal_transaction_id', reversal_id
      ),
      jsonb_build_object(
        'replacement_transaction_id', replacement_id,
        'replacement_amount_paise', replacement_amount,
        'correlation_id', request_row.correlation_id
      ),
      request_row.correlation_id,
      'financial-correction-rpc'
    );
  end if;

  return query select
    request_row.id,
    'APPROVED_AND_EXECUTED'::public.financial_correction_status,
    request_row.version + 1,
    reversal_id,
    replacement_id,
    obligation.outstanding_principal_paise,
    obligation.outstanding_interest_paise,
    obligation.total_due_paise,
    obligation.available_credit_paise,
    false;
exception
  when deadlock_detected
    or serialization_failure
    or lock_not_available
  then
    raise exception 'COR_LOCK_RETRY' using errcode = 'P0001';
end;
$$;

comment on function public.approve_and_execute_financial_correction(
  uuid,
  integer
) is
  'Independently approves and atomically executes one exact current-date reversal and optional typed replacement.';

revoke all on function public.approve_and_execute_financial_correction(
  uuid,
  integer
) from public, anon, authenticated, service_role;

create or replace function app_private.principal_lots_as_of(
  target_credit_account_id uuid,
  target_business_date date
)
returns table (
  organization_id uuid,
  station_id uuid,
  customer_id uuid,
  source_transaction_id uuid,
  source_business_date date,
  source_occurred_at timestamptz,
  source_principal_paise bigint,
  source_remaining_principal_paise bigint,
  source_policy_id uuid,
  grace_days integer,
  grace_policy public.interest_grace_policy_type,
  eligibility_business_date date
)
language sql
stable
security definer
set search_path = ''
as $$
  with account_scope as (
    select
      account.id,
      account.organization_id,
      account.home_station_id as station_id,
      account.customer_id
    from public.credit_accounts as account
    where account.id = target_credit_account_id
  ),
  fuel_lots as (
    select
      account.organization_id,
      account.station_id,
      account.customer_id,
      transaction.id as source_transaction_id,
      transaction.business_date as source_business_date,
      transaction.occurred_at as source_occurred_at,
      transaction.amount_paise as source_principal_paise,
      coalesce(
        sum(transaction.amount_paise::numeric) over (
          order by
            transaction.business_date,
            transaction.occurred_at,
            transaction.id
          rows between unbounded preceding and 1 preceding
        ),
        0::numeric
      ) as prior_principal_paise
    from account_scope as account
    join public.ledger_transactions as transaction
      on transaction.credit_account_id = account.id
     and transaction.organization_id = account.organization_id
     and transaction.transaction_type = 'FUEL_CREDIT'
     and transaction.status = 'POSTED'
     and transaction.business_date <= target_business_date
    where not exists (
      select 1
      from public.financial_reversals as reversal
      where reversal.original_transaction_id = transaction.id
        and reversal.reversal_business_date <= target_business_date
    )
  ),
  principal_repaid as (
    select coalesce(sum(
      case
        when transaction.transaction_type = 'CUSTOMER_REPAYMENT'
             and entry.direction = 'CREDIT'
          then entry.amount_paise::numeric
        when transaction.transaction_type = 'FINANCIAL_REVERSAL'
             and entry.direction = 'DEBIT'
             and original.transaction_type = 'CUSTOMER_REPAYMENT'
          then -entry.amount_paise::numeric
        else 0::numeric
      end
    ), 0::numeric) as amount_paise
    from account_scope as account
    join public.ledger_transactions as transaction
      on transaction.credit_account_id = account.id
     and transaction.organization_id = account.organization_id
     and transaction.status = 'POSTED'
     and transaction.business_date <= target_business_date
    join public.ledger_entries as entry
      on entry.transaction_id = transaction.id
     and entry.organization_id = transaction.organization_id
     and entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
    left join public.financial_reversals as reversal
      on reversal.reversal_transaction_id = transaction.id
    left join public.ledger_transactions as original
      on original.id = reversal.original_transaction_id
     and original.organization_id = reversal.organization_id
  )
  select
    lot.organization_id,
    lot.station_id,
    lot.customer_id,
    lot.source_transaction_id,
    lot.source_business_date,
    lot.source_occurred_at,
    lot.source_principal_paise,
    greatest(
      0::numeric,
      lot.source_principal_paise::numeric
        - greatest(
          0::numeric,
          repayment.amount_paise - lot.prior_principal_paise
        )
    )::bigint as source_remaining_principal_paise,
    source_policy.policy_id,
    source_policy.grace_days,
    source_policy.grace_policy,
    lot.source_business_date
      + source_policy.grace_days as eligibility_business_date
  from fuel_lots as lot
  cross join principal_repaid as repayment
  cross join lateral app_private.resolve_effective_interest_policy(
    lot.organization_id,
    lot.customer_id,
    lot.source_business_date
  ) as source_policy
  order by
    lot.source_business_date,
    lot.source_occurred_at,
    lot.source_transaction_id;
$$;

create or replace function app_private.calculate_interest_components(
  target_credit_account_id uuid,
  target_accrual_business_date date
)
returns table (
  organization_id uuid,
  station_id uuid,
  customer_id uuid,
  source_transaction_id uuid,
  source_business_date date,
  eligibility_business_date date,
  interest_business_date date,
  accrual_business_date date,
  component_kind public.interest_accrual_component_kind,
  source_remaining_principal_paise bigint,
  raw_interest_paise numeric(38, 18),
  source_policy_id uuid,
  rate_policy_id uuid,
  annual_rate numeric(9, 8),
  grace_days integer,
  grace_policy public.interest_grace_policy_type,
  interest_enabled boolean,
  day_count_basis smallint
)
language sql
stable
security definer
set search_path = ''
as $$
  with target_lots as (
    select *
    from app_private.principal_lots_as_of(
      target_credit_account_id,
      target_accrual_business_date
    )
  ),
  source_lots as (
    select
      lot.*,
      coalesce(
        sum(lot.source_principal_paise::numeric) over (
          order by
            lot.source_business_date,
            lot.source_occurred_at,
            lot.source_transaction_id
          rows between unbounded preceding and 1 preceding
        ),
        0::numeric
      ) as prior_principal_paise
    from target_lots as lot
  ),
  repayment_by_date as (
    select
      transaction.business_date,
      sum(
        case
          when transaction.transaction_type = 'CUSTOMER_REPAYMENT'
               and entry.direction = 'CREDIT'
            then entry.amount_paise::numeric
          when transaction.transaction_type = 'FINANCIAL_REVERSAL'
               and entry.direction = 'DEBIT'
               and original.transaction_type = 'CUSTOMER_REPAYMENT'
            then -entry.amount_paise::numeric
          else 0::numeric
        end
      ) as repaid_principal_paise
    from public.ledger_transactions as transaction
    join public.ledger_entries as entry
      on entry.transaction_id = transaction.id
     and entry.organization_id = transaction.organization_id
     and entry.account_code = 'CUSTOMER_ACCOUNTS_RECEIVABLE'
    left join public.financial_reversals as reversal
      on reversal.reversal_transaction_id = transaction.id
    left join public.ledger_transactions as original
      on original.id = reversal.original_transaction_id
     and original.organization_id = reversal.organization_id
    where transaction.credit_account_id = target_credit_account_id
      and transaction.status = 'POSTED'
      and transaction.business_date <= target_accrual_business_date
    group by transaction.business_date
  ),
  repayment_cumulative as (
    select
      repayment.business_date,
      sum(repayment.repaid_principal_paise) over (
        order by repayment.business_date
        rows between unbounded preceding and current row
      ) as repaid_principal_paise
    from repayment_by_date as repayment
  ),
  daily_components as (
    select
      lot.organization_id,
      lot.station_id,
      lot.customer_id,
      lot.source_transaction_id,
      lot.source_business_date,
      lot.eligibility_business_date,
      target_accrual_business_date as interest_business_date,
      target_accrual_business_date as accrual_business_date,
      'DAILY'::public.interest_accrual_component_kind
        as component_kind,
      lot.source_remaining_principal_paise,
      lot.source_policy_id,
      lot.grace_days,
      lot.grace_policy
    from source_lots as lot
    where lot.source_remaining_principal_paise > 0
      and target_accrual_business_date
        >= lot.eligibility_business_date
  ),
  retroactive_dates as (
    select
      threshold_lot.organization_id,
      threshold_lot.station_id,
      threshold_lot.customer_id,
      threshold_lot.source_transaction_id,
      threshold_lot.source_business_date,
      threshold_lot.eligibility_business_date,
      generated_date::date as interest_business_date,
      target_accrual_business_date as accrual_business_date,
      'RETROACTIVE_CATCH_UP'
        ::public.interest_accrual_component_kind as component_kind,
      threshold_lot.source_policy_id,
      threshold_lot.grace_days,
      threshold_lot.grace_policy,
      threshold_lot.source_principal_paise,
      threshold_lot.prior_principal_paise
    from source_lots as threshold_lot
    cross join lateral generate_series(
      threshold_lot.source_business_date::timestamp,
      (
        threshold_lot.eligibility_business_date - 1
      )::timestamp,
      interval '1 day'
    ) as generated_date
    where threshold_lot.source_remaining_principal_paise > 0
      and threshold_lot.grace_policy = 'RETROACTIVE_AFTER_GRACE'
      and target_accrual_business_date
        = threshold_lot.eligibility_business_date
  ),
  retroactive_components as (
    select
      retroactive.organization_id,
      retroactive.station_id,
      retroactive.customer_id,
      retroactive.source_transaction_id,
      retroactive.source_business_date,
      retroactive.eligibility_business_date,
      retroactive.interest_business_date,
      retroactive.accrual_business_date,
      retroactive.component_kind,
      calculated_lot.source_remaining_principal_paise,
      retroactive.source_policy_id,
      retroactive.grace_days,
      retroactive.grace_policy
    from retroactive_dates as retroactive
    left join lateral (
      select repayment.repaid_principal_paise
      from repayment_cumulative as repayment
      where repayment.business_date
        <= retroactive.interest_business_date
      order by repayment.business_date desc
      limit 1
    ) as repayment_at_date on true
    cross join lateral (
      select greatest(
        0::numeric,
        retroactive.source_principal_paise::numeric
          - greatest(
            0::numeric,
            coalesce(
              repayment_at_date.repaid_principal_paise,
              0::numeric
            ) - retroactive.prior_principal_paise
          )
      )::bigint as source_remaining_principal_paise
    ) as calculated_lot
    where calculated_lot.source_remaining_principal_paise > 0
  ),
  unpriced_components as (
    select * from daily_components
    union all
    select * from retroactive_components
  )
  select
    component.organization_id,
    component.station_id,
    component.customer_id,
    component.source_transaction_id,
    component.source_business_date,
    component.eligibility_business_date,
    component.interest_business_date,
    component.accrual_business_date,
    component.component_kind,
    component.source_remaining_principal_paise,
    (
      case
        when rate_policy.interest_enabled
          then (
            component.source_remaining_principal_paise::numeric(38, 18)
            * rate_policy.annual_rate::numeric(38, 18)
            / rate_policy.day_count_basis::numeric(38, 18)
          )
        else 0::numeric
      end
    )::numeric(38, 18) as raw_interest_paise,
    component.source_policy_id,
    rate_policy.policy_id as rate_policy_id,
    rate_policy.annual_rate,
    component.grace_days,
    component.grace_policy,
    rate_policy.interest_enabled,
    rate_policy.day_count_basis
  from unpriced_components as component
  cross join lateral app_private.resolve_effective_interest_policy(
    component.organization_id,
    component.customer_id,
    component.interest_business_date
  ) as rate_policy
  order by
    component.interest_business_date,
    component.source_business_date,
    component.source_transaction_id,
    component.component_kind;
$$;

revoke all on function app_private.principal_lots_as_of(uuid, date)
  from public, anon, authenticated, service_role;
revoke all on function
  app_private.calculate_interest_components(uuid, date)
  from public, anon, authenticated, service_role;
