create function app_private.current_user_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select auth.uid();
$$;

create function app_private.is_organization_owner(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organizations as organization
    join public.organization_memberships as membership
      on membership.organization_id = organization.id
    join public.role_assignments as assignment
      on assignment.organization_id = organization.id
     and assignment.user_id = membership.user_id
     and assignment.role = 'OWNER'
     and assignment.station_id is null
    where organization.id = target_organization_id
      and organization.is_active
      and membership.user_id = (select auth.uid())
      and membership.status = 'ACTIVE'
  );
$$;

create function app_private.is_station_manager(target_station_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.stations as station
    join public.organizations as organization
      on organization.id = station.organization_id
    join public.organization_memberships as organization_membership
      on organization_membership.organization_id = organization.id
    join public.station_memberships as station_membership
      on station_membership.station_id = station.id
     and station_membership.organization_id = organization.id
     and station_membership.user_id = organization_membership.user_id
    join public.role_assignments as assignment
      on assignment.station_id = station.id
     and assignment.organization_id = organization.id
     and assignment.user_id = organization_membership.user_id
     and assignment.role = 'MANAGER'
    where station.id = target_station_id
      and station.is_active
      and organization.is_active
      and organization_membership.user_id = (select auth.uid())
      and organization_membership.status = 'ACTIVE'
      and station_membership.status = 'ACTIVE'
  );
$$;

create function app_private.is_station_attendant(target_station_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.stations as station
    join public.organizations as organization
      on organization.id = station.organization_id
    join public.organization_memberships as organization_membership
      on organization_membership.organization_id = organization.id
    join public.station_memberships as station_membership
      on station_membership.station_id = station.id
     and station_membership.organization_id = organization.id
     and station_membership.user_id = organization_membership.user_id
    join public.role_assignments as assignment
      on assignment.station_id = station.id
     and assignment.organization_id = organization.id
     and assignment.user_id = organization_membership.user_id
     and assignment.role = 'ATTENDANT'
    where station.id = target_station_id
      and station.is_active
      and organization.is_active
      and organization_membership.user_id = (select auth.uid())
      and organization_membership.status = 'ACTIVE'
      and station_membership.status = 'ACTIVE'
  );
$$;

create function app_private.is_customer(target_customer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.customers as customer
    join public.organizations as organization
      on organization.id = customer.organization_id
    join public.organization_memberships as membership
      on membership.organization_id = organization.id
     and membership.user_id = customer.auth_user_id
    join public.role_assignments as assignment
      on assignment.organization_id = organization.id
     and assignment.user_id = customer.auth_user_id
     and assignment.role = 'CUSTOMER'
     and assignment.station_id is null
    where customer.id = target_customer_id
      and customer.auth_user_id = (select auth.uid())
      and customer.status = 'ACTIVE'
      and organization.is_active
      and membership.status = 'ACTIVE'
  );
$$;

create function app_private.is_driver_linked_to_customer(target_customer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.customer_drivers as driver
    join public.driver_permissions as permission
      on permission.driver_id = driver.id
     and permission.customer_id = driver.customer_id
     and permission.organization_id = driver.organization_id
    join public.customers as customer
      on customer.id = driver.customer_id
     and customer.organization_id = driver.organization_id
    join public.organizations as organization
      on organization.id = driver.organization_id
    join public.organization_memberships as membership
      on membership.organization_id = organization.id
     and membership.user_id = driver.auth_user_id
    join public.role_assignments as assignment
      on assignment.organization_id = organization.id
     and assignment.user_id = driver.auth_user_id
     and assignment.role = 'DRIVER'
     and assignment.station_id is null
    where driver.customer_id = target_customer_id
      and driver.auth_user_id = (select auth.uid())
      and driver.status = 'ACTIVE'
      and customer.status = 'ACTIVE'
      and organization.is_active
      and membership.status = 'ACTIVE'
      and current_date >= permission.valid_from
      and (permission.expires_on is null or current_date <= permission.expires_on)
  );
