-- Phase 2E least-privilege hardening.
--
-- The generated service key is used only against the Auth Admin API. No
-- application workflow requires service_role access to public relations or
-- RPCs, so the public service-role allowlist is intentionally empty.

revoke all privileges on table
  public.interest_accrual_components,
  public.interest_accrual_runs,
  public.interest_accruals
from authenticated;

grant select on table
  public.interest_accrual_components,
  public.interest_accrual_runs,
  public.interest_accruals
to authenticated;

-- Remove the legacy generated service-role grants from every current
-- application relation and RPC. This includes all audit_events privileges,
-- including INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES, and
-- MAINTAIN.
revoke all privileges on all tables in schema public
  from service_role;
revoke all privileges on all sequences in schema public
  from service_role;
revoke all privileges on all functions in schema public
  from service_role;

-- Future application objects are private until a reviewed migration grants
-- the exact required access. PostgreSQL's base PUBLIC function EXECUTE grant
-- is revoked alongside Supabase's Data API role defaults.
alter default privileges for role postgres in schema public
  revoke all privileges on tables
  from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all privileges on sequences
  from public, anon, authenticated, service_role;
alter default privileges for role postgres
  revoke execute on functions
  from public;
alter default privileges for role postgres in schema public
  revoke all privileges on functions
  from anon, authenticated, service_role;

-- pg_cron remains owned by the managed supabase_admin role and invoked by the
-- postgres job owner. Its extension-owned PUBLIC object ACLs cannot be
-- changed by the non-superuser migration owner, so the supported security
-- boundary is the revoked cron schema usage below.
revoke all privileges on schema cron
  from public, anon, authenticated, service_role;
