create function app_private.is_safe_correction_text(
  candidate text,
  minimum_length integer,
  maximum_length integer
)
returns boolean
language sql
immutable
security invoker
set search_path = ''
as $$
  select
    candidate is not null
    and candidate = btrim(candidate)
    and char_length(candidate) between minimum_length and maximum_length
    and candidate !~ '[[:cntrl:]]'
    and candidate !~* '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
    and candidate !~ '[[:alnum:]_+/=-]{40,}';
$$;

create function app_private.financial_transaction_fingerprint(
  target_transaction_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select encode(
    sha256(
      convert_to(
        jsonb_build_object(
          'transaction',
          jsonb_build_object(
            'id', transaction.id,
            'organization_id', transaction.organization_id,
            'station_id', transaction.station_id,
            'credit_account_id', transaction.credit_account_id,
            'customer_id', transaction.customer_id,
            'transaction_type', transaction.transaction_type,
            'status', transaction.status,
            'amount_paise', transaction.amount_paise,
            'currency_code', transaction.currency_code,
            'business_date', transaction.business_date,
            'occurred_at', transaction.occurred_at,
            'created_by', transaction.created_by,
            'created_at', transaction.created_at
          ),
          'entries',
          coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'account_code', entry.account_code,
                'direction', entry.direction,
                'amount_paise', entry.amount_paise,
                'currency_code', entry.currency_code
              )
              order by
                entry.account_code,
                entry.direction,
                entry.amount_paise,
                entry.id
            )
            from public.ledger_entries as entry
            where entry.transaction_id = transaction.id
          ), '[]'::jsonb),
          'fuel_sale',
          coalesce((
            select jsonb_build_object(
              'fuel_product_id', sale.fuel_product_id,
              'amount_paise', sale.amount_paise,
              'source_reference', sale.source_reference
            )
            from public.fuel_credit_sales as sale
            where sale.transaction_id = transaction.id
          ), 'null'::jsonb),
          'repayment',
          coalesce((
            select jsonb_build_object(
              'total_amount_paise', repayment.total_amount_paise,
              'allocation_mode', repayment.allocation_mode,
              'payment_method', repayment.payment_method,
              'payer_type', repayment.payer_type,
              'payer_driver_id', repayment.payer_driver_id,
              'source_reference', repayment.source_reference,
              'allocations', coalesce((
                select jsonb_agg(
                  jsonb_build_object(
                    'component', allocation.component,
                    'amount_paise', allocation.amount_paise
                  )
                  order by allocation.component
                )
                from public.repayment_allocations as allocation
                where allocation.repayment_id = repayment.id
              ), '[]'::jsonb)
            )
            from public.customer_repayments as repayment
            where repayment.transaction_id = transaction.id
          ), 'null'::jsonb),
          'interest_accrual',
          coalesce((
            select jsonb_build_object(
              'id', accrual.id,
              'business_date', accrual.business_date,
              'posted_interest_paise', accrual.posted_interest_paise,
              'cumulative_raw_interest_paise',
                accrual.cumulative_raw_interest_paise,
              'cumulative_posted_interest_paise',
                accrual.cumulative_posted_interest_paise,
              'closing_fractional_carry_paise',
                accrual.closing_fractional_carry_paise
            )
            from public.interest_accruals as accrual
            where accrual.ledger_transaction_id = transaction.id
          ), 'null'::jsonb)
        )::text,
        'UTF8'
      )
    ),
    'hex'
  )
  from public.ledger_transactions as transaction
  where transaction.id = target_transaction_id;
$$;

create function app_private.guard_financial_correction_request_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'correction requests are append-only'
      using errcode = '23514';
  end if;

  if old.status <> 'PENDING_REVIEW' then
    raise exception 'terminal correction requests are immutable'
      using errcode = '23514';
  end if;

  if new.status = 'PENDING_REVIEW'
     or new.version <> old.version + 1
     or new.updated_at < old.updated_at
     or (
       to_jsonb(new)
         - array[
             'status',
             'version',
             'decided_by',
             'decision_reason',
             'decided_at',
             'reversal_transaction_id',
             'replacement_transaction_id',
             'updated_at'
           ]
       <>
       to_jsonb(old)
         - array[
             'status',
             'version',
             'decided_by',
             'decision_reason',
             'decided_at',
             'reversal_transaction_id',
             'replacement_transaction_id',
             'updated_at'
           ]
     )
  then
    raise exception 'correction request mutation is invalid'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create function app_private.reject_financial_correction_evidence_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'financial correction evidence is immutable'
    using errcode = '23514';
