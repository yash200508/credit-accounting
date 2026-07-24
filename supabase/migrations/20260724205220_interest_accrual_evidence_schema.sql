create type public.interest_accrual_trigger_source as enum (
  'SCHEDULER',
  'CATCH_UP',
  'TEST'
);

create type public.interest_accrual_run_status as enum (
  'STARTED',
  'COMPLETED',
  'COMPLETED_WITH_REMAINING',
  'FAILED'
);

create type public.interest_accrual_component_kind as enum (
  'DAILY',
  'RETROACTIVE_CATCH_UP'
);

create table public.interest_accrual_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_id uuid not null,
  trigger_source public.interest_accrual_trigger_source not null,
  request_id uuid not null,
  requested_at timestamptz not null,
  station_time_zone_name text not null,
  station_local_date date not null,
  latest_completed_business_date date not null,
  first_business_date date,
  last_business_date date,
  max_catch_up_days integer not null,
  accounts_examined integer not null default 0,
  account_days_processed integer not null default 0,
  accrual_rows_created integer not null default 0,
  components_created integer not null default 0,
  interest_posted_paise bigint not null default 0,
  more_dates_pending boolean not null default false,
  status public.interest_accrual_run_status not null default 'STARTED',
  result_code text,
  error_code text,
  error_message text,
  started_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  constraint interest_accrual_runs_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint interest_accrual_runs_request_unique
    unique (organization_id, station_id, request_id),
  constraint interest_accrual_runs_id_organization_unique
    unique (id, organization_id),
  constraint interest_accrual_runs_time_zone_not_blank
    check (btrim(station_time_zone_name) <> ''),
  constraint interest_accrual_runs_catch_up_range
    check (max_catch_up_days between 1 and 3660),
  constraint interest_accrual_runs_counts_nonnegative
    check (
      accounts_examined >= 0
      and account_days_processed >= 0
      and accrual_rows_created >= 0
      and components_created >= 0
      and interest_posted_paise >= 0
    ),
  constraint interest_accrual_runs_business_date_range
    check (
      (first_business_date is null and last_business_date is null)
      or (
        first_business_date is not null
        and last_business_date is not null
        and last_business_date >= first_business_date
        and last_business_date <= latest_completed_business_date
      )
    ),
  constraint interest_accrual_runs_completion_state
    check (
      (
        status = 'STARTED'
        and completed_at is null
        and result_code is null
        and error_code is null
        and error_message is null
      )
      or (
        status in ('COMPLETED', 'COMPLETED_WITH_REMAINING')
        and completed_at is not null
        and result_code is not null
        and error_code is null
        and error_message is null
      )
      or (
        status = 'FAILED'
        and completed_at is not null
        and result_code is not null
        and error_code is not null
        and error_message is not null
      )
    ),
  constraint interest_accrual_runs_result_code_not_blank
    check (result_code is null or btrim(result_code) <> ''),
  constraint interest_accrual_runs_error_code_not_blank
    check (error_code is null or btrim(error_code) <> ''),
  constraint interest_accrual_runs_error_message_not_blank
    check (error_message is null or btrim(error_message) <> '')
);

