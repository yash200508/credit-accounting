-- Hosted development functional-smoke fixture only.
-- The existing fake Unauthorized User becomes the owner of a second,
-- synthetic tenant. No Auth identity or financial evidence is created here.
begin;
set local statement_timeout = '30s';
set local lock_timeout = '5s';

do $phase_2e$
declare
  unauthorized_user_id uuid;
begin
  if (select count(*) from auth.users) <> 7 then
    raise exception 'P2E_UNEXPECTED_AUTH_USER_COUNT';
  end if;

  select id
    into strict unauthorized_user_id
  from auth.users
  where email = 'unauthorized@credit-accounting.example.test'
    and raw_app_meta_data @> '{"environment":"DEVELOPMENT","fake_data":true}'::jsonb;

  if exists (
    select 1
    from public.organization_memberships
    where user_id = unauthorized_user_id
      and organization_id = 'e0000000-0000-0000-0000-000000000001'
  ) or exists (
    select 1
    from public.role_assignments
    where user_id = unauthorized_user_id
      and organization_id = 'e0000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'P2E_ISOLATION_ACTOR_IN_PRIMARY_TENANT';
  end if;
end
$phase_2e$;

insert into public.organizations (
  id, legal_name, display_name, is_active, created_by, updated_by
)
select
  'e0000000-0000-0000-0000-000000000002',
  'DEVELOPMENT ISOLATION ORGANIZATION - NOT REAL DATA',
  'DEVELOPMENT ISOLATION - FAKE DATA ONLY',
  true,
  id,
  id
from auth.users
where email = 'unauthorized@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.stations (
  id, organization_id, station_code, display_name, address, time_zone_name,
  is_active, created_by, updated_by
)
select
  'e1000000-0000-0000-0000-000000000002',
  'e0000000-0000-0000-0000-000000000002',
  'DEV-ISOLATION',
  'DEVELOPMENT ISOLATION STATION - NOT REAL',
  null,
  'Asia/Kolkata',
  true,
  id,
  id
from auth.users
where email = 'unauthorized@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.organization_memberships (
  id, organization_id, user_id, status, created_by, updated_by
)
select
  'e7000000-0000-0000-0000-000000000007',
  'e0000000-0000-0000-0000-000000000002',
  id,
  'ACTIVE',
  id,
  id
from auth.users
where email = 'unauthorized@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.role_assignments (
  id, organization_id, station_id, user_id, role, created_by
)
select
  'e6000000-0000-0000-0000-000000000007',
  'e0000000-0000-0000-0000-000000000002',
  null,
  id,
  'OWNER',
  id
from auth.users
where email = 'unauthorized@credit-accounting.example.test'
on conflict (id) do nothing;

do $phase_2e$
declare
  unauthorized_user_id uuid;
begin
  select id
    into strict unauthorized_user_id
  from auth.users
  where email = 'unauthorized@credit-accounting.example.test';

  if not exists (
    select 1
    from public.organizations
    where id = 'e0000000-0000-0000-0000-000000000002'
      and legal_name = 'DEVELOPMENT ISOLATION ORGANIZATION - NOT REAL DATA'
      and is_active
  ) or not exists (
    select 1
    from public.stations
    where id = 'e1000000-0000-0000-0000-000000000002'
      and organization_id = 'e0000000-0000-0000-0000-000000000002'
      and station_code = 'DEV-ISOLATION'
      and time_zone_name = 'Asia/Kolkata'
      and address is null
      and is_active
  ) or not exists (
    select 1
    from public.organization_memberships
    where id = 'e7000000-0000-0000-0000-000000000007'
      and organization_id = 'e0000000-0000-0000-0000-000000000002'
      and user_id = unauthorized_user_id
      and status = 'ACTIVE'
  ) or not exists (
    select 1
    from public.role_assignments
    where id = 'e6000000-0000-0000-0000-000000000007'
      and organization_id = 'e0000000-0000-0000-0000-000000000002'
      and station_id is null
      and user_id = unauthorized_user_id
      and role = 'OWNER'
  ) then
    raise exception 'P2E_ISOLATION_FIXTURE_POSTCONDITION_FAILED';
  end if;

  if exists (
    select 1
    from public.organization_memberships
    where user_id = unauthorized_user_id
      and organization_id = 'e0000000-0000-0000-0000-000000000001'
  ) or exists (
    select 1
    from public.role_assignments
    where user_id = unauthorized_user_id
      and organization_id = 'e0000000-0000-0000-0000-000000000001'
  ) then
    raise exception 'P2E_ISOLATION_ACTOR_IN_PRIMARY_TENANT';
  end if;
end
$phase_2e$;

commit;
