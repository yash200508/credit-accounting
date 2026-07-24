create schema if not exists app_private;

revoke all on schema app_private from public, anon, authenticated;

create type public.app_role as enum (
  'OWNER',
  'MANAGER',
  'ATTENDANT',
  'CUSTOMER',
  'DRIVER'
);

create type public.membership_status as enum (
  'INVITED',
  'ACTIVE',
  'SUSPENDED',
  'REVOKED'
);

create type public.customer_status as enum (
  'ACTIVE',
  'INACTIVE'
);

create type public.driver_status as enum (
  'ACTIVE',
  'REVOKED'
);

create type public.qr_credential_status as enum (
  'ACTIVE',
  'EXPIRED',
  'REVOKED',
  'ROTATED'
);

create type public.audit_action_category as enum (
  'AUTHORIZATION',
  'MEMBERSHIP',
  'CUSTOMER',
  'DRIVER',
  'CREDENTIAL',
  'SETTINGS',
  'SECURITY',
  'SYSTEM'
);

create type public.interest_grace_policy_type as enum (
  'AFTER_GRACE_ONLY',
  'RETROACTIVE_AFTER_GRACE'
);

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_display_name_not_blank
    check (btrim(display_name) <> ''),
  constraint profiles_phone_not_blank
    check (phone is null or btrim(phone) <> '')
);

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  legal_name text not null,
  display_name text not null,
  is_active boolean not null default true,
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organizations_legal_name_not_blank
    check (btrim(legal_name) <> ''),
  constraint organizations_display_name_not_blank
    check (btrim(display_name) <> ''),
  constraint organizations_id_tenant_unique unique (id)
);

create table public.stations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_code text not null,
  display_name text not null,
  address text,
  is_active boolean not null default true,
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint stations_code_not_blank
    check (btrim(station_code) <> ''),
  constraint stations_display_name_not_blank
    check (btrim(display_name) <> ''),
  constraint stations_address_not_blank
    check (address is null or btrim(address) <> ''),
  constraint stations_organization_code_unique
    unique (organization_id, station_code),
  constraint stations_id_organization_unique
    unique (id, organization_id)
);

create table public.organization_memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  user_id uuid not null references auth.users (id) on delete cascade,
  status public.membership_status not null default 'INVITED',
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organization_memberships_organization_user_unique
    unique (organization_id, user_id)
);

create table public.station_memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  station_id uuid not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  status public.membership_status not null default 'INVITED',
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint station_memberships_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint station_memberships_station_user_unique
    unique (station_id, user_id)
);

create table public.role_assignments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_id uuid,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.app_role not null,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  constraint role_assignments_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint role_assignments_scope_check
    check (
      (role = 'OWNER' and station_id is null)
      or (role in ('MANAGER', 'ATTENDANT') and station_id is not null)
      or (role in ('CUSTOMER', 'DRIVER') and station_id is null)
    ),
  constraint role_assignments_scope_user_role_unique
    unique nulls not distinct (organization_id, station_id, user_id, role)
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  home_station_id uuid,
  auth_user_id uuid unique references auth.users (id) on delete set null,
  first_name text not null,
  last_name text not null,
  display_name text,
  phone text not null,
  alternate_phone text,
  address text,
  status public.customer_status not null default 'ACTIVE',
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customers_home_station_tenant_fk
    foreign key (home_station_id, organization_id)
    references public.stations (id, organization_id),
  constraint customers_first_name_not_blank
    check (btrim(first_name) <> ''),
  constraint customers_last_name_not_blank
    check (btrim(last_name) <> ''),
  constraint customers_display_name_not_blank
    check (display_name is null or btrim(display_name) <> ''),
  constraint customers_phone_not_blank
    check (btrim(phone) <> ''),
  constraint customers_alternate_phone_not_blank
    check (alternate_phone is null or btrim(alternate_phone) <> ''),
  constraint customers_address_not_blank
    check (address is null or btrim(address) <> ''),
  constraint customers_organization_phone_unique
    unique (organization_id, phone),
  constraint customers_id_organization_unique
    unique (id, organization_id)
);