create table public.interest_accruals (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null,
  organization_id uuid not null,
  station_id uuid not null,
  credit_account_id uuid not null,
  customer_id uuid not null,
  business_date date not null,
  active_policy_id uuid not null,
  annual_rate numeric(9, 8) not null,
  grace_days integer not null,
  grace_policy public.interest_grace_policy_type not null,
  interest_enabled boolean not null,
  day_count_basis smallint not null,
  eligible_principal_paise bigint not null,
  raw_interest_paise numeric(38, 18) not null,
  opening_fractional_carry_paise numeric(38, 18) not null,
  posted_interest_paise bigint not null,
  closing_fractional_carry_paise numeric(38, 18) not null,
  cumulative_raw_interest_paise numeric(38, 18) not null,
  cumulative_posted_interest_paise bigint not null,
  component_count integer not null,
  daily_component_count integer not null,
  retroactive_component_count integer not null,
  ledger_transaction_id uuid,
  calculation_version smallint not null default 1,
  currency_code text not null default 'INR',
  created_at timestamptz not null default statement_timestamp(),
  constraint interest_accruals_run_tenant_fk
    foreign key (run_id, organization_id)
    references public.interest_accrual_runs (id, organization_id),
  constraint interest_accruals_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint interest_accruals_account_customer_tenant_fk
    foreign key (credit_account_id, customer_id, organization_id)
    references public.credit_accounts (id, customer_id, organization_id),
  constraint interest_accruals_policy_tenant_fk
    foreign key (active_policy_id, organization_id)
    references public.interest_policies (id, organization_id),
  constraint interest_accruals_ledger_transaction_tenant_fk
    foreign key (ledger_transaction_id, organization_id)
    references public.ledger_transactions (id, organization_id),
  constraint interest_accruals_id_organization_unique
    unique (id, organization_id),
  constraint interest_accruals_account_date_version_unique
    unique (credit_account_id, business_date, calculation_version),
  constraint interest_accruals_amounts_nonnegative
    check (
      eligible_principal_paise >= 0
      and raw_interest_paise >= 0
      and posted_interest_paise >= 0
      and cumulative_raw_interest_paise >= 0
      and cumulative_posted_interest_paise >= 0
    ),
  constraint interest_accruals_policy_snapshot_valid
    check (
      annual_rate between 0 and 1
      and grace_days between 0 and 3650
      and day_count_basis = 365
    ),
  constraint interest_accruals_component_counts_valid
    check (
      component_count >= 0
      and daily_component_count >= 0
      and retroactive_component_count >= 0
      and component_count =
        daily_component_count + retroactive_component_count
    ),
  constraint interest_accruals_carry_equation
    check (
      closing_fractional_carry_paise =
        opening_fractional_carry_paise
        + raw_interest_paise
        - posted_interest_paise::numeric
      and closing_fractional_carry_paise >= -0.5
      and closing_fractional_carry_paise < 0.5
    ),
  constraint interest_accruals_cumulative_equation
    check (
      cumulative_raw_interest_paise
        - cumulative_posted_interest_paise::numeric
        = closing_fractional_carry_paise
    ),
  constraint interest_accruals_ledger_posting_state
    check (
      (posted_interest_paise = 0 and ledger_transaction_id is null)
      or (posted_interest_paise > 0 and ledger_transaction_id is not null)
    ),
  constraint interest_accruals_calculation_version
    check (calculation_version = 1),
  constraint interest_accruals_currency_code
    check (currency_code = 'INR')
);

create table public.interest_accrual_components (
  id uuid primary key default gen_random_uuid(),
  interest_accrual_id uuid not null,
  organization_id uuid not null,
  station_id uuid not null,
  credit_account_id uuid not null,
  customer_id uuid not null,
  source_transaction_id uuid not null,
  source_business_date date not null,
  eligibility_business_date date not null,
  interest_business_date date not null,
  accrual_business_date date not null,
  component_kind public.interest_accrual_component_kind not null,
  source_remaining_principal_paise bigint not null,
  raw_interest_paise numeric(38, 18) not null,
  source_policy_id uuid not null,
  rate_policy_id uuid not null,
  annual_rate numeric(9, 8) not null,
  grace_days integer not null,
  grace_policy public.interest_grace_policy_type not null,
  interest_enabled boolean not null,
  day_count_basis smallint not null,
  calculation_version smallint not null default 1,
  created_at timestamptz not null default statement_timestamp(),
  constraint interest_accrual_components_accrual_tenant_fk
    foreign key (interest_accrual_id, organization_id)
    references public.interest_accruals (id, organization_id),
  constraint interest_accrual_components_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint interest_accrual_components_account_customer_tenant_fk
    foreign key (credit_account_id, customer_id, organization_id)
    references public.credit_accounts (id, customer_id, organization_id),
  constraint interest_accrual_components_source_transaction_tenant_fk
    foreign key (source_transaction_id, organization_id)
    references public.ledger_transactions (id, organization_id),
  constraint interest_accrual_components_source_policy_tenant_fk
    foreign key (source_policy_id, organization_id)
    references public.interest_policies (id, organization_id),
  constraint interest_accrual_components_rate_policy_tenant_fk
    foreign key (rate_policy_id, organization_id)
    references public.interest_policies (id, organization_id),
  constraint interest_accrual_components_identity_unique
    unique (
      credit_account_id,
      source_transaction_id,
      interest_business_date,
      calculation_version
    ),
  constraint interest_accrual_components_amounts_valid
    check (
      source_remaining_principal_paise > 0
      and raw_interest_paise >= 0
      and annual_rate between 0 and 1
      and grace_days between 0 and 3650
      and day_count_basis = 365
    ),
  constraint interest_accrual_components_dates_valid
    check (
      eligibility_business_date =
        source_business_date + grace_days
      and interest_business_date >= source_business_date
      and interest_business_date <= accrual_business_date
      and (
        (
          component_kind = 'DAILY'
          and interest_business_date = accrual_business_date
          and interest_business_date >= eligibility_business_date
        )
        or (
          component_kind = 'RETROACTIVE_CATCH_UP'
          and grace_policy = 'RETROACTIVE_AFTER_GRACE'
          and accrual_business_date = eligibility_business_date
          and interest_business_date < eligibility_business_date
        )
      )
    ),
  constraint interest_accrual_components_calculation_version
    check (calculation_version = 1)
);

