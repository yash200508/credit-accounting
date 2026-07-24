create function app_private.calculate_credit_account_obligations(
  target_credit_account_id uuid
)
returns table (
  credit_limit_paise bigint,
  outstanding_principal_paise bigint,
  outstanding_interest_paise bigint,
  total_due_paise bigint,
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
  calculated_outstanding_interest numeric;
  calculated_total_due numeric;
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
    ),
    coalesce(
      sum(
        case
          when entry.direction = 'DEBIT' then entry.amount_paise
          when entry.direction = 'CREDIT' then -entry.amount_paise
          else 0
        end
      ) filter (
        where transaction.status = 'POSTED'
          and entry.account_code = 'CUSTOMER_INTEREST_RECEIVABLE'
      ),
      0
    )
  into
    calculated_credit_limit_paise,
    calculated_outstanding_principal,
    calculated_outstanding_interest
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

  if calculated_outstanding_principal < 0
     or calculated_outstanding_interest < 0
  then
    raise exception 'BALANCE_NEGATIVE_OBLIGATION'
      using errcode = 'P0001';
  end if;

  calculated_total_due :=
    calculated_outstanding_principal
    + calculated_outstanding_interest;
  calculated_available_credit :=
    calculated_credit_limit_paise::numeric
    - calculated_outstanding_principal;

  if calculated_outstanding_principal
       not between 0::numeric and 9223372036854775807::numeric
     or calculated_outstanding_interest
       not between 0::numeric and 9223372036854775807::numeric
     or calculated_total_due
       not between 0::numeric and 9223372036854775807::numeric
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
    calculated_outstanding_interest::bigint,
    calculated_total_due::bigint,
    calculated_available_credit::bigint;
end;
$$;

create function public.get_credit_account_obligations(
  p_credit_account_id uuid
)
returns table (
  credit_account_id uuid,
  customer_id uuid,
  organization_id uuid,
  currency_code text,
  credit_limit_paise bigint,
  outstanding_principal_paise bigint,
  outstanding_interest_paise bigint,
  total_due_paise bigint,
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
      or (
        account.home_station_id is not null
        and app_private.is_station_attendant(account.home_station_id)
      )
      or app_private.is_customer(account.customer_id)
    );

  if not found then
    raise exception 'BAL_ACCOUNT_NOT_FOUND_OR_FORBIDDEN'
      using errcode = 'P0001';
  end if;

  select *
  into calculated_balance
  from app_private.calculate_credit_account_obligations(
    p_credit_account_id
  );

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
    calculated_balance.outstanding_interest_paise,
    calculated_balance.total_due_paise,
    calculated_balance.available_credit_paise;
end;
$$;

comment on function app_private.calculate_credit_account_obligations(uuid) is
  'Derives principal, interest, total due, and available credit from posted ledger entries.';
comment on function public.get_credit_account_obligations(uuid) is
  'Returns an authorized account principal, interest, total due, and available credit.';

revoke all on function
  app_private.calculate_credit_account_obligations(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.get_credit_account_obligations(uuid)
  from public, anon, authenticated, service_role;
