\set ON_ERROR_STOP on
\pset pager off

-- Recent failed interest runs. Intentionally omits request payloads and PII.
select
  id,
  station_id,
  requested_at,
  completed_at,
  result_code
from public.interest_accrual_runs
where status = 'FAILED'
order by requested_at desc
limit 50;

-- Catch-up work still remaining.
select
  station_id,
  max(requested_at) as last_requested_at,
  bool_or(more_dates_pending) as more_dates_pending
from public.interest_accrual_runs
group by station_id
having bool_or(more_dates_pending)
order by station_id;

-- Pending correction queue without explanations or proposal payloads.
select
  id,
  organization_id,
  station_id,
  action,
  status,
  version,
  submitted_at
from public.financial_correction_requests
where status = 'PENDING_REVIEW'
order by submitted_at;

-- Current blockers and waiters. Query text is deliberately omitted.
select
  blocked.pid as blocked_pid,
  blocker.pid as blocker_pid,
  blocked.wait_event_type,
  blocked.wait_event,
  now() - blocked.query_start as blocked_for,
  now() - blocker.query_start as blocker_for
from pg_stat_activity blocked
join pg_locks blocked_lock
  on blocked_lock.pid = blocked.pid
 and not blocked_lock.granted
join pg_locks blocker_lock
  on blocker_lock.locktype = blocked_lock.locktype
 and blocker_lock.database is not distinct from blocked_lock.database
 and blocker_lock.relation is not distinct from blocked_lock.relation
 and blocker_lock.page is not distinct from blocked_lock.page
 and blocker_lock.tuple is not distinct from blocked_lock.tuple
 and blocker_lock.virtualxid is not distinct from blocked_lock.virtualxid
 and blocker_lock.transactionid is not distinct from blocked_lock.transactionid
 and blocker_lock.classid is not distinct from blocked_lock.classid
 and blocker_lock.objid is not distinct from blocked_lock.objid
 and blocker_lock.objsubid is not distinct from blocked_lock.objsubid
 and blocker_lock.granted
join pg_stat_activity blocker on blocker.pid = blocker_lock.pid
where blocked.datname = current_database()
order by blocked.query_start;

-- Committed migration history.
select version, name
from supabase_migrations.schema_migrations
order by version;

-- Scheduler registration without displaying the SQL command.
select
  jobid,
  jobname,
  schedule,
  active,
  nodename,
  database
from cron.job
where jobname = 'credit-accounting-hourly-interest-accrual';

-- Recent pg_cron execution status.
select
  jobid,
  runid,
  status,
  start_time,
  end_time
from cron.job_run_details
where jobid in (
  select jobid
  from cron.job
  where jobname = 'credit-accounting-hourly-interest-accrual'
)
order by start_time desc
limit 50;

-- Recent immutable audit actions. JSON state, reason, and actor identity omitted.
select
  occurred_at,
  action_category,
  action,
  entity_type,
  organization_id,
  station_id,
  source_application
from public.audit_events
order by occurred_at desc
limit 100;

-- Database size and application-table growth.
select pg_size_pretty(pg_database_size(current_database())) as database_size;

select
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size
from pg_stat_user_tables
where schemaname in ('public', 'app_private')
order by pg_total_relation_size(relid) desc, schemaname, relname;

-- Slow-query aggregates, when pg_stat_statements is available. SQL text is
-- replaced by a one-way fingerprint so literals and credentials cannot leak.
select
  queryid,
  md5(query) as query_fingerprint,
  calls,
  round(total_exec_time::numeric, 2) as total_exec_ms,
  round(mean_exec_time::numeric, 2) as mean_exec_ms,
  rows
from extensions.pg_stat_statements
where userid <> 0
order by total_exec_time desc
limit 25;
