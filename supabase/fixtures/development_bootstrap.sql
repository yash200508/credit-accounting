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
    'owner-b@credit-accounting.example.test',
    'manager@credit-accounting.example.test',
    'attendant@credit-accounting.example.test',
    'customer@credit-accounting.example.test',
    'driver@credit-accounting.example.test',
    'unauthorized@credit-accounting.example.test'
  );
  if actual_count <> expected_count then
    raise exception 'P2E_EXPECTED_FAKE_AUTH_USERS_MISSING';
  end if;
  if (select count(*) from auth.users) <> expected_count then
    raise exception 'P2E_UNEXPECTED_AUTH_USERS_PRESENT';
  end if;
end
$phase_2e$;

insert into public.profiles (user_id, display_name, phone)
select id, fixture.display_name, fixture.phone
from (
  values
    ('owner-a@credit-accounting.example.test', 'DEVELOPMENT OWNER A - NOT REAL', null),
    ('owner-b@credit-accounting.example.test', 'DEVELOPMENT OWNER B - NOT REAL', null),
    ('manager@credit-accounting.example.test', 'DEVELOPMENT MANAGER - NOT REAL', null),
    ('attendant@credit-accounting.example.test', 'DEVELOPMENT ATTENDANT - NOT REAL', null),
    ('customer@credit-accounting.example.test', 'DEVELOPMENT CUSTOMER USER - NOT REAL', null),
    ('driver@credit-accounting.example.test', 'DEVELOPMENT DRIVER USER - NOT REAL', null),
    ('unauthorized@credit-accounting.example.test', 'DEVELOPMENT UNAUTHORIZED USER - NOT REAL', null)
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

insert into public.stations (
  id, organization_id, station_code, display_name, address, time_zone_name,
  is_active, created_by, updated_by
)
select
  'e1000000-0000-0000-0000-000000000001',
  'e0000000-0000-0000-0000-000000000001',
  'DEV-MUMBAI',
  'DEVELOPMENT MUMBAI STATION - NOT REAL',
  null,
  'Asia/Kolkata',
  true,
  id,
  id
from auth.users
where email = 'owner-a@credit-accounting.example.test'
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
    ('e7000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', 'owner-b@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001', 'manager@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000001', 'attendant@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000005', 'e0000000-0000-0000-0000-000000000001', 'customer@credit-accounting.example.test', 'owner-a@credit-accounting.example.test'),
    ('e7000000-0000-0000-0000-000000000006', 'e0000000-0000-0000-0000-000000000001', 'driver@credit-accounting.example.test', 'owner-a@credit-accounting.example.test')
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
    ('e7100000-0000-0000-0000-000000000003', 'manager@credit-accounting.example.test'),
    ('e7100000-0000-0000-0000-000000000004', 'attendant@credit-accounting.example.test')
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
    ('e6000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000001', null, 'owner-b@credit-accounting.example.test', 'OWNER', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'manager@credit-accounting.example.test', 'MANAGER', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000004', 'e0000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'attendant@credit-accounting.example.test', 'ATTENDANT', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000005', 'e0000000-0000-0000-0000-000000000001', null, 'customer@credit-accounting.example.test', 'CUSTOMER', 'owner-a@credit-accounting.example.test'),
    ('e6000000-0000-0000-0000-000000000006', 'e0000000-0000-0000-0000-000000000001', null, 'driver@credit-accounting.example.test', 'DRIVER', 'owner-a@credit-accounting.example.test')
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
  'fake-development-customer-phone',
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
where customer_user.email = 'customer@credit-accounting.example.test'
on conflict (id) do nothing;

insert into public.customer_account_settings (
  customer_id, organization_id, credit_limit_paise,
  default_annual_interest_rate, grace_days, grace_policy, due_days,
  created_by, updated_by
)
select
  'e2000000-0000-0000-0000-000000000001',
  'e0000000-0000-0000-0000-000000000001',
  1000000,
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
  'fake-development-driver-phone',
  'ACTIVE',
  owner_user.id,
  owner_user.id
from auth.users driver_user
cross join (
  select id from auth.users
  where email = 'owner-a@credit-accounting.example.test'
) owner_user
where driver_user.email = 'driver@credit-accounting.example.test'
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
  '2026-01-01',
  '2099-12-31',
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
    ('e8000000-0000-0000-0000-000000000001', null, 0.18000000)
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

do $phase_2e_verify$
declare
  unauthorized_user_id uuid;
begin
  if (select count(*) from public.profiles) <> 7
     or (select count(*) from public.organizations) <> 1
     or (select count(*) from public.stations) <> 1
     or (select count(*) from public.organization_memberships) <> 6
     or (select count(*) from public.station_memberships) <> 2
     or (select count(*) from public.role_assignments) <> 6
     or (select count(*) from public.customers) <> 1
     or (select count(*) from public.customer_account_settings) <> 1
     or (select count(*) from public.credit_accounts) <> 1
     or (select count(*) from public.customer_drivers) <> 1
     or (select count(*) from public.driver_permissions) <> 1
     or (select count(*) from public.fuel_products) <> 2
     or (select count(*) from public.interest_policies) <> 1
     or (select count(*) from public.app_settings) <> 1
     or (select count(*) from public.audit_events) <> 1
     or (select count(*) from public.qr_credentials) <> 0
  then
    raise exception 'P2E_BOOTSTRAP_APPLICATION_COUNT_MISMATCH';
  end if;

  if not exists (
    select 1
    from public.organizations
    where id = 'e0000000-0000-0000-0000-000000000001'
      and legal_name = 'DEVELOPMENT DEMO ORGANIZATION - NOT REAL DATA'
      and display_name = 'DEVELOPMENT DEMO - FAKE DATA ONLY'
      and is_active
  ) or not exists (
    select 1
    from public.stations
    where id = 'e1000000-0000-0000-0000-000000000001'
      and organization_id = 'e0000000-0000-0000-0000-000000000001'
      and station_code = 'DEV-MUMBAI'
      and display_name = 'DEVELOPMENT MUMBAI STATION - NOT REAL'
      and address is null
      and time_zone_name = 'Asia/Kolkata'
      and is_active
  ) then
    raise exception 'P2E_BOOTSTRAP_SYNTHETIC_SCOPE_MISMATCH';
  end if;

  if not exists (
    select 1
    from public.customer_account_settings
    where customer_id = 'e2000000-0000-0000-0000-000000000001'
      and credit_limit_paise = 1000000
      and default_annual_interest_rate = 0.18000000
      and grace_days = 0
      and grace_policy = 'AFTER_GRACE_ONLY'
      and due_days = 30
  ) or not exists (
    select 1
    from public.credit_accounts
    where id = 'e3000000-0000-0000-0000-000000000001'
      and customer_id = 'e2000000-0000-0000-0000-000000000001'
      and currency_code = 'INR'
      and is_active
  ) then
    raise exception 'P2E_BOOTSTRAP_CREDIT_ACCOUNT_MISMATCH';
  end if;

  if not exists (
    select 1
    from public.customer_drivers
    where id = 'e4000000-0000-0000-0000-000000000001'
      and customer_id = 'e2000000-0000-0000-0000-000000000001'
      and status = 'ACTIVE'
  ) or not exists (
    select 1
    from public.driver_permissions
    where driver_id = 'e4000000-0000-0000-0000-000000000001'
      and customer_id = 'e2000000-0000-0000-0000-000000000001'
      and transaction_limit_paise = 50000
      and daily_limit_paise = 100000
  ) then
    raise exception 'P2E_BOOTSTRAP_DRIVER_MISMATCH';
  end if;

  if (
    select array_agg(product_code order by product_code)
    from public.fuel_products
  ) is distinct from array['DIESEL', 'PETROL']::text[] then
    raise exception 'P2E_BOOTSTRAP_FUEL_PRODUCTS_MISMATCH';
  end if;

  if not exists (
    select 1
    from public.interest_policies
    where id = 'e8000000-0000-0000-0000-000000000001'
      and organization_id = 'e0000000-0000-0000-0000-000000000001'
      and customer_id is null
      and annual_rate = 0.18000000
      and grace_days = 0
      and grace_policy = 'AFTER_GRACE_ONLY'
      and is_active
      and interest_enabled
      and day_count_basis = 365
  ) then
    raise exception 'P2E_BOOTSTRAP_INTEREST_POLICY_MISMATCH';
  end if;

  select id
    into unauthorized_user_id
  from auth.users
  where email = 'unauthorized@credit-accounting.example.test';

  if unauthorized_user_id is null
     or exists (
       select 1 from public.organization_memberships
       where user_id = unauthorized_user_id
     )
     or exists (
       select 1 from public.station_memberships
       where user_id = unauthorized_user_id
     )
     or exists (
       select 1 from public.role_assignments
       where user_id = unauthorized_user_id
     )
     or exists (
       select 1 from public.customers
       where auth_user_id = unauthorized_user_id
     )
     or exists (
       select 1 from public.customer_drivers
       where auth_user_id = unauthorized_user_id
     )
  then
    raise exception 'P2E_BOOTSTRAP_UNAUTHORIZED_ACTOR_SCOPE_MISMATCH';
  end if;

  if (select count(*) from public.ledger_transactions) <> 0
     or (select count(*) from public.ledger_entries) <> 0
     or (select count(*) from public.fuel_credit_sales) <> 0
     or (select count(*) from public.customer_repayments) <> 0
     or (select count(*) from public.repayment_allocations) <> 0
     or (select count(*) from public.interest_accruals) <> 0
     or (select count(*) from public.interest_accrual_components) <> 0
     or (select count(*) from public.interest_accrual_runs) <> 0
     or (select count(*) from public.financial_correction_requests) <> 0
     or (select count(*) from public.financial_correction_events) <> 0
     or (select count(*) from public.financial_reversals) <> 0
     or (select count(*) from public.fuel_credit_correction_proposals) <> 0
     or (select count(*) from public.repayment_correction_proposals) <> 0
     or (select count(*) from public.idempotency_keys) <> 0
  then
    raise exception 'P2E_BOOTSTRAP_FINANCIAL_BASELINE_NOT_EMPTY';
  end if;
end
$phase_2e_verify$;

commit;

select 'PASS: deterministic hosted development application fixtures are present';