create table public.customer_account_settings (
  customer_id uuid primary key,
  organization_id uuid not null,
  credit_limit_paise bigint not null default 0,
  default_annual_interest_rate numeric(9, 8) not null default 0.18000000,
  grace_days integer not null default 0,
  grace_policy public.interest_grace_policy_type not null default 'AFTER_GRACE_ONLY',
  due_days integer not null default 30,
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_account_settings_customer_tenant_fk
    foreign key (customer_id, organization_id)
    references public.customers (id, organization_id),
  constraint customer_account_settings_credit_limit_non_negative
    check (credit_limit_paise >= 0),
  constraint customer_account_settings_rate_range
    check (
      default_annual_interest_rate >= 0
      and default_annual_interest_rate <= 1
    ),
  constraint customer_account_settings_grace_days_range
    check (grace_days between 0 and 3650),
  constraint customer_account_settings_due_days_range
    check (due_days between 0 and 3650),
  constraint customer_account_settings_customer_organization_unique
    unique (customer_id, organization_id)
);

create table public.credit_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  customer_id uuid not null,
  home_station_id uuid,
  currency_code text not null default 'INR',
  is_active boolean not null default true,
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint credit_accounts_customer_tenant_fk
    foreign key (customer_id, organization_id)
    references public.customers (id, organization_id),
  constraint credit_accounts_home_station_tenant_fk
    foreign key (home_station_id, organization_id)
    references public.stations (id, organization_id),
  constraint credit_accounts_currency_code_check
    check (currency_code = 'INR'),
  constraint credit_accounts_customer_unique
    unique (customer_id),
  constraint credit_accounts_id_organization_unique
    unique (id, organization_id)
);

create table public.customer_drivers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  customer_id uuid not null,
  auth_user_id uuid unique references auth.users (id) on delete set null,
  first_name text not null,
  last_name text not null,
  phone text,
  status public.driver_status not null default 'ACTIVE',
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_drivers_customer_tenant_fk
    foreign key (customer_id, organization_id)
    references public.customers (id, organization_id),
  constraint customer_drivers_first_name_not_blank
    check (btrim(first_name) <> ''),
  constraint customer_drivers_last_name_not_blank
    check (btrim(last_name) <> ''),
  constraint customer_drivers_phone_not_blank
    check (phone is null or btrim(phone) <> ''),
  constraint customer_drivers_id_customer_organization_unique
    unique (id, customer_id, organization_id),
  constraint customer_drivers_id_organization_unique
    unique (id, organization_id)
);

create table public.driver_permissions (
  driver_id uuid primary key,
  customer_id uuid not null,
  organization_id uuid not null,
  transaction_limit_paise bigint,
  daily_limit_paise bigint,
  valid_from date not null default current_date,
  expires_on date,
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint driver_permissions_driver_customer_tenant_fk
    foreign key (driver_id, customer_id, organization_id)
    references public.customer_drivers (id, customer_id, organization_id),
  constraint driver_permissions_transaction_limit_non_negative
    check (transaction_limit_paise is null or transaction_limit_paise >= 0),
  constraint driver_permissions_daily_limit_non_negative
    check (daily_limit_paise is null or daily_limit_paise >= 0),
  constraint driver_permissions_valid_dates
    check (expires_on is null or expires_on >= valid_from)
);

create table public.qr_credentials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  customer_id uuid,
  driver_id uuid,
  token_hash text not null unique,
  status public.qr_credential_status not null default 'ACTIVE',
  issued_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  rotated_at timestamptz,
  last_used_at timestamptz,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  constraint qr_credentials_customer_tenant_fk
    foreign key (customer_id, organization_id)
    references public.customers (id, organization_id),
  constraint qr_credentials_driver_tenant_fk
    foreign key (driver_id, organization_id)
    references public.customer_drivers (id, organization_id),
  constraint qr_credentials_exactly_one_subject
    check ((customer_id is not null)::integer + (driver_id is not null)::integer = 1),
  constraint qr_credentials_hash_format
    check (token_hash ~ '^[0-9a-f]{64}$'),
  constraint qr_credentials_expiration_after_issue
    check (expires_at is null or expires_at > issued_at),
  constraint qr_credentials_revocation_state
    check (
      (status = 'REVOKED' and revoked_at is not null)
      or (status <> 'REVOKED' and revoked_at is null)
    ),
  constraint qr_credentials_rotation_state
    check (
      (status = 'ROTATED' and rotated_at is not null)
      or (status <> 'ROTATED' and rotated_at is null)
    ),
  constraint qr_credentials_last_used_after_issue
    check (last_used_at is null or last_used_at >= issued_at)
);