end;
$$;

create function app_private.assert_financial_correction_proposal_shape()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_request_id uuid;
  request_row public.financial_correction_requests%rowtype;
  fuel_proposal_count bigint;
  repayment_proposal_count bigint;
begin
  if tg_table_name = 'financial_correction_requests' then
    target_request_id := coalesce(new.id, old.id);
  else
    target_request_id := coalesce(new.request_id, old.request_id);
  end if;

  select request.*
  into request_row
  from public.financial_correction_requests as request
  where request.id = target_request_id;

  if not found then
    return null;
  end if;

  select count(*) into fuel_proposal_count
  from public.fuel_credit_correction_proposals as proposal
  where proposal.request_id = target_request_id
    and proposal.organization_id = request_row.organization_id
    and proposal.station_id = request_row.station_id
    and proposal.credit_account_id = request_row.credit_account_id
    and proposal.customer_id = request_row.customer_id;

  select count(*) into repayment_proposal_count
  from public.repayment_correction_proposals as proposal
  where proposal.request_id = target_request_id
    and proposal.organization_id = request_row.organization_id
    and proposal.station_id = request_row.station_id
    and proposal.credit_account_id = request_row.credit_account_id
    and proposal.customer_id = request_row.customer_id;

  if request_row.action = 'REVERSAL_ONLY'
     and (fuel_proposal_count <> 0 or repayment_proposal_count <> 0)
  then
    raise exception 'reversal-only request cannot have a replacement proposal'
      using errcode = '23514';
  elsif request_row.action = 'REVERSE_AND_REPLACE'
        and request_row.original_transaction_type = 'FUEL_CREDIT'
        and (
          fuel_proposal_count <> 1
          or repayment_proposal_count <> 0
        )
  then
    raise exception 'fuel correction requires one typed fuel proposal'
      using errcode = '23514';
  elsif request_row.action = 'REVERSE_AND_REPLACE'
        and request_row.original_transaction_type = 'CUSTOMER_REPAYMENT'
        and (
          fuel_proposal_count <> 0
          or repayment_proposal_count <> 1
        )
  then
    raise exception 'repayment correction requires one typed repayment proposal'
      using errcode = '23514';
  elsif request_row.action = 'REVERSE_AND_REPLACE'
        and request_row.original_transaction_type = 'INTEREST_CHARGE'
  then
    raise exception 'interest correction cannot have a manual replacement'
      using errcode = '23514';
  end if;

  return null;
end;
$$;

create function app_private.assert_financial_reversal_shape()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_transaction_id uuid;
  reversal_row public.ledger_transactions%rowtype;
  original_row public.ledger_transactions%rowtype;
  evidence_row public.financial_reversals%rowtype;
  missing_or_extra_count bigint;
