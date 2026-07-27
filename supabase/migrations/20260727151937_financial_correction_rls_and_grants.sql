alter table public.financial_correction_requests
  enable row level security;
alter table public.financial_correction_requests
  force row level security;
alter table public.fuel_credit_correction_proposals
  enable row level security;
alter table public.fuel_credit_correction_proposals
  force row level security;
alter table public.repayment_correction_proposals
  enable row level security;
alter table public.repayment_correction_proposals
  force row level security;
alter table public.financial_correction_events
  enable row level security;
alter table public.financial_correction_events
  force row level security;
alter table public.financial_reversals
  enable row level security;
alter table public.financial_reversals
  force row level security;

revoke all on table public.financial_correction_requests
  from public, anon, authenticated, service_role;
revoke all on table public.fuel_credit_correction_proposals
  from public, anon, authenticated, service_role;
revoke all on table public.repayment_correction_proposals
  from public, anon, authenticated, service_role;
revoke all on table public.financial_correction_events
  from public, anon, authenticated, service_role;
revoke all on table public.financial_reversals
  from public, anon, authenticated, service_role;

grant select on table public.financial_correction_requests
  to authenticated;
grant select on table public.fuel_credit_correction_proposals
  to authenticated;
grant select on table public.repayment_correction_proposals
  to authenticated;
grant select on table public.financial_correction_events
  to authenticated;
grant select on table public.financial_reversals
  to authenticated;

create policy financial_correction_requests_select_authorized
on public.financial_correction_requests
for select
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or app_private.is_station_manager(station_id)
);

create policy fuel_credit_correction_proposals_select_authorized
on public.fuel_credit_correction_proposals
for select
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or app_private.is_station_manager(station_id)
);

create policy repayment_correction_proposals_select_authorized
on public.repayment_correction_proposals
for select
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or app_private.is_station_manager(station_id)
);

create policy financial_correction_events_select_authorized
on public.financial_correction_events
for select
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or exists (
    select 1
    from public.financial_correction_requests as request
    where request.id = financial_correction_events.request_id
      and request.organization_id =
        financial_correction_events.organization_id
      and app_private.is_station_manager(request.station_id)
  )
);

create policy financial_reversals_select_authorized
on public.financial_reversals
for select
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or app_private.is_station_manager(station_id)
);

grant execute on function public.submit_financial_correction_request(
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
) to authenticated;
grant execute on function public.get_financial_correction_impact(uuid)
  to authenticated;
grant execute on function public.approve_and_execute_financial_correction(
  uuid,
  integer
) to authenticated;
grant execute on function public.reject_financial_correction_request(
  uuid,
  integer,
  text
) to authenticated;
grant execute on function public.cancel_financial_correction_request(
  uuid,
  integer,
  text
) to authenticated;

comment on table public.financial_correction_requests is
  'Governed maker-checker requests for append-only financial reversals.';
comment on table public.financial_correction_events is
  'Immutable state-transition evidence for financial correction requests.';
comment on table public.financial_reversals is
  'Immutable link between an original transaction, exact reversal, and optional typed replacement.';
comment on table public.fuel_credit_correction_proposals is
  'Immutable typed fuel-credit replacement proposal constrained to the original account scope.';
comment on table public.repayment_correction_proposals is
  'Immutable typed repayment replacement proposal constrained to the original account scope.';