create table public.interest_policies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  customer_id uuid,
  annual_rate numeric(9, 8) not null default 0.18000000,
  grace_days integer not null default 0,
  grace_policy public.interest_grace_policy_type not null default 'AFTER_GRACE_ONLY',
  effective_from date not null,
  effective_to date,
  is_active boolean not null default true,
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint interest_policies_customer_tenant_fk
    foreign key (customer_id, organization_id)
    references public.customers (id, organization_id),
  constraint interest_policies_rate_range
    check (annual_rate >= 0 and annual_rate <= 1),
  constraint interest_policies_grace_days_range
    check (grace_days between 0 and 3650),
  constraint interest_policies_effective_dates
    check (effective_to is null or effective_to > effective_from)
);

create unique index interest_policies_one_active_default_per_organization
  on public.interest_policies (organization_id)
  where customer_id is null and is_active;

create unique index interest_policies_one_active_override_per_customer
  on public.interest_policies (organization_id, customer_id)
  where customer_id is not null and is_active;

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references auth.users (id),
  actor_role public.app_role,
  organization_id uuid not null references public.organizations (id),
  station_id uuid,
  action_category public.audit_action_category not null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  reason text,
  before_state jsonb,
  after_state jsonb,
  request_id uuid not null,
  source_application text not null,
  occurred_at timestamptz not null default now(),
  constraint audit_events_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint audit_events_action_not_blank
    check (btrim(action) <> ''),
  constraint audit_events_entity_type_not_blank
    check (btrim(entity_type) <> ''),
  constraint audit_events_reason_not_blank
    check (reason is null or btrim(reason) <> ''),
  constraint audit_events_source_application_not_blank
    check (btrim(source_application) <> ''),
  constraint audit_events_before_state_object
    check (before_state is null or jsonb_typeof(before_state) = 'object'),
  constraint audit_events_after_state_object
    check (after_state is null or jsonb_typeof(after_state) = 'object')
);

create table public.app_settings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id),
  station_id uuid,
  setting_key text not null,
  setting_value jsonb not null,
  is_protected boolean not null default false,
  created_by uuid not null references auth.users (id),
  updated_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_settings_station_tenant_fk
    foreign key (station_id, organization_id)
    references public.stations (id, organization_id),
  constraint app_settings_key_format
    check (setting_key ~ '^[a-z][a-z0-9_.-]{0,99}$'),
  constraint app_settings_scope_key_unique
    unique nulls not distinct (organization_id, station_id, setting_key)
);

create index stations_organization_id_idx
  on public.stations (organization_id);
create index organization_memberships_user_status_idx
  on public.organization_memberships (user_id, status, organization_id);
create index station_memberships_user_status_idx
  on public.station_memberships (user_id, status, station_id);
create index station_memberships_organization_id_idx
  on public.station_memberships (organization_id);
create index role_assignments_user_role_organization_idx
  on public.role_assignments (user_id, role, organization_id);
create index role_assignments_station_user_role_idx
  on public.role_assignments (station_id, user_id, role)
  where station_id is not null;
create index customers_home_station_id_idx
  on public.customers (home_station_id)
  where home_station_id is not null;
create index customers_auth_user_status_idx
  on public.customers (auth_user_id, status)
  where auth_user_id is not null;
create index customer_account_settings_organization_id_idx
  on public.customer_account_settings (organization_id);
create index credit_accounts_organization_id_idx
  on public.credit_accounts (organization_id);
create index credit_accounts_home_station_id_idx
  on public.credit_accounts (home_station_id)
  where home_station_id is not null;
create index customer_drivers_customer_id_idx
  on public.customer_drivers (customer_id);
