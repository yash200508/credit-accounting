create function app_private.can_read_customer_repayment(
  target_repayment_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.customer_repayments as repayment
    where repayment.id = target_repayment_id
      and app_private.can_read_financial_station(
        repayment.organization_id,
        repayment.station_id
      )
  );
$$;

revoke all on function app_private.can_read_customer_repayment(uuid)
  from public, anon, authenticated, service_role;
grant execute on function app_private.can_read_customer_repayment(uuid)
  to authenticated;

grant select on table public.customer_repayments to authenticated;
grant select on table public.repayment_allocations to authenticated;

revoke all on table public.customer_repayments from service_role;
revoke all on table public.repayment_allocations from service_role;

create policy customer_repayments_select_authorized
on public.customer_repayments
for select
to authenticated
using (
  app_private.can_read_financial_station(organization_id, station_id)
);

create policy repayment_allocations_select_authorized
on public.repayment_allocations
for select
to authenticated
using (
  app_private.can_read_customer_repayment(repayment_id)
);

revoke all on function public.get_credit_account_obligations(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_credit_account_obligations(uuid)
  to authenticated;

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
grant execute on function public.post_customer_repayment(
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
) to authenticated;

alter default privileges for role postgres in schema public
  revoke execute on functions from public;
alter default privileges for role postgres in schema app_private
  revoke execute on functions from public;
