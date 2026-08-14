#!/usr/bin/env python3
"""Run four bounded concurrency races against the approved hosted project.

The harness is deliberately fail-closed and development-only. It obtains a
short-lived Supabase CLI login role from an access token already present in the
process environment, opens independent TLS Supavisor session-mode connections,
and never logs credentials or connection strings.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Callable

try:
    import psycopg
    from psycopg.rows import dict_row
except ImportError as exc:  # pragma: no cover - environment precondition
    raise SystemExit("FAIL: psycopg 3 is required for hosted concurrency") from exc


ROOT = Path(__file__).resolve().parents[3]
AUTH_STATE = ROOT / ".local-state" / "phase-2e-auth.json"
LINK_FILE = ROOT / "supabase" / ".temp" / "project-ref"
POOLER_FILE = ROOT / "supabase" / ".temp" / "pooler-url"
CATALOG_VERIFIER = ROOT / "supabase" / "validation" / "phase_2e_catalog_security.sql"
EVIDENCE_DIR = ROOT / ".local-state"

EXPECTED_PROJECT_REF = "pjjbjeqkktxnphavolvf"
EXPECTED_PROJECT_NAME = "credit-accounting-development"
EXPECTED_REGION = "ap-south-1"
EXPECTED_ORGANIZATION_ID = "e0000000-0000-0000-0000-000000000001"
EXPECTED_STATION_ID = "e1000000-0000-0000-0000-000000000001"
EXPECTED_PRODUCT_ID = "ef100000-0000-0000-0000-000000000001"
EXPECTED_POOLER_HOST = "aws-1-ap-south-1.pooler.supabase.com"
EXPECTED_MIGRATION_COUNT = 25
EXPECTED_DATA_API_SCHEMAS = {"public", "graphql_public"}
API_ROOT = "https://api.supabase.com/v1"

STATEMENT_TIMEOUT_MS = 30_000
LOCK_TIMEOUT_MS = 10_000
IDLE_TRANSACTION_TIMEOUT_MS = 30_000
RACE_JOIN_TIMEOUT_SECONDS = 45
WINNER_HOLD_SECONDS = 2.0
SECOND_RACER_DELAY_SECONDS = 0.15

ERROR_CODE = re.compile(r"\b(?:FCP|RPP|IAC|COR)_[A-Z0-9_]+\b")
INFRASTRUCTURE_SQLSTATE_PREFIXES = ("08",)
INFRASTRUCTURE_SQLSTATES = {"57P01", "57P02", "57P03", "58030"}


class HarnessFailure(RuntimeError):
    """A precondition or invariant failed."""


class CriticalInvariantFailure(HarnessFailure):
    """A high-confidence financial concurrency blocker was found."""


class InfrastructureFailure(HarnessFailure):
    """A network, TLS, pooler, or session failure occurred."""


@dataclass
class RacerResult:
    racer: str
    logical_operation: str
    actor: str
    session_started_utc: str | None = None
    transaction_started_utc: str | None = None
    classification: str = "not_started"
    sqlstate: str | None = None
    error_code: str | None = None
    committed: bool = False
    rolled_back: bool = False
    commit_state: str = "not_started"
    duration_ms: int | None = None
    operation_duration_ms: int | None = None
    lock_observation: str | None = None
    payload: dict[str, Any] = field(default_factory=dict)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def json_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(key): json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [json_value(item) for item in value]
    if isinstance(value, (uuid.UUID, date, datetime, Decimal)):
        return str(value)
    return value


def api_json(
    token: str,
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
) -> Any:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"{API_ROOT}{path}",
        data=body,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "credit-accounting-phase-2e-hosted-concurrency",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise InfrastructureFailure(
            f"Supabase Management API returned HTTP {exc.code}"
        ) from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise InfrastructureFailure("Supabase Management API request failed") from exc


def required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise HarnessFailure(f"required environment value is missing: {name}")
    return value


def validate_target_environment() -> tuple[str, str, int]:
    if os.environ.get("PHASE_2E_REMOTE_DATABASE") != "1":
        raise HarnessFailure("PHASE_2E_REMOTE_DATABASE=1 is required")
    if required_environment("SUPABASE_PROJECT_ID") != EXPECTED_PROJECT_REF:
        raise HarnessFailure("selected project reference is not approved")
    if required_environment("SUPABASE_EXPECTED_REGION") != EXPECTED_REGION:
        raise HarnessFailure("selected region is not approved")
    if LINK_FILE.read_text(encoding="utf-8").strip() != EXPECTED_PROJECT_REF:
        raise HarnessFailure("local Supabase link does not match the approved project")

    parsed = urllib.parse.urlsplit(POOLER_FILE.read_text(encoding="utf-8").strip())
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise HarnessFailure("linked pooler URL is not PostgreSQL")
    if parsed.password:
        raise HarnessFailure("linked pooler metadata unexpectedly contains a password")
    if parsed.hostname != EXPECTED_POOLER_HOST or parsed.port != 5432:
        raise HarnessFailure("linked pooler is not Mumbai Supavisor session mode")
    if parsed.username != f"postgres.{EXPECTED_PROJECT_REF}":
        raise HarnessFailure("linked pooler user does not bind the approved project")
    if parsed.path != "/postgres":
        raise HarnessFailure("linked pooler database is not postgres")
    return parsed.hostname, "postgres", parsed.port


def load_fake_identities() -> dict[str, str]:
    try:
        state = json.loads(AUTH_STATE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HarnessFailure("ignored fake-Auth state is unavailable") from exc
    identities: dict[str, str] = {}
    expected_labels = {
        "owner-a",
        "owner-b",
        "manager",
        "attendant",
        "customer",
        "driver",
        "unauthorized",
    }
    for user in state.get("users", []):
        if not isinstance(user, dict):
            continue
        label = str(user.get("label", ""))
        email = str(user.get("email", ""))
        user_id = str(user.get("user_id", ""))
        if label in expected_labels:
            if not email.endswith("@credit-accounting.example.test"):
                raise HarnessFailure("fake identity has an unexpected email domain")
            try:
                uuid.UUID(user_id)
            except ValueError as exc:
                raise HarnessFailure("fake identity has an invalid user id") from exc
            identities[label] = user_id
    if set(identities) != expected_labels:
        raise HarnessFailure("the exact seven fake identities are not available")
    return identities


def temporary_login(token: str, *, read_only: bool) -> tuple[str, str, int]:
    result = api_json(
        token,
        "POST",
        f"/projects/{EXPECTED_PROJECT_REF}/cli/login-role",
        {"read_only": read_only},
    )
    if not isinstance(result, dict):
        raise InfrastructureFailure("temporary login response was unexpected")
    role = str(result.get("role", "")).strip()
    password = str(result.get("password", ""))
    try:
        ttl_seconds = int(result.get("ttl_seconds", 0))
    except (TypeError, ValueError) as exc:
        raise InfrastructureFailure("temporary login TTL was invalid") from exc
    if not role or not password or ttl_seconds < 180:
        raise InfrastructureFailure("temporary login role was incomplete or too short-lived")
    return role, password, ttl_seconds


class ConnectionFactory:
    def __init__(
        self,
        *,
        host: str,
        database: str,
        port: int,
        role: str,
        password: str,
    ) -> None:
        self.host = host
        self.database = database
        self.port = port
        self.user = f"{role}.{EXPECTED_PROJECT_REF}"
        self.password = password
        if not self.user.endswith(f".{EXPECTED_PROJECT_REF}"):
            raise HarnessFailure("temporary login user is not project-bound")

    def connect(self, application_name: str) -> psycopg.Connection[Any]:
        try:
            connection = psycopg.connect(
                host=self.host,
                port=self.port,
                dbname=self.database,
                user=self.user,
                password=self.password,
                sslmode="require",
                connect_timeout=15,
                application_name=application_name,
                autocommit=True,
                row_factory=dict_row,
            )
        except psycopg.Error as exc:
            raise InfrastructureFailure("hosted PostgreSQL connection failed") from exc
        if not bool(connection.pgconn.ssl_in_use):
            connection.close()
            raise InfrastructureFailure("hosted PostgreSQL connection did not use TLS")
        try:
            with connection.cursor() as cur:
                cur.execute("set role postgres")
        except psycopg.Error as exc:
            connection.close()
            raise InfrastructureFailure(
                "temporary login role could not assume postgres"
            ) from exc
        return connection


def begin(cur: psycopg.Cursor[Any], *, read_only: bool = False) -> None:
    cur.execute("begin read only" if read_only else "begin")
    cur.execute(f"set local statement_timeout = '{STATEMENT_TIMEOUT_MS}ms'")
    cur.execute(f"set local lock_timeout = '{LOCK_TIMEOUT_MS}ms'")
    cur.execute(
        f"set local idle_in_transaction_session_timeout = "
        f"'{IDLE_TRANSACTION_TIMEOUT_MS}ms'"
    )


def set_authenticated(cur: psycopg.Cursor[Any], actor_id: str) -> None:
    cur.execute("set local role authenticated")
    cur.execute(
        "select set_config('request.jwt.claim.sub', %s, true), "
        "set_config('request.jwt.claim.role', 'authenticated', true)",
        (actor_id,),
    )


def query_one(
    factory: ConnectionFactory,
    sql: str,
    parameters: tuple[Any, ...] = (),
    *,
    application: str,
) -> dict[str, Any]:
    with factory.connect(application) as connection:
        with connection.cursor() as cur:
            begin(cur, read_only=True)
            cur.execute(sql, parameters)
            row = cur.fetchone()
            cur.execute("rollback")
    if row is None:
        raise HarnessFailure(f"{application} returned no row")
    return dict(row)


def execute_transaction(
    factory: ConnectionFactory,
    callback: Callable[[psycopg.Cursor[Any]], Any],
    *,
    application: str,
) -> Any:
    with factory.connect(application) as connection:
        with connection.cursor() as cur:
            begin(cur)
            try:
                result = callback(cur)
                cur.execute("commit")
                return result
            except BaseException:
                try:
                    cur.execute("rollback")
                except psycopg.Error:
                    pass
                raise


def local_migration_versions() -> list[str]:
    versions: list[str] = []
    for path in sorted((ROOT / "supabase" / "migrations").glob("*.sql")):
        match = re.fullmatch(r"(\d{14})_[a-z0-9_]+\.sql", path.name)
        if not match:
            raise HarnessFailure(f"unexpected migration filename: {path.name}")
        versions.append(match.group(1))
    return versions


def management_preflight(token: str) -> dict[str, Any]:
    project = api_json(token, "GET", f"/projects/{EXPECTED_PROJECT_REF}")
    if not isinstance(project, dict):
        raise HarnessFailure("project metadata response was unexpected")
    if project.get("id") != EXPECTED_PROJECT_REF and project.get("ref") != EXPECTED_PROJECT_REF:
        raise HarnessFailure("Management API returned a different project")
    if project.get("name") != EXPECTED_PROJECT_NAME:
        raise HarnessFailure("project is not the approved development project")
    if project.get("region") != EXPECTED_REGION:
        raise HarnessFailure("project is not in the approved Mumbai region")
    if project.get("status") not in {"ACTIVE", "ACTIVE_HEALTHY"}:
        raise HarnessFailure("approved development project is not healthy")

    postgrest = api_json(token, "GET", f"/projects/{EXPECTED_PROJECT_REF}/postgrest")
    if not isinstance(postgrest, dict):
        raise HarnessFailure("Data API configuration response was unexpected")
    raw_schemas = (
        postgrest.get("db_schema")
        or postgrest.get("db_schemas")
        or postgrest.get("schemas")
        or ""
    )
    if isinstance(raw_schemas, str):
        schemas = {item.strip() for item in raw_schemas.split(",") if item.strip()}
    else:
        schemas = {str(item).strip() for item in raw_schemas if str(item).strip()}
    if schemas != EXPECTED_DATA_API_SCHEMAS:
        raise HarnessFailure("Data API exposed schemas changed unexpectedly")
    return {
        "project": EXPECTED_PROJECT_NAME,
        "project_ref": EXPECTED_PROJECT_REF,
        "region": EXPECTED_REGION,
        "status": str(project.get("status")),
        "data_api_schemas": sorted(schemas),
        "app_private_exposed": "app_private" in schemas,
        "cron_exposed": "cron" in schemas,
    }


def database_preflight(
    factory: ConnectionFactory,
    identities: dict[str, str],
    *,
    phase: str,
) -> dict[str, Any]:
    expected_users = sorted(identities.values())
    local_versions = local_migration_versions()
    if len(local_versions) != EXPECTED_MIGRATION_COUNT:
        raise HarnessFailure("local migration count is not exactly 25")

    with factory.connect(f"phase-2e-{phase}-catalog") as connection:
        with connection.cursor() as cur:
            begin(cur, read_only=True)
            cur.execute(
                "select version from supabase_migrations.schema_migrations "
                "order by version"
            )
            remote_versions = [str(row["version"]) for row in cur.fetchall()]
            if remote_versions != local_versions:
                raise HarnessFailure("local and remote migration histories differ")

            cur.execute(
                """
                select
                  count(*)::integer as auth_user_count,
                  count(*) filter (
                    where id = any(%s::uuid[])
                      and lower(coalesce(email, '')) like
                        '%%@credit-accounting.example.test'
                      and raw_app_meta_data @>
                        '{"environment":"DEVELOPMENT","fake_data":true}'::jsonb
                  )::integer as exact_fake_identity_count,
                  count(*) filter (
                    where not (id = any(%s::uuid[]))
                       or lower(coalesce(email, '')) not like
                            '%%@credit-accounting.example.test'
                       or not (
                         raw_app_meta_data @>
                           '{"environment":"DEVELOPMENT","fake_data":true}'::jsonb
                       )
                  )::integer as unexpected_auth_count
                from auth.users
                """,
                (expected_users, expected_users),
            )
            auth = dict(cur.fetchone() or {})
            if auth != {
                "auth_user_count": 7,
                "exact_fake_identity_count": 7,
                "unexpected_auth_count": 0,
            }:
                raise HarnessFailure("hosted Auth identities changed unexpectedly")

            cur.execute(
                """
                with application_tables as (
                  select c.oid, c.relrowsecurity, c.relforcerowsecurity
                  from pg_class c
                  join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relkind in ('r', 'p')
                ), financial_tables as (
                  select c.oid
                  from pg_class c
                  join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public'
                    and c.relname = any(array[
                      'audit_events', 'customer_repayments',
                      'financial_correction_events',
                      'financial_correction_requests', 'financial_reversals',
                      'fuel_credit_correction_proposals', 'fuel_credit_sales',
                      'idempotency_keys', 'interest_accrual_components',
                      'interest_accrual_runs', 'interest_accruals',
                      'ledger_entries', 'ledger_transactions',
                      'repayment_allocations',
                      'repayment_correction_proposals'
                    ])
                ), unbalanced as (
                  select transaction.id
                  from public.ledger_transactions transaction
                  left join public.ledger_entries entry
                    on entry.transaction_id = transaction.id
                  group by transaction.id
                  having coalesce(sum(entry.amount_paise)
                           filter (where entry.direction = 'DEBIT'), 0)
                      <> coalesce(sum(entry.amount_paise)
                           filter (where entry.direction = 'CREDIT'), 0)
                )
                select
                  (select count(*)::integer from application_tables)
                    as public_table_count,
                  (select count(*)::integer from application_tables
                   where relrowsecurity) as rls_enabled_count,
                  (select count(*)::integer from application_tables
                   where relforcerowsecurity) as rls_forced_count,
                  (select count(*)::integer from public.organizations
                   where legal_name not like 'DEVELOPMENT%%NOT REAL DATA'
                      or display_name not like 'DEVELOPMENT%%FAKE DATA ONLY')
                    as organization_marker_failures,
                  (select count(*)::integer from public.stations
                   where display_name not like 'DEVELOPMENT%%NOT REAL'
                      or time_zone_name <> 'Asia/Kolkata')
                    as station_marker_failures,
                  (select count(*)::integer from public.customers
                   where display_name not like 'DEVELOPMENT%%NOT REAL'
                      or not (
                        phone = 'fake-development-customer-phone'
                        or (
                          left(phone, 4) = '+999'
                          and length(phone) = 16
                          and substring(phone from 5) ~ '^[0-9]{12}$'
                        )
                      )
                      or alternate_phone is not null
                      or address is not null) as customer_marker_failures,
                  (select count(*)::integer from public.customer_drivers
                   where phone <> 'fake-development-driver-phone')
                    as driver_marker_failures,
                  (select count(*)::integer from application_tables
                   where has_table_privilege('service_role', oid, 'select')
                      or has_table_privilege('service_role', oid, 'insert')
                      or has_table_privilege('service_role', oid, 'update')
                      or has_table_privilege('service_role', oid, 'delete')
                      or has_table_privilege('service_role', oid, 'truncate')
                      or has_table_privilege('service_role', oid, 'references')
                      or has_table_privilege('service_role', oid, 'trigger')
                      or has_table_privilege('service_role', oid, 'maintain')
                      or has_any_column_privilege('service_role', oid, 'select')
                      or has_any_column_privilege('service_role', oid, 'insert')
                      or has_any_column_privilege('service_role', oid, 'update')
                      or has_any_column_privilege('service_role', oid, 'references'))
                    as service_role_table_grants,
                  (select count(*)::integer
                   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public'
                     and has_function_privilege('service_role', p.oid, 'execute'))
                    as service_role_rpc_grants,
                  (select count(*)::integer from financial_tables
                   where has_table_privilege('service_role', oid, 'insert')
                      or has_table_privilege('service_role', oid, 'update')
                      or has_table_privilege('service_role', oid, 'delete')
                      or has_table_privilege('service_role', oid, 'truncate')
                      or has_table_privilege('authenticated', oid, 'insert')
                      or has_table_privilege('authenticated', oid, 'update')
                      or has_table_privilege('authenticated', oid, 'delete')
                      or has_table_privilege('authenticated', oid, 'truncate')
                      or has_table_privilege('anon', oid, 'insert')
                      or has_table_privilege('anon', oid, 'update')
                      or has_table_privilege('anon', oid, 'delete')
                      or has_table_privilege('anon', oid, 'truncate'))
                    as raw_financial_mutation_grants,
                  (select count(*)::integer
                   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.prosecdef
                     and has_function_privilege('authenticated', p.oid, 'execute'))
                    as authenticated_public_definers,
                  (select count(*)::integer from cron.job) as cron_job_count,
                  (select count(*)::integer from cron.job
                   where jobname = 'credit-accounting-hourly-interest-accrual'
                     and schedule = '7 * * * *'
                     and command =
                       'select app_private.run_hourly_interest_accrual();'
                     and username = 'postgres' and active)
                    as exact_cron_job_count,
                  (select count(*)::integer from unbalanced)
                    as unbalanced_transactions,
                  (select count(*)::integer from public.idempotency_keys
                   where status <> 'COMPLETED') as incomplete_idempotency,
                  has_schema_privilege('authenticator', 'app_private', 'usage')
                    as app_private_authenticator_usage,
                  has_schema_privilege('authenticator', 'cron', 'usage')
                    as cron_authenticator_usage
                """
            )
            summary = dict(cur.fetchone() or {})
            expected_zero = {
                "organization_marker_failures",
                "station_marker_failures",
                "customer_marker_failures",
                "driver_marker_failures",
                "service_role_table_grants",
                "service_role_rpc_grants",
                "raw_financial_mutation_grants",
                "unbalanced_transactions",
                "incomplete_idempotency",
            }
            if any(int(summary[name]) != 0 for name in expected_zero):
                raise HarnessFailure("synthetic-data or security preflight failed")
            if (
                summary.get("public_table_count") != 30
                or summary.get("rls_enabled_count") != 30
                or summary.get("rls_forced_count") != 30
                or summary.get("authenticated_public_definers") != 11
                or summary.get("cron_job_count") != 1
                or summary.get("exact_cron_job_count") != 1
                or summary.get("app_private_authenticator_usage") is not False
                or summary.get("cron_authenticator_usage") is not False
            ):
                raise HarnessFailure("catalog, RLS, or cron preflight drifted")
            cur.execute("rollback")

        verifier_sql = CATALOG_VERIFIER.read_text(encoding="utf-8")
        with connection.cursor() as cur:
            cur.execute(verifier_sql, prepare=False)
            verifier_passed = False
            while True:
                if cur.description is not None:
                    verifier_row = cur.fetchone()
                    verifier_passed = verifier_passed or bool(
                        verifier_row
                        and any(
                            str(value).startswith("PASS: hosted catalog")
                            for value in verifier_row.values()
                        )
                    )
                if not cur.nextset():
                    break
            if not verifier_passed:
                raise HarnessFailure("committed catalog/security verifier did not pass")

    return {
        "migration_count": len(remote_versions),
        "migration_head": remote_versions[-1],
        "migration_histories_match": True,
        "auth_user_count": auth["auth_user_count"],
        "exact_fake_identity_count": auth["exact_fake_identity_count"],
        "no_real_customer_markers": True,
        "public_table_count": summary["public_table_count"],
        "rls_enabled_count": summary["rls_enabled_count"],
        "rls_forced_count": summary["rls_forced_count"],
        "service_role_table_grants": summary["service_role_table_grants"],
        "service_role_rpc_grants": summary["service_role_rpc_grants"],
        "raw_financial_mutation_grants": summary[
            "raw_financial_mutation_grants"
        ],
        "authenticated_public_definers": summary[
            "authenticated_public_definers"
        ],
        "cron_job_count": summary["cron_job_count"],
        "catalog_verifier": "PASS",
        "default_acl_hardening": "PASS",
        "schema_function_grant_drift": 0,
    }


def cron_snapshot(factory: ConnectionFactory) -> dict[str, Any]:
    return query_one(
        factory,
        """
        select
          count(*)::integer as recorded_runs,
          max(runid)::bigint as latest_run_id,
          (array_agg(status order by runid desc))[1] as latest_status,
          (array_agg(start_time order by runid desc))[1] as latest_start_time,
          (array_agg(end_time order by runid desc))[1] as latest_end_time
        from cron.job_run_details
        where jobid = (
          select jobid from cron.job
          where jobname = 'credit-accounting-hourly-interest-accrual'
        )
        """,
        application="phase-2e-cron-snapshot",
    )


def synthetic_phone(run_uuid: uuid.UUID, offset: int) -> str:
    suffix = (run_uuid.int + offset) % 1_000_000_000_000
    return f"+999{suffix:012d}"


def create_account(
    factory: ConnectionFactory,
    *,
    actor_id: str,
    run_marker: str,
    scenario: str,
    phone: str,
    credit_limit_paise: int,
) -> dict[str, Any]:
    display_name = f"DEVELOPMENT HOSTED CONCURRENCY {run_marker} {scenario} - NOT REAL"

    def operation(cur: psycopg.Cursor[Any]) -> dict[str, Any]:
        set_authenticated(cur, actor_id)
        cur.execute(
            """
            select customer_id, credit_account_id, credit_limit_paise
            from public.create_customer_with_credit_account(
              %s, 'Development', %s, %s, %s, null, null,
              %s, 0.18000000, 0, 'AFTER_GRACE_ONLY', 30, %s
            )
            """,
            (
                EXPECTED_STATION_ID,
                f"Concurrency {scenario}",
                phone,
                display_name,
                credit_limit_paise,
                uuid.uuid4(),
            ),
        )
        row = cur.fetchone()
        if row is None:
            raise HarnessFailure(f"{scenario} account creation returned no row")
        created = dict(row)
        cur.execute(
            """
            select outstanding_principal_paise, available_credit_paise
            from public.get_credit_account_balance(%s)
            """,
            (created["credit_account_id"],),
        )
        balance = cur.fetchone()
        if balance is None:
            raise HarnessFailure(f"{scenario} opening balance returned no row")
        created.update(dict(balance))
        return created

    result = execute_transaction(
        factory, operation, application=f"phase-2e-create-{scenario.lower()}"
    )
    if (
        int(result["credit_limit_paise"]) != credit_limit_paise
        or int(result["outstanding_principal_paise"]) != 0
        or int(result["available_credit_paise"]) != credit_limit_paise
    ):
        raise HarnessFailure(f"{scenario} account did not start empty")
    return result


def post_fuel(
    factory: ConnectionFactory,
    *,
    actor_id: str,
    account_id: uuid.UUID | str,
    amount_paise: int,
    key: uuid.UUID,
    reference: str,
    application: str,
) -> dict[str, Any]:
    def operation(cur: psycopg.Cursor[Any]) -> dict[str, Any]:
        set_authenticated(cur, actor_id)
        cur.execute(
            """
            select transaction_id, sale_id, amount_paise,
                   outstanding_principal_paise, available_credit_paise,
                   idempotent_replay
            from public.post_fuel_credit_transaction(%s, %s, %s, %s, %s, %s)
            """,
            (
                account_id,
                EXPECTED_STATION_ID,
                EXPECTED_PRODUCT_ID,
                amount_paise,
                key,
                reference,
            ),
        )
        row = cur.fetchone()
        if row is None:
            raise HarnessFailure("fuel posting returned no row")
        return dict(row)

    return execute_transaction(factory, operation, application=application)


def submit_reversal(
    factory: ConnectionFactory,
    *,
    manager_id: str,
    original_transaction_id: uuid.UUID | str,
    run_marker: str,
) -> dict[str, Any]:
    def operation(cur: psycopg.Cursor[Any]) -> dict[str, Any]:
        set_authenticated(cur, manager_id)
        cur.execute(
            """
            select request_id, status, version, correlation_id, idempotent_replay
            from public.submit_financial_correction_request(
              %s, 'REVERSAL_ONLY', 'OPERATIONAL_ERROR', %s, %s,
              null, null, null, null, null, null, null, null, null, null
            )
            """,
            (
                original_transaction_id,
                f"Development-only hosted concurrency {run_marker}; not real data.",
                uuid.uuid4(),
            ),
        )
        row = cur.fetchone()
        if row is None:
            raise HarnessFailure("correction submission returned no row")
        return dict(row)

    result = execute_transaction(
        factory, operation, application="phase-2e-submit-correction"
    )
    if result["status"] != "PENDING_REVIEW" or int(result["version"]) != 1:
        raise HarnessFailure("correction request did not start pending at version 1")
    return result


def classify_psycopg_error(exc: psycopg.Error) -> tuple[str, str | None, str | None]:
    sqlstate = getattr(exc, "sqlstate", None)
    primary = str(getattr(getattr(exc, "diag", None), "message_primary", "") or "")
    match = ERROR_CODE.search(primary)
    code = match.group(0) if match else None
    if (
        isinstance(exc, psycopg.OperationalError)
        or (sqlstate and sqlstate.startswith(INFRASTRUCTURE_SQLSTATE_PREFIXES))
        or sqlstate in INFRASTRUCTURE_SQLSTATES
    ):
        return "infrastructure_failure", sqlstate, code
    if sqlstate == "40P01":
        return "deadlock", sqlstate, code
    if sqlstate == "55P03":
        return "lock_timeout", sqlstate, code
    if sqlstate == "57014":
        return "statement_timeout", sqlstate, code
    if code:
        return "business_rejection", sqlstate, code
    return "unexpected_database_failure", sqlstate, code


def run_race(
    factory: ConnectionFactory,
    *,
    scenario: str,
    racers: list[
        tuple[
            str,
            str,
            str | None,
            float,
            float,
            Callable[[psycopg.Cursor[Any]], dict[str, Any]],
        ]
    ],
) -> list[RacerResult]:
    barrier = threading.Barrier(len(racers) + 1)
    results: list[RacerResult | None] = [None] * len(racers)

    def worker(
        index: int,
        racer: str,
        logical_operation: str,
        actor_id: str | None,
        delay_seconds: float,
        hold_after_seconds: float,
        operation: Callable[[psycopg.Cursor[Any]], dict[str, Any]],
    ) -> None:
        result = RacerResult(
            racer=racer,
            logical_operation=logical_operation,
            actor="internal-test-admin" if actor_id is None else racer,
        )
        started = time.monotonic()
        connection: psycopg.Connection[Any] | None = None
        transaction_started = False
        operation_started: float | None = None
        try:
            connection = factory.connect(
                f"phase-2e-{scenario.lower()}-{racer.lower()}"
            )
            result.session_started_utc = utc_now()
            barrier.wait(timeout=20)
            if delay_seconds:
                time.sleep(delay_seconds)
            with connection.cursor() as cur:
                begin(cur)
                transaction_started = True
                result.transaction_started_utc = utc_now()
                if actor_id is not None:
                    set_authenticated(cur, actor_id)
                operation_started = time.monotonic()
                result.payload = operation(cur)
                operation_finished = time.monotonic()
                if hold_after_seconds:
                    cur.execute("select pg_sleep(%s)", (hold_after_seconds,))
                cur.execute("commit")
                result.committed = True
                result.commit_state = "committed"
                result.classification = "success"
                result.operation_duration_ms = round(
                    (operation_finished - operation_started) * 1000
                )
        except threading.BrokenBarrierError:
            result.classification = "infrastructure_failure"
            result.commit_state = "not_started"
        except InfrastructureFailure:
            result.classification = "infrastructure_failure"
            result.commit_state = "not_started"
        except psycopg.Error as exc:
            classification, sqlstate, code = classify_psycopg_error(exc)
            result.classification = classification
            result.sqlstate = sqlstate
            result.error_code = code
            if connection is not None and transaction_started:
                try:
                    with connection.cursor() as cur:
                        cur.execute("rollback")
                    result.rolled_back = True
                    result.commit_state = "rolled_back"
                except psycopg.Error:
                    result.commit_state = "unknown"
            elif not transaction_started:
                result.commit_state = "not_started"
            if operation_started is not None:
                result.operation_duration_ms = round(
                    (time.monotonic() - operation_started) * 1000
                )
        except BaseException:
            result.classification = "unexpected_harness_failure"
            if connection is not None and transaction_started:
                try:
                    with connection.cursor() as cur:
                        cur.execute("rollback")
                    result.rolled_back = True
                    result.commit_state = "rolled_back"
                except psycopg.Error:
                    result.commit_state = "unknown"
        finally:
            if connection is not None:
                connection.close()
            result.duration_ms = round((time.monotonic() - started) * 1000)
            results[index] = result

    threads: list[threading.Thread] = []
    for index, racer in enumerate(racers):
        thread = threading.Thread(
            target=worker,
            args=(index, *racer),
            name=f"phase-2e-{scenario}-{racer[0]}",
            daemon=True,
        )
        thread.start()
        threads.append(thread)

    try:
        barrier.wait(timeout=20)
    except threading.BrokenBarrierError as exc:
        raise InfrastructureFailure(f"{scenario} sessions did not become ready") from exc
    for thread in threads:
        thread.join(timeout=RACE_JOIN_TIMEOUT_SECONDS)
    if any(thread.is_alive() for thread in threads):
        raise InfrastructureFailure(f"{scenario} sessions did not finish in time")
    if any(result is None for result in results):
        raise InfrastructureFailure(f"{scenario} did not record both racer results")
    typed_results = [result for result in results if result is not None]
    for result in typed_results:
        if result.operation_duration_ms is not None:
            result.lock_observation = (
                "waited_or_slow"
                if result.operation_duration_ms >= 1_000
                else "no_material_wait_observed"
            )
    return typed_results


def assert_no_infrastructure_outcome(results: list[RacerResult], scenario: str) -> None:
    failures = {
        "infrastructure_failure",
        "deadlock",
        "lock_timeout",
        "statement_timeout",
        "unexpected_database_failure",
        "unexpected_harness_failure",
    }
    if any(result.classification in failures for result in results):
        raise HarnessFailure(f"{scenario} had a non-business concurrency failure")
    if any(result.commit_state == "unknown" for result in results):
        raise InfrastructureFailure(f"{scenario} has an unknown commit state")


def fuel_race(
    factory: ConnectionFactory,
    identities: dict[str, str],
    run_uuid: uuid.UUID,
    run_marker: str,
) -> tuple[dict[str, Any], list[str]]:
    account = create_account(
        factory,
        actor_id=identities["owner-a"],
        run_marker=run_marker,
        scenario="FUEL",
        phone=synthetic_phone(run_uuid, 101),
        credit_limit_paise=100_000,
    )
    account_id = account["credit_account_id"]
    key_a, key_b = uuid.uuid4(), uuid.uuid4()
    reference_a = f"P2E-HC-{run_marker}-FUEL-A"
    reference_b = f"P2E-HC-{run_marker}-FUEL-B"

    def racer(key: uuid.UUID, reference: str) -> Callable[[Any], dict[str, Any]]:
        def operation(cur: psycopg.Cursor[Any]) -> dict[str, Any]:
            cur.execute(
                """
                select transaction_id, sale_id, outstanding_principal_paise,
                       available_credit_paise, idempotent_replay
                from public.post_fuel_credit_transaction(%s, %s, %s, 70000, %s, %s)
                """,
                (account_id, EXPECTED_STATION_ID, EXPECTED_PRODUCT_ID, key, reference),
            )
            row = cur.fetchone()
            return dict(row or {})

        return operation

    results = run_race(
        factory,
        scenario="fuel",
        racers=[
            (
                "A",
                "post fuel credit INR 700",
                identities["owner-a"],
                0.0,
                WINNER_HOLD_SECONDS,
                racer(key_a, reference_a),
            ),
            (
                "B",
                "post fuel credit INR 700",
                identities["owner-a"],
                SECOND_RACER_DELAY_SECONDS,
                0.0,
                racer(key_b, reference_b),
            ),
        ],
    )
    reconciliation = query_one(
        factory,
        """
        select
          balance.credit_limit_paise,
          balance.outstanding_principal_paise,
          balance.available_credit_paise,
          (select count(*)::integer from public.fuel_credit_sales
           where credit_account_id = %s) as fuel_sales,
          (select count(*)::integer from public.ledger_transactions
           where credit_account_id = %s) as ledger_transactions,
          (select count(*)::integer from public.ledger_entries as entry
           join public.ledger_transactions as transaction
             on transaction.id = entry.transaction_id
           where transaction.credit_account_id = %s) as ledger_entries,
          (select count(*)::integer from public.audit_events
           where request_id = any(%s::uuid[])
             and action = 'fuel_credit.posted') as success_audits,
          (select count(*)::integer from public.idempotency_keys
           where idempotency_key = any(%s::uuid[])
             and status = 'COMPLETED') as completed_idempotency,
          (select count(*)::integer from public.idempotency_keys
           where idempotency_key = any(%s::uuid[])
             and status <> 'COMPLETED') as partial_idempotency,
          (select count(*)::integer from (
             select transaction.id
             from public.ledger_transactions as transaction
             join public.ledger_entries as entry
               on entry.transaction_id = transaction.id
             where transaction.credit_account_id = %s
             group by transaction.id
             having sum(entry.amount_paise) filter (where entry.direction='DEBIT')
                 <> sum(entry.amount_paise) filter (where entry.direction='CREDIT')
           ) as unbalanced) as unbalanced_transactions
        from app_private.calculate_credit_account_balance(%s) as balance
        """,
        (
            account_id,
            account_id,
            account_id,
            [key_a, key_b],
            [key_a, key_b],
            [key_a, key_b],
            account_id,
            account_id,
        ),
        application="phase-2e-fuel-reconciliation",
    )
    successes = [result for result in results if result.committed]
    rejections = [result for result in results if not result.committed]
    if len(successes) == 2:
        raise CriticalInvariantFailure("both fuel racers committed")
    assert_no_infrastructure_outcome(results, "fuel race")
    if (
        len(successes) != 1
        or len(rejections) != 1
        or rejections[0].error_code != "FCP_INSUFFICIENT_CREDIT"
    ):
        raise HarnessFailure("fuel race did not produce one stable business rejection")
    expected = {
        "credit_limit_paise": 100_000,
        "outstanding_principal_paise": 70_000,
        "available_credit_paise": 30_000,
        "fuel_sales": 1,
        "ledger_transactions": 1,
        "ledger_entries": 2,
        "success_audits": 1,
        "completed_idempotency": 1,
        "partial_idempotency": 0,
        "unbalanced_transactions": 0,
    }
    if reconciliation != expected:
        raise HarnessFailure("fuel race reconciliation failed")
    winner_transaction = str(successes[0].payload["transaction_id"])
    return (
        {
            "starting": {"credit_limit_paise": 100_000, "principal_paise": 0},
            "racers": [asdict(result) for result in results],
            "winner": successes[0].racer,
            "loser": rejections[0].racer,
            "loser_error": rejections[0].error_code,
            "reconciliation": reconciliation,
            "partial_rows": 0,
        },
        [winner_transaction],
    )


def repayment_race(
    factory: ConnectionFactory,
    identities: dict[str, str],
    run_uuid: uuid.UUID,
    run_marker: str,
) -> tuple[dict[str, Any], list[str]]:
    account = create_account(
        factory,
        actor_id=identities["owner-a"],
        run_marker=run_marker,
        scenario="REPAYMENT",
        phone=synthetic_phone(run_uuid, 202),
        credit_limit_paise=200_000,
    )
    account_id = account["credit_account_id"]
    initial_key = uuid.uuid4()
    initial = post_fuel(
        factory,
        actor_id=identities["owner-a"],
        account_id=account_id,
        amount_paise=100_000,
        key=initial_key,
        reference=f"P2E-HC-{run_marker}-REPAYMENT-BASE",
        application="phase-2e-repayment-base",
    )
    key_a, key_b = uuid.uuid4(), uuid.uuid4()

    def racer(key: uuid.UUID, label: str) -> Callable[[Any], dict[str, Any]]:
        def operation(cur: psycopg.Cursor[Any]) -> dict[str, Any]:
            cur.execute(
                """
                select transaction_id, repayment_id, principal_allocation_paise,
                       outstanding_principal_paise, available_credit_paise,
                       idempotent_replay
                from public.post_customer_repayment(
                  %s, %s, 70000, 'PRINCIPAL_ONLY', %s,
                  null, null, null, %s, 'CASH'
                )
                """,
                (
                    account_id,
                    EXPECTED_STATION_ID,
                    key,
                    f"P2E-HC-{run_marker}-REPAYMENT-{label}",
                ),
            )
            row = cur.fetchone()
            return dict(row or {})

        return operation

    results = run_race(
        factory,
        scenario="repayment",
        racers=[
            (
                "A",
                "post principal repayment INR 700",
                identities["owner-a"],
                0.0,
                WINNER_HOLD_SECONDS,
                racer(key_a, "A"),
            ),
            (
                "B",
                "post principal repayment INR 700",
                identities["owner-a"],
                SECOND_RACER_DELAY_SECONDS,
                0.0,
                racer(key_b, "B"),
            ),
        ],
    )
    reconciliation = query_one(
        factory,
        """
        select
          obligations.credit_limit_paise,
          obligations.outstanding_principal_paise,
          obligations.outstanding_interest_paise,
          obligations.total_due_paise,
          obligations.available_credit_paise,
          (select count(*)::integer from public.customer_repayments
           where credit_account_id = %s) as repayments,
          (select count(*)::integer from public.repayment_allocations
           where credit_account_id = %s) as allocations,
          (select count(*)::integer from public.ledger_transactions
           where credit_account_id = %s
             and transaction_type = 'CUSTOMER_REPAYMENT')
            as repayment_ledger_transactions,
          (select count(*)::integer from public.ledger_entries as entry
           join public.ledger_transactions as transaction
             on transaction.id = entry.transaction_id
           where transaction.credit_account_id = %s
             and transaction.transaction_type = 'CUSTOMER_REPAYMENT')
            as repayment_ledger_entries,
          (select count(*)::integer from public.audit_events
           where request_id = any(%s::uuid[])
             and action = 'customer_repayment.posted') as success_audits,
          (select count(*)::integer from public.idempotency_keys
           where idempotency_key = any(%s::uuid[])
             and status = 'COMPLETED') as completed_idempotency,
          (select count(*)::integer from public.idempotency_keys
           where idempotency_key = any(%s::uuid[])
             and status <> 'COMPLETED') as partial_idempotency
        from app_private.calculate_credit_account_obligations(%s) as obligations
        """,
        (
            account_id,
            account_id,
            account_id,
            account_id,
            [key_a, key_b],
            [key_a, key_b],
            [key_a, key_b],
            account_id,
        ),
        application="phase-2e-repayment-reconciliation",
    )
    successes = [result for result in results if result.committed]
    rejections = [result for result in results if not result.committed]
    if len(successes) == 2 or int(reconciliation["outstanding_principal_paise"]) < 0:
        raise CriticalInvariantFailure("both repayments committed or principal is negative")
    assert_no_infrastructure_outcome(results, "repayment race")
    if (
        len(successes) != 1
        or len(rejections) != 1
        or rejections[0].error_code != "RPP_PRINCIPAL_EXCEEDS_DUE"
    ):
        raise HarnessFailure("repayment race did not produce one stable rejection")
    expected = {
        "credit_limit_paise": 200_000,
        "outstanding_principal_paise": 30_000,
        "outstanding_interest_paise": 0,
        "total_due_paise": 30_000,
        "available_credit_paise": 170_000,
        "repayments": 1,
        "allocations": 1,
        "repayment_ledger_transactions": 1,
        "repayment_ledger_entries": 2,
        "success_audits": 1,
        "completed_idempotency": 1,
        "partial_idempotency": 0,
    }
    if reconciliation != expected:
        raise HarnessFailure("repayment race reconciliation failed")
    winner_transaction = str(successes[0].payload["transaction_id"])
    return (
        {
            "starting": {
                "credit_limit_paise": 200_000,
                "principal_paise": 100_000,
                "available_credit_paise": int(initial["available_credit_paise"]),
            },
            "racers": [asdict(result) for result in results],
            "winner": successes[0].racer,
            "loser": rejections[0].racer,
            "loser_error": rejections[0].error_code,
            "reconciliation": reconciliation,
            "partial_rows": 0,
        },
        [str(initial["transaction_id"]), winner_transaction],
    )


def interest_race(
    factory: ConnectionFactory,
    identities: dict[str, str],
    run_uuid: uuid.UUID,
    run_marker: str,
) -> tuple[dict[str, Any], list[str]]:
    account = create_account(
        factory,
        actor_id=identities["owner-a"],
        run_marker=run_marker,
        scenario="INTEREST",
        phone=synthetic_phone(run_uuid, 303),
        credit_limit_paise=200_000,
    )
    account_id = account["credit_account_id"]
    customer_id = account["customer_id"]
    local_date_row = query_one(
        factory,
        """
        select (statement_timestamp() at time zone time_zone_name)::date
          as station_local_date
        from public.stations where id = %s
        """,
        (EXPECTED_STATION_ID,),
        application="phase-2e-station-date",
    )
    target_date = local_date_row["station_local_date"] - timedelta(days=1)
    source_transaction_id = uuid.uuid4()
    test_run_id = uuid.uuid4()
    test_request_id = uuid.uuid4()
    principal_paise = 36_501

    def setup(cur: psycopg.Cursor[Any]) -> None:
        cur.execute(
            """
            insert into public.ledger_transactions (
              id, organization_id, station_id, credit_account_id, customer_id,
              transaction_type, status, amount_paise, currency_code,
              occurred_at, business_date, created_by, created_at
            ) values (
              %s, %s, %s, %s, %s, 'FUEL_CREDIT', 'POSTED', %s, 'INR',
              (%s::date::timestamp + interval '12 hours')
                at time zone 'Asia/Kolkata',
              %s, %s, statement_timestamp()
            )
            """,
            (
                source_transaction_id,
                EXPECTED_ORGANIZATION_ID,
                EXPECTED_STATION_ID,
                account_id,
                customer_id,
                principal_paise,
                target_date,
                target_date,
                identities["owner-a"],
            ),
        )
        cur.execute(
            """
            insert into public.ledger_entries (
              organization_id, transaction_id, account_code, direction,
              amount_paise, currency_code
            ) values
              (%s, %s, 'CUSTOMER_ACCOUNTS_RECEIVABLE', 'DEBIT', %s, 'INR'),
              (%s, %s, 'FUEL_SALES_REVENUE', 'CREDIT', %s, 'INR')
            """,
            (
                EXPECTED_ORGANIZATION_ID,
                source_transaction_id,
                principal_paise,
                EXPECTED_ORGANIZATION_ID,
                source_transaction_id,
                principal_paise,
            ),
        )
        cur.execute(
            """
            insert into public.interest_accrual_runs (
              id, organization_id, station_id, trigger_source, request_id,
              requested_at, station_time_zone_name, station_local_date,
              latest_completed_business_date, max_catch_up_days, status
            ) values (
              %s, %s, %s, 'TEST', %s,
              ((%s::date + 1)::timestamp + interval '12 hours')
                at time zone 'Asia/Kolkata',
              'Asia/Kolkata', %s::date + 1, %s, 1, 'STARTED'
            )
            """,
            (
                test_run_id,
                EXPECTED_ORGANIZATION_ID,
                EXPECTED_STATION_ID,
                test_request_id,
                target_date,
                target_date,
                target_date,
            ),
        )

    execute_transaction(factory, setup, application="phase-2e-interest-setup")

    def racer() -> Callable[[Any], dict[str, Any]]:
        def operation(cur: psycopg.Cursor[Any]) -> dict[str, Any]:
            cur.execute(
                """
                select interest_accrual_id, was_created, posted_interest_paise,
                       ledger_transaction_id, raw_interest_paise,
                       closing_fractional_carry_paise
                from app_private.post_interest_for_account_date(%s, %s, %s)
                """,
                (test_run_id, account_id, target_date),
            )
            row = cur.fetchone()
            return dict(row or {})

        return operation

    results = run_race(
        factory,
        scenario="interest",
        racers=[
            (
                "A",
                "post interest for one account/date",
                None,
                0.0,
                WINNER_HOLD_SECONDS,
                racer(),
            ),
            (
                "B",
                "post interest for one account/date",
                None,
                SECOND_RACER_DELAY_SECONDS,
                0.0,
                racer(),
            ),
        ],
    )
    reconciliation = query_one(
        factory,
        """
        select
          count(*)::integer as logical_accruals,
          count(*) filter (where run_id = %s)::integer as linked_to_test_run,
          coalesce(sum(posted_interest_paise), 0)::bigint as posted_paise,
          coalesce(sum(raw_interest_paise), 0)::numeric as raw_interest_paise,
          coalesce(sum(opening_fractional_carry_paise), 0)::numeric
            as opening_carry_paise,
          coalesce(sum(closing_fractional_carry_paise), 0)::numeric
            as closing_carry_paise,
          count(*) filter (
            where abs(
              closing_fractional_carry_paise
                - (opening_fractional_carry_paise + raw_interest_paise
                   - posted_interest_paise)
            ) > 0.000000000000000001
          )::integer as carry_mismatches,
          (select count(*)::integer from public.interest_accrual_components
           where credit_account_id = %s and interest_business_date = %s)
            as component_count,
          (select count(*)::integer from public.ledger_transactions
           where credit_account_id = %s
             and transaction_type = 'INTEREST_CHARGE')
            as interest_ledger_transactions,
          (select count(*)::integer from public.ledger_entries as entry
           join public.ledger_transactions as transaction
             on transaction.id = entry.transaction_id
           where transaction.credit_account_id = %s
             and transaction.transaction_type = 'INTEREST_CHARGE')
            as interest_ledger_entries,
          (select count(*)::integer from public.audit_events
           where request_id = %s and action = 'interest.accrued'
             and after_state->>'credit_account_id' = %s::text)
            as interest_audits,
          count(*) filter (
            where posted_interest_paise > 0
              and ledger_transaction_id is null
          )::integer as missing_ledger_links
        from public.interest_accruals
        where credit_account_id = %s and business_date = %s
        """,
        (
            test_run_id,
            account_id,
            target_date,
            account_id,
            account_id,
            test_request_id,
            account_id,
            account_id,
            target_date,
        ),
        application="phase-2e-interest-reconciliation",
    )
    assert_no_infrastructure_outcome(results, "interest race")
    if not all(result.committed for result in results):
        raise HarnessFailure("one interest racer did not commit deterministically")
    created_flags = sorted(bool(result.payload.get("was_created")) for result in results)
    if created_flags != [False, True]:
        raise CriticalInvariantFailure("interest race created duplicate logical evidence")
    if (
        reconciliation["logical_accruals"] != 1
        or reconciliation["linked_to_test_run"] != 1
        or reconciliation["posted_paise"] != 18
        or reconciliation["component_count"] != 1
        or reconciliation["interest_ledger_transactions"] != 1
        or reconciliation["interest_ledger_entries"] != 2
        or reconciliation["interest_audits"] != 1
        or reconciliation["carry_mismatches"] != 0
        or reconciliation["missing_ledger_links"] != 0
        or not (Decimal("0") <= reconciliation["closing_carry_paise"] < Decimal("1"))
    ):
        raise CriticalInvariantFailure("interest race reconciliation failed")

    def finalize_run(cur: psycopg.Cursor[Any]) -> None:
        cur.execute(
            """
            update public.interest_accrual_runs
            set first_business_date = %s,
                last_business_date = %s,
                accounts_examined = 1,
                account_days_processed = 1,
                accrual_rows_created = 1,
                components_created = 1,
                interest_posted_paise = 18,
                more_dates_pending = false,
                status = 'COMPLETED',
                result_code = 'PHASE_2E_HOSTED_CONCURRENCY_PASS',
                completed_at = statement_timestamp()
            where id = %s and status = 'STARTED'
            """,
            (target_date, target_date, test_run_id),
        )
        if cur.rowcount != 1:
            raise HarnessFailure("TEST interest run could not be finalized exactly once")

    execute_transaction(factory, finalize_run, application="phase-2e-interest-finalize")
    winner = next(result for result in results if result.payload["was_created"])
    replay = next(result for result in results if not result.payload["was_created"])
    interest_transaction_id = str(winner.payload["ledger_transaction_id"])
    return (
        {
            "target_date": target_date,
            "starting_principal_paise": principal_paise,
            "test_run_status": "COMPLETED",
            "racers": [asdict(result) for result in results],
            "winner": winner.racer,
            "replay": replay.racer,
            "reconciliation": reconciliation,
            "fractional_carry_reconciled": True,
            "partial_rows": 0,
        },
        [str(source_transaction_id), interest_transaction_id],
    )


def correction_race(
    factory: ConnectionFactory,
    identities: dict[str, str],
    run_uuid: uuid.UUID,
    run_marker: str,
) -> tuple[dict[str, Any], list[str]]:
    account = create_account(
        factory,
        actor_id=identities["owner-a"],
        run_marker=run_marker,
        scenario="CORRECTION",
        phone=synthetic_phone(run_uuid, 404),
        credit_limit_paise=500_000,
    )
    account_id = account["credit_account_id"]
    original = post_fuel(
        factory,
        actor_id=identities["owner-a"],
        account_id=account_id,
        amount_paise=100_000,
        key=uuid.uuid4(),
        reference=f"P2E-HC-{run_marker}-CORRECTION-BASE",
        application="phase-2e-correction-base",
    )
    original_id = original["transaction_id"]
    fingerprint_before = query_one(
        factory,
        "select app_private.financial_transaction_fingerprint(%s) as fingerprint",
        (original_id,),
        application="phase-2e-fingerprint-before",
    )["fingerprint"]
    request = submit_reversal(
        factory,
        manager_id=identities["manager"],
        original_transaction_id=original_id,
        run_marker=run_marker,
    )
    request_id = request["request_id"]

    def racer() -> Callable[[Any], dict[str, Any]]:
        def operation(cur: psycopg.Cursor[Any]) -> dict[str, Any]:
            cur.execute(
                """
                select request_id, status, version, reversal_transaction_id,
                       replacement_transaction_id, outstanding_principal_paise,
                       available_credit_paise, idempotent_replay
                from public.approve_and_execute_financial_correction(%s, 1)
                """,
                (request_id,),
            )
            row = cur.fetchone()
            return dict(row or {})

        return operation

    results = run_race(
        factory,
        scenario="correction",
        racers=[
            (
                "OWNER_A",
                "approve and execute correction version 1",
                identities["owner-a"],
                0.0,
                WINNER_HOLD_SECONDS,
                racer(),
            ),
            (
                "OWNER_B",
                "approve and execute correction version 1",
                identities["owner-b"],
                SECOND_RACER_DELAY_SECONDS,
                0.0,
                racer(),
            ),
        ],
    )
    fingerprint_after = query_one(
        factory,
        "select app_private.financial_transaction_fingerprint(%s) as fingerprint",
        (original_id,),
        application="phase-2e-fingerprint-after",
    )["fingerprint"]
    reconciliation = query_one(
        factory,
        """
        select
          request.status,
          request.version,
          request.requester_id,
          request.decided_by,
          request.reversal_transaction_id,
          request.replacement_transaction_id,
          (select count(*)::integer from public.financial_reversals
           where request_id = request.id) as reversal_count,
          (select count(*)::integer from public.financial_correction_events
           where request_id = request.id
             and event_type = 'APPROVED_AND_EXECUTED') as approval_events,
          (select count(*)::integer from public.ledger_transactions
           where id = request.reversal_transaction_id
             and transaction_type = 'FINANCIAL_REVERSAL')
            as reversal_ledger_transactions,
          (select count(*)::integer from public.ledger_entries
           where transaction_id = request.reversal_transaction_id)
            as reversal_ledger_entries,
          (select count(*)::integer from public.ledger_transactions
           where id = request.original_transaction_id
             and transaction_type = 'FUEL_CREDIT'
             and status = 'POSTED' and amount_paise = 100000)
            as original_unchanged_rows,
          (select count(*)::integer from public.audit_events
           where action = 'financial_correction.reversal_executed'
             and entity_id = request.reversal_transaction_id)
            as reversal_audits
        from public.financial_correction_requests as request
        where request.id = %s
        """,
        (request_id,),
        application="phase-2e-correction-reconciliation",
    )
    assert_no_infrastructure_outcome(results, "correction race")
    if not all(result.committed for result in results):
        raise HarnessFailure("one correction approver did not reach a terminal result")
    non_replays = [result for result in results if not result.payload["idempotent_replay"]]
    replays = [result for result in results if result.payload["idempotent_replay"]]
    if len(non_replays) != 1 or reconciliation["reversal_count"] != 1:
        raise CriticalInvariantFailure("correction race created duplicate execution")
    if (
        len(replays) != 1
        or reconciliation["status"] != "APPROVED_AND_EXECUTED"
        or reconciliation["version"] != 2
        or str(reconciliation["requester_id"]) != identities["manager"]
        or str(reconciliation["decided_by"])
        not in {identities["owner-a"], identities["owner-b"]}
        or reconciliation["replacement_transaction_id"] is not None
        or reconciliation["approval_events"] != 1
        or reconciliation["reversal_ledger_transactions"] != 1
        or reconciliation["reversal_ledger_entries"] != 2
        or reconciliation["original_unchanged_rows"] != 1
        or reconciliation["reversal_audits"] != 1
        or fingerprint_after != fingerprint_before
    ):
        raise HarnessFailure("correction race reconciliation failed")
    reversal_id = str(reconciliation["reversal_transaction_id"])
    return (
        {
            "request_id": str(request_id),
            "request_starting_status": "PENDING_REVIEW",
            "request_starting_version": 1,
            "racers": [asdict(result) for result in results],
            "winner": non_replays[0].racer,
            "loser": replays[0].racer,
            "loser_outcome": "terminal idempotent replay",
            "reconciliation": reconciliation,
            "original_fingerprint_unchanged": True,
            "partial_rows": 0,
        },
        [str(original_id), reversal_id],
    )


def global_reconciliation(
    factory: ConnectionFactory,
    transaction_ids: list[str],
) -> dict[str, Any]:
    if len(transaction_ids) != len(set(transaction_ids)):
        raise HarnessFailure("run transaction list contains duplicates")
    result = query_one(
        factory,
        """
        with totals as (
          select transaction.id,
                 count(entry.id)::integer as entry_count,
                 coalesce(sum(entry.amount_paise)
                   filter (where entry.direction='DEBIT'), 0)::bigint as debits,
                 coalesce(sum(entry.amount_paise)
                   filter (where entry.direction='CREDIT'), 0)::bigint as credits
          from public.ledger_transactions as transaction
          left join public.ledger_entries as entry
            on entry.transaction_id = transaction.id
          where transaction.id = any(%s::uuid[])
          group by transaction.id
        )
        select
          count(*)::integer as transaction_count,
          count(*) filter (where debits <> credits)::integer as unbalanced_count,
          count(*) filter (where entry_count <> 2)::integer
            as unexpected_entry_count,
          coalesce(sum(debits), 0)::bigint as total_debit_paise,
          coalesce(sum(credits), 0)::bigint as total_credit_paise,
          (select count(*)::integer from (
             select transaction.id
             from public.ledger_transactions as transaction
             left join public.ledger_entries as entry
               on entry.transaction_id = transaction.id
             group by transaction.id
             having coalesce(sum(entry.amount_paise)
                      filter (where entry.direction='DEBIT'),0)
                 <> coalesce(sum(entry.amount_paise)
                      filter (where entry.direction='CREDIT'),0)
           ) as unbalanced) as global_unbalanced_count,
          (select count(*)::integer from public.idempotency_keys
           where status <> 'COMPLETED') as incomplete_idempotency,
          (select count(*)::integer from public.interest_accrual_runs
           where status = 'STARTED') as unfinished_interest_runs
        from totals
        """,
        (transaction_ids,),
        application="phase-2e-global-reconciliation",
    )
    if (
        result["transaction_count"] != len(transaction_ids)
        or result["unbalanced_count"] != 0
        or result["unexpected_entry_count"] != 0
        or result["total_debit_paise"] != result["total_credit_paise"]
        or result["global_unbalanced_count"] != 0
        or result["incomplete_idempotency"] != 0
        or result["unfinished_interest_runs"] != 0
    ):
        raise CriticalInvariantFailure("global hosted reconciliation failed")
    return result


def lock_summary(scenarios: dict[str, Any]) -> dict[str, Any]:
    racers = [
        racer
        for scenario in scenarios.values()
        for racer in scenario.get("racers", [])
    ]
    return {
        "deadlocks": sum(racer["classification"] == "deadlock" for racer in racers),
        "lock_timeouts": sum(
            racer["classification"] == "lock_timeout" for racer in racers
        ),
        "statement_timeouts": sum(
            racer["classification"] == "statement_timeout" for racer in racers
        ),
        "infrastructure_failures": sum(
            racer["classification"] == "infrastructure_failure" for racer in racers
        ),
        "unknown_commit_states": sum(
            racer["commit_state"] == "unknown" for racer in racers
        ),
        "material_waits_observed": sum(
            racer.get("lock_observation") == "waited_or_slow" for racer in racers
        ),
    }


def main() -> int:
    run_uuid = uuid.uuid4()
    run_marker = run_uuid.hex[:12].upper()
    evidence_path = EVIDENCE_DIR / f"phase-2e-hosted-concurrency-{run_marker}.json"
    token = ""
    password = ""
    stage = "startup"
    report: dict[str, Any] = {
        "status": "FAIL",
        "run_id": run_marker,
        "started_utc": utc_now(),
        "classification": "low-volume deterministic smoke; not load or stress testing",
        "cron_manually_invoked": False,
        "network_retry_count": 0,
    }
    try:
        stage = "target validation"
        host, database, port = validate_target_environment()
        identities = load_fake_identities()
        token = required_environment("SUPABASE_ACCESS_TOKEN")
        stage = "management preflight"
        management_before = management_preflight(token)
        stage = "temporary login"
        role, password, ttl_seconds = temporary_login(token, read_only=False)
        factory = ConnectionFactory(
            host=host,
            database=database,
            port=port,
            role=role,
            password=password,
        )
        report["connection"] = {
            "method": "Supavisor session mode",
            "region": EXPECTED_REGION,
            "port_class": "session-mode 5432",
            "tls_required_and_verified": True,
            "credential_source": "short-lived official CLI login role in process memory",
            "credential_ttl_seconds": ttl_seconds,
        }
        stage = "database preflight"
        report["preflight"] = {
            "management": management_before,
            "database": database_preflight(
                factory, identities, phase="pre-concurrency"
            ),
        }
        stage = "cron preflight snapshot"
        cron_before = cron_snapshot(factory)
        if os.environ.get("PHASE_2E_PREFLIGHT_ONLY") == "1":
            print("PASS: hosted concurrency preflight only; no race was run")
            return 0

        scenarios: dict[str, Any] = {}
        transaction_ids: list[str] = []
        stage = "fuel-credit race"
        scenarios["fuel"], created = fuel_race(
            factory, identities, run_uuid, run_marker
        )
        transaction_ids.extend(created)
        print("PASS: hosted fuel-credit overspending race")

        stage = "repayment race"
        scenarios["repayment"], created = repayment_race(
            factory, identities, run_uuid, run_marker
        )
        transaction_ids.extend(created)
        print("PASS: hosted competing repayment race")

        stage = "interest-accrual race"
        scenarios["interest"], created = interest_race(
            factory, identities, run_uuid, run_marker
        )
        transaction_ids.extend(created)
        print("PASS: hosted duplicate interest-accrual race")

        stage = "correction-approval race"
        scenarios["correction"], created = correction_race(
            factory, identities, run_uuid, run_marker
        )
        transaction_ids.extend(created)
        print("PASS: hosted concurrent correction-approval race")

        stage = "global reconciliation"
        report["scenarios"] = scenarios
        report["global_reconciliation"] = global_reconciliation(
            factory, transaction_ids
        )
        report["no_partial_state"] = all(
            scenario["partial_rows"] == 0 for scenario in scenarios.values()
        )
        report["lock_summary"] = lock_summary(scenarios)
        if any(
            report["lock_summary"][name] != 0
            for name in (
                "deadlocks",
                "lock_timeouts",
                "statement_timeouts",
                "infrastructure_failures",
                "unknown_commit_states",
            )
        ):
            raise HarnessFailure("unexpected lock or infrastructure outcome")

        stage = "post-concurrency management verification"
        management_after = management_preflight(token)
        stage = "post-concurrency database verification"
        database_after = database_preflight(
            factory, identities, phase="post-concurrency"
        )
        stage = "post-concurrency cron snapshot"
        cron_after = cron_snapshot(factory)
        report["post_verification"] = {
            "management": management_after,
            "database": database_after,
        }
        report["cron"] = {
            "registration_unchanged": True,
            "before": cron_before,
            "after": cron_after,
            "incidental_runs": max(
                0,
                int(cron_after["recorded_runs"])
                - int(cron_before["recorded_runs"]),
            ),
            "manual_invocation": False,
        }
        report["status"] = "PASS"
        report["completed_utc"] = utc_now()
        EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)
        evidence_path.write_text(
            json.dumps(json_value(report), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"PASS: all four hosted races reconciled; run_id={run_marker}")
        print(f"PASS: sanitized evidence saved under .local-state for {run_marker}")
        return 0
    except CriticalInvariantFailure as exc:
        report["failure_class"] = "critical_financial_concurrency_blocker"
        report["failure"] = str(exc)
        print(f"FAIL: critical hosted concurrency blocker: {exc}", file=sys.stderr)
        return 2
    except InfrastructureFailure as exc:
        report["failure_class"] = "infrastructure_or_network"
        report["failure"] = str(exc)
        print(f"FAIL: hosted concurrency infrastructure: {exc}", file=sys.stderr)
        return 3
    except psycopg.Error as exc:
        classification, sqlstate, code = classify_psycopg_error(exc)
        report["failure_class"] = classification
        report["sqlstate"] = sqlstate
        report["application_error_code"] = code
        print(
            "FAIL: hosted concurrency database error: "
            f"stage={stage}; classification={classification}; "
            f"sqlstate={sqlstate or 'none'}; "
            f"application_error_code={code or 'none'}",
            file=sys.stderr,
        )
        return 4
    except (HarnessFailure, OSError, ValueError, KeyError, TypeError) as exc:
        report["failure_class"] = "precondition_or_invariant"
        report["failure"] = str(exc)
        print(f"FAIL: hosted concurrency smoke: {exc}", file=sys.stderr)
        return 1
    finally:
        token = ""
        password = ""


if __name__ == "__main__":
    raise SystemExit(main())
