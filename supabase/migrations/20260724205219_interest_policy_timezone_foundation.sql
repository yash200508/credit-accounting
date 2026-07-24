create extension if not exists btree_gist with schema extensions;

create function app_private.is_valid_iana_time_zone(
  target_time_zone_name text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from pg_catalog.pg_timezone_names() as time_zone
    where time_zone.name = target_time_zone_name
  );
$$;

create function app_private.guard_station_time_zone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.time_zone_name is null
     or btrim(new.time_zone_name) = ''
     or not app_private.is_valid_iana_time_zone(new.time_zone_name)
  then
    raise exception 'IAC_INVALID_TIMEZONE'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

alter table public.stations
  add column time_zone_name text not null default 'UTC';

create trigger stations_guard_time_zone
before insert or update of time_zone_name on public.stations
for each row execute function app_private.guard_station_time_zone();

comment on column public.stations.time_zone_name is
  'Canonical IANA time-zone name used to derive immutable transaction business dates and completed accrual days.';

alter table public.ledger_transactions
  add column business_date date;

alter table public.ledger_transactions
  disable trigger ledger_transactions_reject_update_delete;

update public.ledger_transactions as transaction
set business_date =
  (transaction.occurred_at at time zone station.time_zone_name)::date
from public.stations as station
where station.id = transaction.station_id
  and station.organization_id = transaction.organization_id
  and transaction.business_date is null;

alter table public.ledger_transactions
  enable trigger ledger_transactions_reject_update_delete;

alter table public.ledger_transactions
  alter column business_date set not null,
  alter column created_by drop not null;

alter table public.ledger_transactions
  add constraint ledger_transactions_actor_required
  check (
    created_by is not null
    or transaction_type = 'INTEREST_CHARGE'
  );

create function app_private.set_ledger_transaction_business_date()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  derived_business_date date;
begin
  select (new.occurred_at at time zone station.time_zone_name)::date
  into derived_business_date
  from public.stations as station
  where station.id = new.station_id
    and station.organization_id = new.organization_id;

  if not found then
    raise exception 'LEDGER_STATION_NOT_FOUND'
      using errcode = '23503';
  end if;

  if new.transaction_type in ('FUEL_CREDIT', 'CUSTOMER_REPAYMENT')
  then
    if new.business_date is not null
       and new.business_date <> derived_business_date
    then
      raise exception 'LEDGER_BUSINESS_DATE_MISMATCH'
        using errcode = '23514';
    end if;

    new.business_date := derived_business_date;
  elsif new.business_date is null then
    new.business_date := derived_business_date;
  end if;

  return new;
end;
$$;

create trigger ledger_transactions_set_business_date
before insert on public.ledger_transactions
for each row execute function app_private.set_ledger_transaction_business_date();

create index ledger_transactions_account_business_date_idx
  on public.ledger_transactions (
    credit_account_id,
    business_date,
    occurred_at,
    id
  );

create index ledger_transactions_station_business_date_idx
  on public.ledger_transactions (
    station_id,
    business_date,
    occurred_at,
    id
  );

comment on column public.ledger_transactions.business_date is
  'Immutable station-local business date captured at posting; interest uses this value instead of recomputing historical dates.';
comment on column public.ledger_transactions.created_by is
  'Human actor for interactive postings; null only for trusted system-created interest charges.';

alter table public.interest_policies
  add column interest_enabled boolean not null default true,
  add column day_count_basis smallint not null default 365,
  add constraint interest_policies_day_count_basis_fixed
    check (day_count_basis = 365),
  add constraint interest_policies_id_organization_unique
    unique (id, organization_id);

drop index public.interest_policies_one_active_default_per_organization;
drop index public.interest_policies_one_active_override_per_customer;

alter table public.interest_policies
  add constraint interest_policies_active_default_dates_excl
  exclude using gist (
    organization_id with =,
    daterange(
      effective_from,
      coalesce(effective_to, 'infinity'::date),
      '[)'
    ) with &&
  )
  where (is_active and customer_id is null);

alter table public.interest_policies
  add constraint interest_policies_active_customer_dates_excl
  exclude using gist (
    organization_id with =,
    customer_id with =,
    daterange(
      effective_from,
      coalesce(effective_to, 'infinity'::date),
      '[)'
    ) with &&
  )
  where (is_active and customer_id is not null);

create index interest_policies_default_effective_idx
  on public.interest_policies (
    organization_id,
    effective_from desc,
    effective_to
  )
  where is_active and customer_id is null;

create index interest_policies_customer_effective_idx
  on public.interest_policies (
    organization_id,
    customer_id,
    effective_from desc,
    effective_to
  )
  where is_active and customer_id is not null;

comment on column public.interest_policies.interest_enabled is
  'Effective-dated accrual switch. Disabled periods retain policy evidence and accrue zero.';
comment on column public.interest_policies.day_count_basis is
  'Fixed Actual/365 denominator for this product, including leap years.';

revoke all on function app_private.is_valid_iana_time_zone(text)
  from public, anon, authenticated, service_role;
revoke all on function app_private.guard_station_time_zone()
  from public, anon, authenticated, service_role;
revoke all on function app_private.set_ledger_transaction_business_date()
  from public, anon, authenticated, service_role;
