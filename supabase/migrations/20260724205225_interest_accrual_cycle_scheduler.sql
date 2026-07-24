create extension if not exists pg_cron with schema pg_catalog;

create function app_private.run_interest_accrual_for_station(
  target_station_id uuid,
  target_requested_at timestamptz,
  target_trigger_source public.interest_accrual_trigger_source,
  target_request_id uuid,
  target_max_catch_up_days integer
)
returns table (
  interest_accrual_run_id uuid,
  run_status public.interest_accrual_run_status,
  result_code text,
  accounts_examined integer,
  account_days_processed integer,
  accrual_rows_created integer,
  components_created integer,
  interest_posted_paise bigint,
  more_dates_pending boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_station public.stations%rowtype;
  existing_run public.interest_accrual_runs%rowtype;
  new_run_id uuid := gen_random_uuid();
  calculated_station_local_date date;
  calculated_latest_completed_date date;
  account_row record;
  posting_result record;
  next_business_date date;
  first_fuel_business_date date;
  last_accrual_business_date date;
  processed_for_account integer;
  calculated_accounts_examined integer := 0;
  calculated_account_days_processed integer := 0;
  calculated_accrual_rows_created integer := 0;
  calculated_components_created integer := 0;
  calculated_interest_posted_paise numeric := 0;
  calculated_more_dates_pending boolean := false;
  calculated_first_business_date date;
  calculated_last_business_date date;
  final_status public.interest_accrual_run_status;
  final_result_code text;
  failure_sqlstate text;
begin
  if target_requested_at is null
     or target_request_id is null
     or target_trigger_source is null
  then
    raise exception 'IAC_INVALID_DATE'
      using errcode = '22023';
  end if;

  if target_max_catch_up_days not between 1 and 3660 then
    raise exception 'IAC_CATCH_UP_LIMIT_INVALID'
      using errcode = '22023';
  end if;

  select station.*
  into target_station
  from public.stations as station
  where station.id = target_station_id;

  if not found then
    raise exception 'IAC_STATION_NOT_FOUND'
      using errcode = 'P0001';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(target_station_id::text, 24072026)
  );

  select run.*
  into existing_run
  from public.interest_accrual_runs as run
  where run.organization_id = target_station.organization_id
    and run.station_id = target_station_id
    and run.request_id = target_request_id;

  if found then
    return query
    select
      existing_run.id,
      existing_run.status,
      existing_run.result_code,
      existing_run.accounts_examined,
      existing_run.account_days_processed,
      existing_run.accrual_rows_created,
      existing_run.components_created,
      existing_run.interest_posted_paise,
      existing_run.more_dates_pending;
    return;
  end if;

  calculated_station_local_date :=
    (target_requested_at at time zone target_station.time_zone_name)::date;
  calculated_latest_completed_date :=
    calculated_station_local_date - 1;

  insert into public.interest_accrual_runs (
    id,
    organization_id,
    station_id,
    trigger_source,
    request_id,
    requested_at,
    station_time_zone_name,
    station_local_date,
    latest_completed_business_date,
    max_catch_up_days,
    status
  )
  values (
    new_run_id,
    target_station.organization_id,
    target_station_id,
    target_trigger_source,
    target_request_id,
    target_requested_at,
    target_station.time_zone_name,
    calculated_station_local_date,
    calculated_latest_completed_date,
    target_max_catch_up_days,
    'STARTED'
  );

  begin
    for account_row in
      select account.id
      from public.credit_accounts as account
      where account.organization_id = target_station.organization_id
        and account.home_station_id = target_station_id
        and exists (
          select 1
          from public.ledger_transactions as transaction
          where transaction.credit_account_id = account.id
            and transaction.organization_id = account.organization_id
            and transaction.transaction_type = 'FUEL_CREDIT'
            and transaction.status = 'POSTED'
            and transaction.business_date
              <= calculated_latest_completed_date
        )
      order by account.id
    loop
      calculated_accounts_examined :=
        calculated_accounts_examined + 1;

      select min(transaction.business_date)
      into first_fuel_business_date
      from public.ledger_transactions as transaction
      where transaction.credit_account_id = account_row.id
        and transaction.organization_id =
          target_station.organization_id
        and transaction.transaction_type = 'FUEL_CREDIT'
        and transaction.status = 'POSTED';

      select max(accrual.business_date)
      into last_accrual_business_date
      from public.interest_accruals as accrual
      where accrual.credit_account_id = account_row.id
        and accrual.calculation_version = 1;

      next_business_date := coalesce(
        last_accrual_business_date + 1,
        first_fuel_business_date
      );
      processed_for_account := 0;

      while next_business_date
              <= calculated_latest_completed_date
        and processed_for_account < target_max_catch_up_days
      loop
        select *
        into posting_result
        from app_private.post_interest_for_account_date(
          new_run_id,
          account_row.id,
          next_business_date
        );

        calculated_account_days_processed :=
          calculated_account_days_processed + 1;
        processed_for_account := processed_for_account + 1;
        calculated_first_business_date := least(
          coalesce(
            calculated_first_business_date,
            next_business_date
          ),
          next_business_date
        );
        calculated_last_business_date := greatest(
          coalesce(
            calculated_last_business_date,
            next_business_date
          ),
          next_business_date
        );

        if posting_result.was_created then
          calculated_accrual_rows_created :=
            calculated_accrual_rows_created + 1;
          calculated_interest_posted_paise :=
            calculated_interest_posted_paise
              + posting_result.posted_interest_paise;

          select
            calculated_components_created + count(*)::integer
          into calculated_components_created
          from public.interest_accrual_components as component
          where component.interest_accrual_id =
            posting_result.interest_accrual_id;
        end if;

        next_business_date := next_business_date + 1;
      end loop;

      if next_business_date <= calculated_latest_completed_date then
        calculated_more_dates_pending := true;
      end if;
    end loop;

    if calculated_interest_posted_paise
         not between 0::numeric and 9223372036854775807::numeric
    then
      raise exception 'IAC_RUN_INTEREST_OVERFLOW'
        using errcode = '22003';
    end if;

    if calculated_more_dates_pending then
      final_status := 'COMPLETED_WITH_REMAINING';
      final_result_code := 'IAC_CATCHUP_LIMIT';
    else
      final_status := 'COMPLETED';
      final_result_code := 'IAC_COMPLETED';
    end if;

    update public.interest_accrual_runs
    set
      first_business_date = calculated_first_business_date,
      last_business_date = calculated_last_business_date,
      accounts_examined = calculated_accounts_examined,
      account_days_processed =
        calculated_account_days_processed,
      accrual_rows_created =
        calculated_accrual_rows_created,
      components_created = calculated_components_created,
      interest_posted_paise =
        calculated_interest_posted_paise::bigint,
      more_dates_pending = calculated_more_dates_pending,
      status = final_status,
      result_code = final_result_code,
      completed_at = statement_timestamp()
    where id = new_run_id;
  exception
    when others then
      get stacked diagnostics failure_sqlstate = returned_sqlstate;

      calculated_accounts_examined := 0;
      calculated_account_days_processed := 0;
      calculated_accrual_rows_created := 0;
      calculated_components_created := 0;
      calculated_interest_posted_paise := 0;
      calculated_more_dates_pending := true;
      calculated_first_business_date := null;
      calculated_last_business_date := null;
      final_status := 'FAILED';
      final_result_code := 'IAC_SCHEDULER_FAILURE';

      update public.interest_accrual_runs
      set
        accounts_examined = 0,
        account_days_processed = 0,
        accrual_rows_created = 0,
        components_created = 0,
        interest_posted_paise = 0,
        more_dates_pending = true,
        status = final_status,
        result_code = final_result_code,
        error_code = failure_sqlstate,
        error_message =
          'Accrual execution failed; inspect database logs using the request ID.',
        completed_at = statement_timestamp()
      where id = new_run_id;
  end;

  select run.*
  into existing_run
  from public.interest_accrual_runs as run
  where run.id = new_run_id;

  return query
  select
    existing_run.id,
    existing_run.status,
    existing_run.result_code,
    existing_run.accounts_examined,
    existing_run.account_days_processed,
    existing_run.accrual_rows_created,
    existing_run.components_created,
    existing_run.interest_posted_paise,
    existing_run.more_dates_pending;
