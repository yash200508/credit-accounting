create function app_private.can_read_fuel_product(
  target_organization_id uuid,
  target_station_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.is_organization_owner(target_organization_id)
    or (
      target_station_id is not null
      and (
        app_private.is_station_manager(target_station_id)
        or app_private.is_station_attendant(target_station_id)
      )
    )
    or (
      target_station_id is null
      and exists (
        select 1
        from public.stations as station
        where station.organization_id = target_organization_id
          and station.is_active
          and (
            app_private.is_station_manager(station.id)
            or app_private.is_station_attendant(station.id)
          )
      )
    );
$$;

create function app_private.can_read_financial_station(
  target_organization_id uuid,
  target_station_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.is_organization_owner(target_organization_id)
    or (
      target_station_id is not null
      and app_private.is_station_manager(target_station_id)
    );
$$;

create function app_private.can_read_ledger_transaction(
  target_transaction_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.ledger_transactions as transaction
    where transaction.id = target_transaction_id
      and app_private.can_read_financial_station(
        transaction.organization_id,
        transaction.station_id
      )
  );
$$;

revoke all on function app_private.can_read_fuel_product(uuid, uuid)
  from public, anon;
revoke all on function app_private.can_read_financial_station(uuid, uuid)
  from public, anon;
revoke all on function app_private.can_read_ledger_transaction(uuid)
  from public, anon;

grant execute on function app_private.can_read_fuel_product(uuid, uuid)
  to authenticated;
grant execute on function app_private.can_read_financial_station(uuid, uuid)
  to authenticated;
grant execute on function app_private.can_read_ledger_transaction(uuid)
  to authenticated;

grant select on table public.fuel_products to authenticated;
grant select on table public.ledger_transactions to authenticated;
grant select on table public.ledger_entries to authenticated;
grant select on table public.fuel_credit_sales to authenticated;
grant select on table public.idempotency_keys to authenticated;

revoke all on table public.fuel_products from service_role;
revoke all on table public.ledger_transactions from service_role;
revoke all on table public.ledger_entries from service_role;
revoke all on table public.fuel_credit_sales from service_role;
revoke all on table public.idempotency_keys from service_role;

create policy fuel_products_select_authorized
on public.fuel_products
for select
to authenticated
using (
  app_private.can_read_fuel_product(organization_id, station_id)
);

create policy ledger_transactions_select_authorized
on public.ledger_transactions
for select
to authenticated
using (
  app_private.can_read_financial_station(organization_id, station_id)
);

create policy ledger_entries_select_authorized
on public.ledger_entries
for select
to authenticated
using (
  app_private.can_read_ledger_transaction(transaction_id)
);

create policy fuel_credit_sales_select_authorized
on public.fuel_credit_sales
for select
to authenticated
using (
  app_private.can_read_financial_station(organization_id, station_id)
);

create policy idempotency_keys_select_authorized
on public.idempotency_keys
for select
to authenticated
using (
  app_private.can_read_financial_station(organization_id, station_id)
);

alter default privileges for role postgres in schema public
  revoke execute on functions from public;
alter default privileges for role postgres in schema app_private
  revoke execute on functions from public;