begin
  if tg_table_name = 'ledger_transactions' then
    target_transaction_id := coalesce(new.id, old.id);
  elsif tg_table_name = 'ledger_entries' then
    target_transaction_id := coalesce(new.transaction_id, old.transaction_id);
  else
    target_transaction_id :=
      coalesce(new.reversal_transaction_id, old.reversal_transaction_id);
  end if;

  select transaction.*
  into reversal_row
  from public.ledger_transactions as transaction
  where transaction.id = target_transaction_id;

  if not found
     or reversal_row.transaction_type <> 'FINANCIAL_REVERSAL'
  then
    return null;
  end if;

  select reversal.*
  into evidence_row
  from public.financial_reversals as reversal
  where reversal.reversal_transaction_id = target_transaction_id;

  if not found then
    raise exception 'financial reversal has no immutable evidence'
      using errcode = '23514';
  end if;

  select transaction.*
  into original_row
  from public.ledger_transactions as transaction
  where transaction.id = evidence_row.original_transaction_id;

  if not found
     or original_row.transaction_type = 'FINANCIAL_REVERSAL'
     or reversal_row.status <> 'POSTED'
     or reversal_row.organization_id <> original_row.organization_id
     or reversal_row.station_id <> original_row.station_id
     or reversal_row.credit_account_id <> original_row.credit_account_id
     or reversal_row.customer_id <> original_row.customer_id
     or reversal_row.currency_code <> original_row.currency_code
     or reversal_row.amount_paise <> original_row.amount_paise
     or reversal_row.business_date <> evidence_row.reversal_business_date
     or original_row.business_date <> evidence_row.original_business_date
     or reversal_row.amount_paise <> evidence_row.reversal_amount_paise
     or original_row.amount_paise <> evidence_row.original_amount_paise
  then
    raise exception 'financial reversal header is not an exact compensation'
      using errcode = '23514';
  end if;

  select count(*) into missing_or_extra_count
  from (
    (
      select
        original_entry.account_code,
        case original_entry.direction
          when 'DEBIT' then 'CREDIT'::public.ledger_entry_direction
          else 'DEBIT'::public.ledger_entry_direction
        end as direction,
        original_entry.amount_paise,
        original_entry.currency_code
      from public.ledger_entries as original_entry
      where original_entry.transaction_id = original_row.id
      except all
      select
        reversal_entry.account_code,
        reversal_entry.direction,
        reversal_entry.amount_paise,
        reversal_entry.currency_code
      from public.ledger_entries as reversal_entry
      where reversal_entry.transaction_id = reversal_row.id
    )
    union all
    (
      select
        reversal_entry.account_code,
        reversal_entry.direction,
        reversal_entry.amount_paise,
        reversal_entry.currency_code
      from public.ledger_entries as reversal_entry
      where reversal_entry.transaction_id = reversal_row.id
      except all
      select
        original_entry.account_code,
        case original_entry.direction
          when 'DEBIT' then 'CREDIT'::public.ledger_entry_direction
          else 'DEBIT'::public.ledger_entry_direction
        end,
        original_entry.amount_paise,
        original_entry.currency_code
      from public.ledger_entries as original_entry
      where original_entry.transaction_id = original_row.id
    )
  ) as shape_difference;

  if missing_or_extra_count <> 0 then
    raise exception 'financial reversal entries are not an exact compensation'
      using errcode = '23514';
  end if;

  return null;
end;
$$;

revoke all on function app_private.is_safe_correction_text(
  text,
  integer,
  integer
) from public, anon, authenticated, service_role;
revoke all on function app_private.financial_transaction_fingerprint(uuid)
  from public, anon, authenticated, service_role;
revoke all on function
  app_private.guard_financial_correction_request_mutation()
  from public, anon, authenticated, service_role;
revoke all on function
  app_private.reject_financial_correction_evidence_mutation()
  from public, anon, authenticated, service_role;
revoke all on function
  app_private.assert_financial_correction_proposal_shape()
  from public, anon, authenticated, service_role;
revoke all on function app_private.assert_financial_reversal_shape()
  from public, anon, authenticated, service_role;

create trigger financial_correction_requests_guard_update_delete
before update or delete on public.financial_correction_requests
for each row execute function
  app_private.guard_financial_correction_request_mutation();

create trigger fuel_credit_correction_proposals_reject_update_delete
before update or delete on public.fuel_credit_correction_proposals
for each row execute function
  app_private.reject_financial_correction_evidence_mutation();

create trigger repayment_correction_proposals_reject_update_delete
before update or delete on public.repayment_correction_proposals
for each row execute function
  app_private.reject_financial_correction_evidence_mutation();

create trigger financial_correction_events_reject_update_delete
before update or delete on public.financial_correction_events
for each row execute function
  app_private.reject_financial_correction_evidence_mutation();

create trigger financial_reversals_reject_update_delete
before update or delete on public.financial_reversals
for each row execute function
  app_private.reject_financial_correction_evidence_mutation();

create constraint trigger financial_correction_requests_proposal_shape
after insert or update on public.financial_correction_requests
deferrable initially deferred
for each row execute function
  app_private.assert_financial_correction_proposal_shape();

create constraint trigger fuel_correction_proposals_request_shape
after insert or update or delete
on public.fuel_credit_correction_proposals
deferrable initially deferred
for each row execute function
  app_private.assert_financial_correction_proposal_shape();

create constraint trigger repayment_correction_proposals_request_shape
after insert or update or delete
on public.repayment_correction_proposals
deferrable initially deferred
for each row execute function
  app_private.assert_financial_correction_proposal_shape();

create constraint trigger ledger_transactions_require_reversal_shape
after insert or update on public.ledger_transactions
deferrable initially deferred
for each row execute function app_private.assert_financial_reversal_shape();

create constraint trigger ledger_entries_require_reversal_shape
after insert or update or delete on public.ledger_entries
deferrable initially deferred
for each row execute function app_private.assert_financial_reversal_shape();

create constraint trigger financial_reversals_require_exact_shape
after insert or update on public.financial_reversals
deferrable initially deferred
for each row execute function app_private.assert_financial_reversal_shape();
