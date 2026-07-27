\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

-- Hosted development only. Auth users must already exist through the official
-- Auth Admin API. This file contains no password, token, or real-world data.
begin;
set local statement_timeout = '30s';
set local lock_timeout = '5s';

do $phase_2e$
declare
  expected_count constant integer := 7;
  actual_count integer;
begin
  select count(*)
    into actual_count
  from auth.users
  where email in (
    'owner-a@credit-accounting.example.test',
    'owner-checker@credit-accounting.example.test',
    'manager-a@credit-accounting.example.test',
    'attendant-a@credit-accounting.example.test',
    'customer-a@credit-accounting.example.test',
    'driver-a@credit-accounting.example.test',
    'isolation-owner@credit-accounting.example.test'
  );
  if actual_count <> expected_count then
    raise exception 'P2E_EXPECTED_FAKE_AUTH_USERS_MISSING';
  end if;
end
$phase_2e$;

insert into public.profiles (user_id, display_name, phone)
select id, fixture.display_name, fixture.phone
from (
  values
    ('owner-a@credit-accounting.example.test', 'Development Owner A', '+15550100101'),
    ('owner-checker@credit-accounting.example.test', 'Development Owner Checker', '+15550100102'),
    ('manager-a@credit-accounting.example.test', 'Development Manager A', '+15550100103'),
    ('attendant-a@credit-accounting.example.test', 'Development Attendant A', '+15550100104'),
    ('customer-a@credit-accounting.example.test', 'Development Customer A', '+15550100105'),
    ('driver-a@credit-accounting.example.test', 'Development Driver A', '+15550100106'),
    ('isolation-owner@credit-accounting.example.test', 'Development Isolation Owner', '+15550100107')
) as fixture(email, display_name, phone)
join auth.users using (email)
on conflict (user_id) do nothing;

insert into public.organizations (
  id, legal_name, display_name, is_active, created_by, updated_by
)
select
  'e0000000-0000-0000-0000-000000000001',
  'DEVELOPMENT DEMO ORGANIZATION - NOT REAL DATA',
  'DEVELOPMENT DEMO - FAKE DATA ONLY',
  true,
  id,
  id
from auth.users
where email = 'owner-a@credit-accounting.example.test'
on conflict (id) do nothing;

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
where email = 'isolation-owner@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.stations (
  id, organization_id, station_code, display_name, address, time_zone_name,
  is_active, created_by, updated_by
)
select
  'e1000000-0000-0000-0000-000000000001',
  'e0000000-0000-0000-0000-000000000001',
  'DEV-DEMO',
  'DEVELOPMENT DEMO STATION - NOT REAL',
  null,
  'Asia/Kolkata',
  true,
  id,
  id
from auth.users
where email = 'owner-a@credit-accounting.example.test'
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
where email = 'isolation-owner@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.organization_memberships (
  id, organization_id, user_id, status, created_by, updated_by
)
select
  fixture.id::uuid,
  fixture.organization_id::uuid,
  member.id,
  'ACTIVE',
  creator.id,
  creator.id
from (
  values
    ('e7000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', 'owner-a@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 'owner-checker@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001', 'manager-a@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000001', 'attendant-a@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000005', 'e0000000-0000-0000-0000-000000000001', 'customer-a@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000006', 'e0000000-0000-0000-0000-000000000001', 'driver-a@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000007', 'e0000000-0000-0000-0000-000000000002', 'isolation-owner@credit-accounting.example.test', 'isolation-owner@credit-accounting.example.test')
) as fixture(id, organization_id, member_email, creator_email)
join auth.users member on member.email = fixture.member_email
join auth.users creator on creator.email = fixture.creator_email
on conflict (id) do nothing;

insert into public.station_memberships (
  id, organization_id, station_id, user_id, status, created_by, updated_by
)
select
  fixture.id::uuid,
  'e0000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  member.id,
  'ACTIVE',
  owner_user.id,
  owner_user.id
from (
  values
    ('e7100000-0000-0000-0000-000000000003', 'manager-a@credit-accounting.example.test'),
    ('e7100000-0000-0000-0000-000000000004', 'attendant-a@credit-accounting.example.test')
) as fixture(id, member_email)
join auth.users member on member.email = fixture.member_email
cross join (
  select id
  from auth.users
  where email = 'owner-a@credit-accounting.example.test'
) owner_user
on conflict (id) do nothing;

insert into public.role_assignments (
  id, organization_id, station_id, user_id, role, created_by
)
select
  fixture.id::uuid,
  fixture.organization_id::uuid,
  fixture.station_id::uuid,
  member.id,
  fixture.role::public.app_role,
  creator.id
from (
  values
    ('e6000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000001', null, 'owner-a@credit-accounting.example.test', 'OWNER', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', null, 'owner-checker@credit-accounting.example.test', 'OWNER', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'manager-a@credit-accounting.example.test', 'MANAGER', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'attendant-a@credit-accounting.example.test', 'ATTENDANT', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000005', 'e0000000-0000-0000-0000-000000000001', null, 'customer-a@credit-accounting.example.test', 'CUSTOMER', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000006', 'e0000000-0000-0000-0000-000000000001', null, 'driver-a@credit-accounting.example.test', 'DRIVER', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000007', 'e0000000-0000-0000-0000-000000000002', null, 'isolation-owner@credit-accounting.example.test', 'OWNER', 'isolation-owner@credit-accounting.example.test')
) as fixture(id, organization_id, station_id, member_email, role, creator_email)
join auth.users member on member.email = fixture.member_email
join auth.users creator on creator.email = fixture.creator_email
on conflict (id) do nothing;

insert into public.customers (
  id, organization_id, home_station_id, auth_user_id, first_name, last_name,
  display_name, phone, alternate_phone, address, status, created_by, updated_by
)
select
  'e2000000-0000-0000-0000-000000000001',
  'e0000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  customer_user.id,
  'Development',
  'Customer',
  'DEVELOPMENT CUSTOMER - NOT REAL',
  '+15550100201',
  null,
  null,
  'ACTIVE',
  owner_user.id,
  owner_user.id
from auth.users customer_user
cross join (
  select id from auth.users
  where email = 'owner-a@credit-accounting.example.test'
) owner_user
where customer_user.email = 'customer-a@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.customer_account_settings (
  customer_id, organization_id, credit_limit_paise,
  default_annual_interest_rate, grace_days, grace_policy, due_days,
  created_by, updated_by
)
select
  'e2000000-0000-0000-0000-000000000001',
  'e0000000-0000-0000-0000-000000000001',
  200000,
  0.18000000,
  0,
  'AFTER_GRACE_ONLY',
  30,
  id,
  id