$$;

create function app_private.can_access_organization(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.is_organization_owner(target_organization_id)
    or exists (
      select 1
      from public.role_assignments as assignment
      join public.organization_memberships as organization_membership
        on organization_membership.organization_id = assignment.organization_id
       and organization_membership.user_id = assignment.user_id
      left join public.station_memberships as station_membership
        on station_membership.station_id = assignment.station_id
       and station_membership.organization_id = assignment.organization_id
       and station_membership.user_id = assignment.user_id
      left join public.stations as station
        on station.id = assignment.station_id
       and station.organization_id = assignment.organization_id
      join public.organizations as organization
        on organization.id = assignment.organization_id
      where assignment.organization_id = target_organization_id
        and assignment.user_id = (select auth.uid())
        and assignment.role in ('MANAGER', 'ATTENDANT', 'CUSTOMER')
        and organization.is_active
        and organization_membership.status = 'ACTIVE'
        and (
          (
            assignment.role in ('MANAGER', 'ATTENDANT')
            and station_membership.status = 'ACTIVE'
            and station.is_active
          )
          or (
            assignment.role = 'CUSTOMER'
            and exists (
              select 1
              from public.customers as customer
              where customer.organization_id = assignment.organization_id
                and customer.auth_user_id = assignment.user_id
                and customer.status = 'ACTIVE'
            )
          )
        )
    );
$$;

create function app_private.can_access_station(target_station_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.is_station_manager(target_station_id)
    or app_private.is_station_attendant(target_station_id)
    or exists (
      select 1
      from public.stations as station
      where station.id = target_station_id
        and station.is_active
        and app_private.is_organization_owner(station.organization_id)
    )
    or exists (
      select 1
      from public.customers as customer
      where customer.home_station_id = target_station_id
        and app_private.is_customer(customer.id)
    );
$$;

create function app_private.can_read_customer(target_customer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    app_private.is_customer(target_customer_id)
    or exists (
      select 1
      from public.customers as customer
      where customer.id = target_customer_id
        and (
          app_private.is_organization_owner(customer.organization_id)
          or (
            customer.home_station_id is not null
            and app_private.is_station_manager(customer.home_station_id)
          )
        )
    );
$$;

create function app_private.can_read_driver(target_driver_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.customer_drivers as driver
    where driver.id = target_driver_id
      and (
        app_private.is_organization_owner(driver.organization_id)
        or exists (
          select 1
          from public.customers as customer
          where customer.id = driver.customer_id
            and customer.organization_id = driver.organization_id
            and customer.home_station_id is not null
            and app_private.is_station_manager(customer.home_station_id)
        )
        or app_private.is_customer(driver.customer_id)
        or (
          driver.auth_user_id = (select auth.uid())
          and driver.status = 'ACTIVE'
          and exists (
            select 1
            from public.organization_memberships as membership
            join public.role_assignments as assignment
              on assignment.organization_id = membership.organization_id
             and assignment.user_id = membership.user_id
             and assignment.role = 'DRIVER'
             and assignment.station_id is null
            join public.organizations as organization
              on organization.id = membership.organization_id
            where membership.organization_id = driver.organization_id
              and membership.user_id = driver.auth_user_id
              and membership.status = 'ACTIVE'
              and organization.is_active
          )
        )
      )
  );
$$;

create function app_private.can_read_interest_policy(
  target_organization_id uuid,
  target_customer_id uuid
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
      target_customer_id is null
      and exists (
        select 1
        from public.stations as station
        where station.organization_id = target_organization_id
          and app_private.is_station_manager(station.id)
      )
    )
    or (
      target_customer_id is not null
      and (
        app_private.can_read_customer(target_customer_id)
        or app_private.is_customer(target_customer_id)
      )
    );
$$;

create function app_private.can_read_audit_event(
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

create function app_private.set_updated_at_and_user()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
begin
  new.updated_at := now();
  if current_user_id is not null then
    new.updated_by := current_user_id;
  end if;
  return new;
end;
$$;

drop trigger app_settings_set_updated_at on public.app_settings;

create trigger app_settings_set_updated_at_and_user
before update on public.app_settings
for each row execute function app_private.set_updated_at_and_user();

create function public.get_my_driver_parent_account()
returns table (
  customer_id uuid,
  credit_account_id uuid,
  customer_display_name text,
  account_active boolean,
  credit_limit_paise bigint,
  currency_code text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    customer.id,
    account.id,
    coalesce(
      customer.display_name,
      concat_ws(' ', customer.first_name, customer.last_name)
    ),
    account.is_active,
    settings.credit_limit_paise,
    account.currency_code
  from public.customer_drivers as driver
  join public.driver_permissions as permission
    on permission.driver_id = driver.id
   and permission.customer_id = driver.customer_id
   and permission.organization_id = driver.organization_id
  join public.customers as customer
    on customer.id = driver.customer_id
   and customer.organization_id = driver.organization_id
  join public.customer_account_settings as settings
    on settings.customer_id = customer.id
   and settings.organization_id = customer.organization_id
  join public.credit_accounts as account
    on account.customer_id = customer.id
   and account.organization_id = customer.organization_id
  join public.organizations as organization
    on organization.id = customer.organization_id
  join public.organization_memberships as membership
    on membership.organization_id = organization.id
   and membership.user_id = driver.auth_user_id
  join public.role_assignments as assignment
    on assignment.organization_id = organization.id
   and assignment.user_id = driver.auth_user_id
   and assignment.role = 'DRIVER'
   and assignment.station_id is null
  where driver.auth_user_id = (select auth.uid())
    and driver.status = 'ACTIVE'
    and customer.status = 'ACTIVE'
    and account.is_active
    and organization.is_active
    and membership.status = 'ACTIVE'
    and current_date >= permission.valid_from
    and (permission.expires_on is null or current_date <= permission.expires_on);
$$;

revoke all on function app_private.current_user_id() from public, anon;
revoke all on function app_private.is_organization_owner(uuid) from public, anon;
revoke all on function app_private.is_station_manager(uuid) from public, anon;
revoke all on function app_private.is_station_attendant(uuid) from public, anon;
revoke all on function app_private.is_customer(uuid) from public, anon;
revoke all on function app_private.is_driver_linked_to_customer(uuid) from public, anon;
revoke all on function app_private.can_access_organization(uuid) from public, anon;
revoke all on function app_private.can_access_station(uuid) from public, anon;
revoke all on function app_private.can_read_customer(uuid) from public, anon;
revoke all on function app_private.can_read_driver(uuid) from public, anon;
revoke all on function app_private.can_read_interest_policy(uuid, uuid) from public, anon;
revoke all on function app_private.can_read_audit_event(uuid, uuid) from public, anon;
revoke all on function app_private.set_updated_at_and_user() from public, anon, authenticated;
revoke all on function public.get_my_driver_parent_account() from public, anon;

grant usage on schema app_private to authenticated;
grant execute on function app_private.current_user_id() to authenticated;
grant execute on function app_private.is_organization_owner(uuid) to authenticated;
grant execute on function app_private.is_station_manager(uuid) to authenticated;
grant execute on function app_private.is_station_attendant(uuid) to authenticated;
grant execute on function app_private.is_customer(uuid) to authenticated;
grant execute on function app_private.is_driver_linked_to_customer(uuid) to authenticated;
grant execute on function app_private.can_access_organization(uuid) to authenticated;
grant execute on function app_private.can_access_station(uuid) to authenticated;
grant execute on function app_private.can_read_customer(uuid) to authenticated;
grant execute on function app_private.can_read_driver(uuid) to authenticated;
grant execute on function app_private.can_read_interest_policy(uuid, uuid) to authenticated;
grant execute on function app_private.can_read_audit_event(uuid, uuid) to authenticated;
grant execute on function public.get_my_driver_parent_account() to authenticated;

grant select on table public.profiles to authenticated;
grant select on table public.organizations to authenticated;
grant select on table public.stations to authenticated;
grant select on table public.organization_memberships to authenticated;
grant select on table public.station_memberships to authenticated;
grant select on table public.role_assignments to authenticated;
grant select on table public.customers to authenticated;
grant select on table public.customer_account_settings to authenticated;
grant select on table public.credit_accounts to authenticated;
grant select on table public.customer_drivers to authenticated;
grant select on table public.driver_permissions to authenticated;
grant select on table public.qr_credentials to authenticated;
grant select on table public.interest_policies to authenticated;
grant select on table public.audit_events to authenticated;
grant select on table public.app_settings to authenticated;
grant update (display_name, phone) on table public.profiles to authenticated;
grant update (setting_value) on table public.app_settings to authenticated;

create policy profiles_select_self
on public.profiles
for select
to authenticated
using (user_id = (select auth.uid()));

create policy profiles_update_self
on public.profiles
for update
to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

create policy organizations_select_authorized
on public.organizations
for select
to authenticated
using (app_private.can_access_organization(id));

create policy stations_select_authorized
on public.stations
for select
to authenticated
using (app_private.can_access_station(id));

create policy organization_memberships_select_authorized
on public.organization_memberships
for select
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or (
    user_id = (select auth.uid())
    and status = 'ACTIVE'
  )
);

create policy station_memberships_select_authorized
on public.station_memberships
for select
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or app_private.is_station_manager(station_id)
  or (
    user_id = (select auth.uid())
    and status = 'ACTIVE'
  )
);

create policy role_assignments_select_authorized
on public.role_assignments
for select
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or (
    station_id is not null
    and role <> 'OWNER'
    and app_private.is_station_manager(station_id)
  )
  or (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.organization_memberships as membership
      where membership.organization_id = role_assignments.organization_id
        and membership.user_id = (select auth.uid())
        and membership.status = 'ACTIVE'
    )
  )
);

create policy customers_select_authorized
on public.customers
for select
to authenticated
using (app_private.can_read_customer(id));

create policy customer_account_settings_select_authorized
on public.customer_account_settings
for select
to authenticated
using (app_private.can_read_customer(customer_id));

create policy credit_accounts_select_authorized
on public.credit_accounts
for select
to authenticated
using (app_private.can_read_customer(customer_id));

create policy customer_drivers_select_authorized
on public.customer_drivers
for select
to authenticated
using (app_private.can_read_driver(id));

create policy driver_permissions_select_authorized
on public.driver_permissions
for select
to authenticated
using (app_private.can_read_driver(driver_id));

create policy qr_credentials_select_owner
on public.qr_credentials
for select
to authenticated
using (app_private.is_organization_owner(organization_id));

create policy interest_policies_select_authorized
on public.interest_policies
for select
to authenticated
using (
  app_private.can_read_interest_policy(organization_id, customer_id)
);

create policy audit_events_select_authorized
on public.audit_events
for select
to authenticated
using (
  app_private.can_read_audit_event(organization_id, station_id)
);

create policy app_settings_select_authorized
on public.app_settings
for select
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or (
    not is_protected
    and station_id is not null
    and app_private.is_station_manager(station_id)
  )
);

create policy app_settings_update_authorized
on public.app_settings
for update
to authenticated
using (
  app_private.is_organization_owner(organization_id)
  or (
    not is_protected
    and station_id is not null
    and app_private.is_station_manager(station_id)
  )
)
with check (
  app_private.is_organization_owner(organization_id)
  or (
    not is_protected
    and station_id is not null
    and app_private.is_station_manager(station_id)
  )
);