create index interest_accrual_runs_station_requested_idx
  on public.interest_accrual_runs (
    station_id,
    requested_at desc
  );
create index interest_accrual_runs_status_idx
  on public.interest_accrual_runs (
    status,
    requested_at
  )
  where status in ('STARTED', 'FAILED');

create index interest_accruals_station_business_date_idx
  on public.interest_accruals (
    station_id,
    business_date desc,
    credit_account_id
  );
create index interest_accruals_customer_business_date_idx
  on public.interest_accruals (
    customer_id,
    business_date desc
  );
create index interest_accruals_run_idx
  on public.interest_accruals (run_id);
create index interest_accruals_active_policy_idx
  on public.interest_accruals (active_policy_id);
create index interest_accruals_ledger_transaction_idx
  on public.interest_accruals (ledger_transaction_id)
  where ledger_transaction_id is not null;

create index interest_accrual_components_accrual_idx
  on public.interest_accrual_components (interest_accrual_id);
create index interest_accrual_components_station_idx
  on public.interest_accrual_components (station_id);
create index interest_accrual_components_source_transaction_idx
  on public.interest_accrual_components (source_transaction_id);
create index interest_accrual_components_account_interest_date_idx
  on public.interest_accrual_components (
    credit_account_id,
    interest_business_date,
    source_transaction_id
  );
create index interest_accrual_components_rate_policy_idx
  on public.interest_accrual_components (rate_policy_id);
create index interest_accrual_components_source_policy_idx
  on public.interest_accrual_components (source_policy_id);

create function app_private.reject_interest_evidence_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'interest accrual evidence is append-only'
    using errcode = '42501';
end;
$$;

create function app_private.guard_interest_accrual_run_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'interest accrual runs cannot be deleted'
      using errcode = '42501';
  end if;

  if old.status = 'STARTED'
     and new.status in (
       'COMPLETED',
       'COMPLETED_WITH_REMAINING',
       'FAILED'
     )
     and new.id is not distinct from old.id
     and new.organization_id is not distinct from old.organization_id
     and new.station_id is not distinct from old.station_id
     and new.trigger_source is not distinct from old.trigger_source
     and new.request_id is not distinct from old.request_id
     and new.requested_at is not distinct from old.requested_at
     and new.station_time_zone_name
       is not distinct from old.station_time_zone_name
     and new.station_local_date is not distinct from old.station_local_date
     and new.latest_completed_business_date
       is not distinct from old.latest_completed_business_date
     and new.max_catch_up_days is not distinct from old.max_catch_up_days
     and new.started_at is not distinct from old.started_at
     and new.created_at is not distinct from old.created_at
  then
    return new;
  end if;

  raise exception 'interest accrual runs are immutable after finalization'
    using errcode = '42501';
end;
$$;

create trigger interest_accrual_runs_guard_update_delete
before update or delete on public.interest_accrual_runs
for each row execute function
  app_private.guard_interest_accrual_run_mutation();

create trigger interest_accruals_reject_update_delete
before update or delete on public.interest_accruals
for each row execute function
  app_private.reject_interest_evidence_mutation();

create trigger interest_accrual_components_reject_update_delete
before update or delete on public.interest_accrual_components
for each row execute function
  app_private.reject_interest_evidence_mutation();

alter table public.interest_accrual_runs enable row level security;
alter table public.interest_accrual_runs force row level security;
alter table public.interest_accruals enable row level security;
alter table public.interest_accruals force row level security;
alter table public.interest_accrual_components enable row level security;
alter table public.interest_accrual_components force row level security;

comment on table public.interest_accrual_runs is
  'One append-only operational record per trusted station accrual invocation; only STARTED-to-final fields may be finalized once.';
comment on table public.interest_accruals is
  'Immutable account/day result, including zero-post days and exact fractional-paise carry.';
comment on table public.interest_accrual_components is
  'Immutable FIFO principal-lot and policy evidence for every raw daily or retroactive interest component.';

revoke all on function app_private.reject_interest_evidence_mutation()
  from public, anon, authenticated, service_role;
revoke all on function
  app_private.guard_interest_accrual_run_mutation()
  from public, anon, authenticated, service_role;