create index customer_drivers_auth_user_status_idx
  on public.customer_drivers (auth_user_id, status)
  where auth_user_id is not null;
create index driver_permissions_customer_organization_idx
  on public.driver_permissions (customer_id, organization_id);
create index qr_credentials_organization_status_idx
  on public.qr_credentials (organization_id, status);
create index qr_credentials_customer_id_idx
  on public.qr_credentials (customer_id)
  where customer_id is not null;
create index qr_credentials_driver_id_idx
  on public.qr_credentials (driver_id)
  where driver_id is not null;
create index interest_policies_customer_id_idx
  on public.interest_policies (customer_id)
  where customer_id is not null;
create index audit_events_organization_occurred_at_idx
  on public.audit_events (organization_id, occurred_at desc);
create index audit_events_station_occurred_at_idx
  on public.audit_events (station_id, occurred_at desc)
  where station_id is not null;
create index audit_events_actor_user_id_idx
  on public.audit_events (actor_user_id)
  where actor_user_id is not null;
create index audit_events_request_id_idx
  on public.audit_events (request_id);
create index app_settings_station_id_idx
  on public.app_settings (station_id)
  where station_id is not null;

create function app_private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create function app_private.reject_audit_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'audit events are append-only'
    using errcode = '42501';
end;
$$;

revoke all on function app_private.set_updated_at() from public, anon, authenticated;
revoke all on function app_private.reject_audit_mutation() from public, anon, authenticated;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function app_private.set_updated_at();

create trigger organizations_set_updated_at
before update on public.organizations
for each row execute function app_private.set_updated_at();

create trigger stations_set_updated_at
before update on public.stations
for each row execute function app_private.set_updated_at();

create trigger organization_memberships_set_updated_at
before update on public.organization_memberships
for each row execute function app_private.set_updated_at();

create trigger station_memberships_set_updated_at
before update on public.station_memberships
for each row execute function app_private.set_updated_at();

create trigger customers_set_updated_at
before update on public.customers
for each row execute function app_private.set_updated_at();

create trigger customer_account_settings_set_updated_at
before update on public.customer_account_settings
for each row execute function app_private.set_updated_at();

create trigger credit_accounts_set_updated_at
before update on public.credit_accounts
for each row execute function app_private.set_updated_at();

create trigger customer_drivers_set_updated_at
before update on public.customer_drivers
for each row execute function app_private.set_updated_at();

create trigger driver_permissions_set_updated_at
before update on public.driver_permissions
for each row execute function app_private.set_updated_at();

create trigger interest_policies_set_updated_at
before update on public.interest_policies
for each row execute function app_private.set_updated_at();

create trigger app_settings_set_updated_at
before update on public.app_settings
for each row execute function app_private.set_updated_at();

create trigger audit_events_reject_update_delete
before update or delete on public.audit_events
for each row execute function app_private.reject_audit_mutation();

alter table public.profiles enable row level security;
alter table public.profiles force row level security;
alter table public.organizations enable row level security;
alter table public.organizations force row level security;
alter table public.stations enable row level security;
alter table public.stations force row level security;
alter table public.organization_memberships enable row level security;
alter table public.organization_memberships force row level security;
alter table public.station_memberships enable row level security;
alter table public.station_memberships force row level security;
alter table public.role_assignments enable row level security;
alter table public.role_assignments force row level security;
alter table public.customers enable row level security;
alter table public.customers force row level security;
alter table public.customer_account_settings enable row level security;
alter table public.customer_account_settings force row level security;
alter table public.credit_accounts enable row level security;
alter table public.credit_accounts force row level security;
alter table public.customer_drivers enable row level security;
alter table public.customer_drivers force row level security;
alter table public.driver_permissions enable row level security;
alter table public.driver_permissions force row level security;
alter table public.qr_credentials enable row level security;
alter table public.qr_credentials force row level security;
alter table public.interest_policies enable row level security;
alter table public.interest_policies force row level security;
alter table public.audit_events enable row level security;
alter table public.audit_events force row level security;
alter table public.app_settings enable row level security;
alter table public.app_settings force row level security;

revoke all on all tables in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
