create function public.reject_financial_correction_request(
  p_request_id uuid,
  p_expected_version integer,
  p_rejection_reason text
)
returns table (
  request_id uuid,
  status public.financial_correction_status,
  version integer,
  correlation_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  request_row public.financial_correction_requests%rowtype;
  normalized_reason text := btrim(p_rejection_reason);
begin
  if actor_id is null then
    raise exception 'COR_AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  if not app_private.is_safe_correction_text(normalized_reason, 10, 500) then
    raise exception 'COR_INVALID_REASON' using errcode = 'P0001';
  end if;

  select request.*
  into request_row
  from public.financial_correction_requests as request
  where request.id = p_request_id
  for update;

  if not found then
    raise exception 'COR_INVALID_REQUEST' using errcode = 'P0001';
  end if;

  if not app_private.is_organization_owner(request_row.organization_id) then
    raise exception 'COR_FORBIDDEN' using errcode = 'P0001';
  end if;

  if request_row.status <> 'PENDING_REVIEW' then
    raise exception 'COR_REQUEST_NOT_PENDING' using errcode = 'P0001';
  end if;

  if p_expected_version is null
     or request_row.version <> p_expected_version
  then
    raise exception 'COR_VERSION_CONFLICT' using errcode = 'P0001';
  end if;

  update public.financial_correction_requests as target
  set
    status = 'REJECTED',
    version = target.version + 1,
    decided_by = actor_id,
    decision_reason = normalized_reason,
    decided_at = statement_timestamp(),
    updated_at = statement_timestamp()
  where target.id = request_row.id;

  insert into public.financial_correction_events (
    request_id,
    organization_id,
    event_type,
    previous_status,
    new_status,
    actor_user_id,
    actor_role,
    reason,
    correlation_id
  )
  values (
    request_row.id,
    request_row.organization_id,
    'REJECTED',
    'PENDING_REVIEW',
    'REJECTED',
    actor_id,
    'OWNER',
    normalized_reason,
    request_row.correlation_id
  );

  insert into public.audit_events (
    actor_user_id,
    actor_role,
    organization_id,
    station_id,
    action_category,
    action,
    entity_type,
    entity_id,
    reason,
    before_state,
    after_state,
    request_id,
    source_application
  )
  values (
    actor_id,
    'OWNER',
    request_row.organization_id,
    request_row.station_id,
    'FINANCIAL',
    'financial_correction.rejected',
    'financial_correction_request',
    request_row.id,
    normalized_reason,
    jsonb_build_object(
      'status', request_row.status,
      'version', request_row.version
    ),
    jsonb_build_object(
      'status', 'REJECTED',
      'version', request_row.version + 1,
      'correlation_id', request_row.correlation_id
    ),
    request_row.correlation_id,
    'financial-correction-rpc'
  );

  return query select
    request_row.id,
    'REJECTED'::public.financial_correction_status,
    request_row.version + 1,
    request_row.correlation_id;
end;
$$;

create function public.cancel_financial_correction_request(
  p_request_id uuid,
  p_expected_version integer,
  p_cancellation_reason text
)
returns table (
  request_id uuid,
  status public.financial_correction_status,
  version integer,
  correlation_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  actor_role public.app_role;
  request_row public.financial_correction_requests%rowtype;
  normalized_reason text := btrim(p_cancellation_reason);
begin
  if actor_id is null then
    raise exception 'COR_AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  if not app_private.is_safe_correction_text(normalized_reason, 10, 500) then
    raise exception 'COR_INVALID_REASON' using errcode = 'P0001';
  end if;

  select request.*
  into request_row
  from public.financial_correction_requests as request
  where request.id = p_request_id
  for update;

  if not found then
    raise exception 'COR_INVALID_REQUEST' using errcode = 'P0001';
  end if;

  if request_row.requester_id = actor_id then
    actor_role := request_row.requester_role;
  elsif app_private.is_organization_owner(request_row.organization_id) then
    actor_role := 'OWNER';
  else
    raise exception 'COR_FORBIDDEN' using errcode = 'P0001';
  end if;

  if request_row.status <> 'PENDING_REVIEW' then
    raise exception 'COR_REQUEST_NOT_PENDING' using errcode = 'P0001';
  end if;

  if p_expected_version is null
     or request_row.version <> p_expected_version
  then
    raise exception 'COR_VERSION_CONFLICT' using errcode = 'P0001';
  end if;

  update public.financial_correction_requests as target
  set
    status = 'CANCELLED',
    version = target.version + 1,
    decided_by = actor_id,
    decision_reason = normalized_reason,
    decided_at = statement_timestamp(),
    updated_at = statement_timestamp()
  where target.id = request_row.id;

  insert into public.financial_correction_events (
    request_id,
    organization_id,
    event_type,
    previous_status,
    new_status,
    actor_user_id,
    actor_role,
    reason,
    correlation_id
  )
  values (
    request_row.id,
    request_row.organization_id,
    'CANCELLED',
    'PENDING_REVIEW',
    'CANCELLED',
    actor_id,
    actor_role,
    normalized_reason,
    request_row.correlation_id
  );

  insert into public.audit_events (
    actor_user_id,
    actor_role,
    organization_id,
    station_id,
    action_category,
    action,
    entity_type,
    entity_id,
    reason,
    before_state,
    after_state,
    request_id,
    source_application
  )
  values (
    actor_id,
    actor_role,
    request_row.organization_id,
    request_row.station_id,
    'FINANCIAL',
    'financial_correction.cancelled',
    'financial_correction_request',
    request_row.id,
    normalized_reason,
    jsonb_build_object(
      'status', request_row.status,
      'version', request_row.version
    ),
    jsonb_build_object(
      'status', 'CANCELLED',
      'version', request_row.version + 1,
      'correlation_id', request_row.correlation_id
    ),
    request_row.correlation_id,
    'financial-correction-rpc'
  );

  return query select
    request_row.id,
    'CANCELLED'::public.financial_correction_status,
    request_row.version + 1,
    request_row.correlation_id;
end;
$$;

comment on function public.reject_financial_correction_request(
  uuid,
  integer,
  text
) is
  'Lets an active organization owner terminally reject a pending correction.';

comment on function public.cancel_financial_correction_request(
  uuid,
  integer,
  text
) is
  'Lets the original requester or an active organization owner terminally cancel a pending correction.';

revoke all on function public.reject_financial_correction_request(
  uuid,
  integer,
  text
) from public, anon, authenticated, service_role;
revoke all on function public.cancel_financial_correction_request(
  uuid,
  integer,
  text
) from public, anon, authenticated, service_role;