end;
$$;

create function app_private.run_interest_accrual_cycle(
  target_requested_at timestamptz,
  target_trigger_source public.interest_accrual_trigger_source,
  target_max_catch_up_days integer
)
returns table (
  interest_accrual_run_id uuid,
  station_id uuid,
  run_status public.interest_accrual_run_status,
  result_code text,
  more_dates_pending boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  station_row record;
  station_result record;
begin
  for station_row in
    select station.id
    from public.stations as station
    join public.organizations as organization
      on organization.id = station.organization_id
    where station.is_active
      and organization.is_active
    order by station.id
  loop
    select *
    into station_result
    from app_private.run_interest_accrual_for_station(
      station_row.id,
      target_requested_at,
      target_trigger_source,
      gen_random_uuid(),
      target_max_catch_up_days
    );

    return query
    select
      station_result.interest_accrual_run_id,
      station_row.id,
      station_result.run_status,
      station_result.result_code,
      station_result.more_dates_pending;
  end loop;
end;
$$;

create function app_private.run_hourly_interest_accrual()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform *
  from app_private.run_interest_accrual_cycle(
    statement_timestamp(),
    'SCHEDULER',
    31
  );
end;
$$;

comment on function app_private.run_interest_accrual_for_station(
  uuid,
  timestamptz,
  public.interest_accrual_trigger_source,
  uuid,
  integer
) is
  'Trusted station runner. Uses station-local last completed day, serializes station invocations, catches up chronologically, and persists safe run outcomes.';
comment on function app_private.run_interest_accrual_cycle(
  timestamptz,
  public.interest_accrual_trigger_source,
  integer
) is
  'Runs active stations independently without any client-side global trigger or secret.';
comment on function app_private.run_hourly_interest_accrual() is
  'Fixed pg_cron entry point; accrues at most 31 account-days per account per hourly cycle.';

revoke all on function app_private.run_interest_accrual_for_station(
  uuid,
  timestamptz,
  public.interest_accrual_trigger_source,
  uuid,
  integer
) from public, anon, authenticated, service_role;
revoke all on function app_private.run_interest_accrual_cycle(
  timestamptz,
  public.interest_accrual_trigger_source,
  integer
) from public, anon, authenticated, service_role;
revoke all on function app_private.run_hourly_interest_accrual()
  from public, anon, authenticated, service_role;

revoke all on schema cron
  from public, anon, authenticated, service_role;
revoke all on all tables in schema cron
  from public, anon, authenticated, service_role;
revoke execute on all functions in schema cron
  from public, anon, authenticated, service_role;

select cron.schedule(
  'credit-accounting-hourly-interest-accrual',
  '7 * * * *',
  'select app_private.run_hourly_interest_accrual();'
);