from auth.users
where email = 'owner-a@credit-accounting.example.test'
on conflict (customer_id) do nothing;

insert into public.credit_accounts (
  id, organization_id, customer_id, home_station_id, currency_code,
  is_active, created_by, updated_by
)
select
  'e3000000-0000-0000-0000-000000000001',
  'e0000000-0000-0000-0000-000000000001',
  'e2000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  'INR',
  true,
  id,
  id
from auth.users
where email = 'owner-a@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.customer_drivers (
  id, organization_id, customer_id, auth_user_id, first_name, last_name,
  phone, status, created_by, updated_by
)
select
  'e4000000-0000-0000-0000-000000000001',
  'e0000000-0000-0000-0000-000000000001',
  'e2000000-0000-0000-0000-000000000001',
  driver_user.id,
  'Development',
  'Driver',
  '+15550100301',
  'ACTIVE',
  owner_user.id,
  owner_user.id
from auth.users driver_user
cross join (
  select id from auth.users
  where email = 'owner-a@credit-accounting.example.test'
) owner_user
where driver_user.email = 'driver-a@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.driver_permissions (
  driver_id, customer_id, organization_id, transaction_limit_paise,
  daily_limit_paise, valid_from, expires_on, created_by, updated_by
)
select
  'e4000000-0000-0000-0000-000000000001',
  'e2000000-0000-0000-0000-000000000001',
  'e0000000-0000-0000-0000-000000000001',
  50000,
  100000,
  current_date,
  current_date + 3650,
  id,
  id
from auth.users
where email = 'owner-a@credit-accounting.example.test'
on conflict (driver_id) do nothing;

insert into public.fuel_products (
  id, organization_id, station_id, product_code, display_name, is_active,
  currency_code, created_by, updated_by
)
select
  fixture.id::uuid,
  'e0000000-0000-0000-0000-000000000001',
  fixture.station_id::uuid,
  fixture.product_code,
  fixture.display_name,
  true,
  'INR',
  owner_user.id,
  owner_user.id
from (
  values
    ('ef100000-0000-0000-0000-000000000001', null, 'PETROL', 'DEVELOPMENT PETROL - NOT REAL'),
    ('ef100000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000001', 'DIESEL', 'DEVELOPMENT DIESEL - NOT REAL')
) as fixture(id, station_id, product_code, display_name)
cross join (
  select id from auth.users
  where email = 'owner-a@credit-accounting.example.test'
) owner_user
on conflict (id) do nothing;

insert into public.interest_policies (
  id, organization_id, customer_id, annual_rate, grace_days, grace_policy,
  effective_from, effective_to, is_active, interest_enabled, day_count_basis,
  created_by, updated_by
)
select
  fixture.id::uuid,
  'e0000000-0000-0000-0000-000000000001',
  fixture.customer_id::uuid,
  fixture.annual_rate::numeric,
  0,
  'AFTER_GRACE_ONLY',
  '2026-01-01',
  null,
  true,
  true,
  365,
  owner_user.id,
  owner_user.id
from (
  values
    ('e8000000-0000-0000-0000-000000000001', null, 0.18000000),
    ('e8000000-0000-0000-0000-000000000002', 'e2000000-0000-0000-0000-000000000001', 0.15000000)
) as fixture(id, customer_id, annual_rate)
cross join (
  select id from auth.users
  where email = 'owner-a@credit-accounting.example.test'
) owner_user
on conflict (id) do nothing;

insert into public.app_settings (
  id, organization_id, station_id, setting_key, setting_value, is_protected,
  created_by, updated_by
)
select
  'ea000000-0000-0000-0000-000000000001',
  'e0000000-0000-0000-0000-000000000001',
  null,
  'environment.data_classification',
  '"DEVELOPMENT - FAKE DATA ONLY"'::jsonb,
  true,
  id,
  id
from auth.users
where email = 'owner-a@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.audit_events (
  id, actor_user_id, actor_role, organization_id, station_id,
  action_category, action, entity_type, entity_id, reason,
  before_state, after_state, request_id, source_application
)
select
  'e9000000-0000-0000-0000-000000000001',
  id,
  'OWNER',
  'e0000000-0000-0000-0000-000000000001',
  'e1000000-0000-0000-0000-000000000001',
  'SYSTEM',
  'development.bootstrap.created',
  'development_fixture',
  null,
  'Deterministic hosted development bootstrap',
  null,
  '{"environment":"DEVELOPMENT","fake_data":true}'::jsonb,
  'e9000000-0000-0000-0000-000000000002',
  'phase-2e-bootstrap'
from auth.users
where email = 'owner-a@credit-accounting.example.test'
on conflict (id) do nothing;

commit;

select 'PASS: deterministic hosted development application fixtures are present';
