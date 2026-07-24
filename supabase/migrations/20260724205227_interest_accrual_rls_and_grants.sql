grant select on table public.interest_accrual_runs
  to authenticated;
grant select on table public.interest_accruals
  to authenticated;
grant select on table public.interest_accrual_components
  to authenticated;

revoke all on table public.interest_accrual_runs
  from public, anon, service_role;
revoke all on table public.interest_accruals
  from public, anon, service_role;
revoke all on table public.interest_accrual_components
  from public, anon, service_role;

create policy interest_accrual_runs_select_financial_leadership
on public.interest_accrual_runs
for select
to authenticated
using (
  (select app_private.can_read_financial_station(
    organization_id,
    station_id
  ))
);

create policy interest_accruals_select_financial_leadership
on public.interest_accruals
for select
to authenticated
using (
  (select app_private.can_read_financial_station(
    organization_id,
    station_id
  ))
);

create policy interest_accrual_components_select_financial_leadership
on public.interest_accrual_components
for select
to authenticated
using (
  (select app_private.can_read_financial_station(
    organization_id,
    station_id
  ))
);

revoke all on function
  app_private.resolve_effective_interest_policy(uuid, uuid, date)
  from public, anon, authenticated, service_role;
revoke all on function app_private.principal_lots_as_of(uuid, date)
  from public, anon, authenticated, service_role;
revoke all on function
  app_private.calculate_interest_components(uuid, date)
  from public, anon, authenticated, service_role;
revoke all on function
  app_private.post_interest_for_account_date(uuid, uuid, date)
  from public, anon, authenticated, service_role;
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

alter default privileges for role postgres in schema public
  revoke execute on functions from public;
alter default privileges for role postgres in schema app_private
  revoke execute on functions from public;
