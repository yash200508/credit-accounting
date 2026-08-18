#!/usr/bin/env python3
"""Validate the hosted hourly interest cycle without changing cron.

This harness is deliberately split into explicit modes because a principal
posted through the trusted application function is not eligible until the next
Asia/Kolkata business day.  ``prepare`` creates one synthetic account and fuel
posting.  ``execute`` is fail-closed to the short interval after the next
station-local midnight and before the registered pg_cron job can run.  It then
calls the existing private hourly entry point exactly twice: once for work and
once for immediate idempotency evidence.

Credentials must already be present in the process environment.  They are
used only to obtain an official short-lived CLI login role and are never logged
or persisted.  Sanitized state and evidence are written only below the ignored
``.local-state`` directory.
"""

from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from typing import Any

import psycopg

from phase_2e_concurrency_smoke import (
    EVIDENCE_DIR,
    EXPECTED_DATA_API_SCHEMAS,
    EXPECTED_MIGRATION_COUNT,
    EXPECTED_ORGANIZATION_ID,
    EXPECTED_PRODUCT_ID,
    EXPECTED_PROJECT_NAME,
    EXPECTED_PROJECT_REF,
    EXPECTED_REGION,
    EXPECTED_STATION_ID,
    HarnessFailure,
    InfrastructureFailure,
    ConnectionFactory,
    api_json,
    begin,
    database_preflight,
    execute_transaction,
    json_value,
    load_fake_identities,
    management_preflight as shared_management_preflight,
    required_environment,
    set_authenticated,
    temporary_login,
    utc_now,
    validate_target_environment,
)


STATE_PATH = EVIDENCE_DIR / "phase-2e-scheduler-interest-state.json"
PRINCIPAL_PAISE = 36_501
CREDIT_LIMIT_PAISE = 100_000
ANNUAL_RATE = Decimal("0.18000000")
GRACE_DAYS = 0
GRACE_POLICY = "AFTER_GRACE_ONLY"
DAY_COUNT_BASIS = 365
EXPECTED_RAW_INTEREST = Decimal("18.000493150684931507")
EXPECTED_POSTED_INTEREST = 18
EXPECTED_CLOSING_CARRY = Decimal("0.000493150684931507")
EXPECTED_ACTIVE_STATION_COUNT = 2
EXPECTED_SUPABASE_ORGANIZATION_NAME = "surya lakshmi fuels point"
CRON_JOB_NAME = "credit-accounting-hourly-interest-accrual"
CRON_SCHEDULE = "7 * * * *"
CRON_COMMAND = "select app_private.run_hourly_interest_accrual();"
EXECUTION_APPROVAL = "APPROVED_EXACTLY_TWO_CALLS"
ROLLOVER_APPROVAL = "APPROVED_FRESH_FIXTURE_AFTER_NATURAL_CRON"
VALID_MODES = {"preflight", "prepare", "rollover", "execute", "verify"}


class TimingGate(HarnessFailure):
    """The fixture is sound, but the approved cycle is not yet safe to call."""


class CriticalSchedulerFailure(HarnessFailure):
    """A financial, ledger, or idempotency invariant failed."""


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(json_value(payload), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def load_state() -> dict[str, Any] | None:
    if not STATE_PATH.exists():
        return None
    try:
        payload = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HarnessFailure("ignored scheduler state is unreadable") from exc
    if not isinstance(payload, dict):
        raise HarnessFailure("ignored scheduler state has an invalid shape")
    if payload.get("project_ref") != EXPECTED_PROJECT_REF:
        raise HarnessFailure("scheduler state belongs to another project")
    return payload


def query_all(
    factory: ConnectionFactory,
    sql: str,
    parameters: tuple[Any, ...] = (),
    *,
    application: str,
) -> list[dict[str, Any]]:
    with factory.connect(application) as connection:
        with connection.cursor() as cur:
            begin(cur, read_only=True)
            cur.execute(sql, parameters)
            rows = [dict(row) for row in cur.fetchall()]
            cur.execute("rollback")
    return rows


def query_one(
    factory: ConnectionFactory,
    sql: str,
    parameters: tuple[Any, ...] = (),
    *,
    application: str,
) -> dict[str, Any]:
    rows = query_all(factory, sql, parameters, application=application)
    if len(rows) != 1:
        raise HarnessFailure(f"{application} did not return exactly one row")
    return rows[0]


def management_preflight(token: str) -> dict[str, Any]:
    """Extend the shared target guard with exact platform-organization proof."""
    result = shared_management_preflight(token)
    project = api_json(token, "GET", f"/projects/{EXPECTED_PROJECT_REF}")
    if not isinstance(project, dict):
        raise HarnessFailure("project organization metadata was unexpected")
    organization_id = str(project.get("organization_id", "")).strip()
    if not organization_id:
        raise HarnessFailure("project organization identifier is missing")

    response = api_json(token, "GET", "/organizations")
    organizations: Any = response
    if isinstance(response, dict):
        organizations = response.get("organizations") or response.get("data")
    if not isinstance(organizations, list):
        raise HarnessFailure("organization list response was unexpected")
    matches = [
        organization
        for organization in organizations
        if isinstance(organization, dict)
        and str(organization.get("id", "")) == organization_id
    ]
    if (
        len(matches) != 1
        or str(matches[0].get("name", "")).strip()
           != EXPECTED_SUPABASE_ORGANIZATION_NAME
    ):
        raise HarnessFailure("project is not in the approved Supabase organization")
    result["organization"] = EXPECTED_SUPABASE_ORGANIZATION_NAME
    return result


def expected_calculation() -> dict[str, Any]:
    quantum = Decimal("0.000000000000000001")
    raw = (
        Decimal(PRINCIPAL_PAISE) * ANNUAL_RATE / Decimal(DAY_COUNT_BASIS)
    ).quantize(quantum, rounding=ROUND_HALF_UP)
    posted = int(raw.quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    carry = raw - Decimal(posted)
    if (
        raw != EXPECTED_RAW_INTEREST
        or posted != EXPECTED_POSTED_INTEREST
        or carry != EXPECTED_CLOSING_CARRY
    ):
        raise HarnessFailure("local exact-decimal expectation drifted")
    return {
        "formula": "36501 * 0.18000000 / 365",
        "principal_paise": PRINCIPAL_PAISE,
        "annual_rate_fraction": ANNUAL_RATE,
        "annual_rate_percent": Decimal("18.000000"),
        "day_count_basis": DAY_COUNT_BASIS,
        "raw_interest_paise": raw,
        "cumulative_whole_paise": posted,
        "closing_fractional_carry_paise": carry,
    }


def cron_registration(factory: ConnectionFactory) -> dict[str, Any]:
    row = query_one(
        factory,
        """
        select
          count(*) over ()::integer as total_jobs,
          jobid::bigint,
          jobname,
          schedule,
          command,
          database,
          username,
          active,
          current_setting('TimeZone') as server_time_zone,
          current_setting('cron.timezone') as cron_time_zone
        from cron.job
        """,
        application="phase-2e-scheduler-cron-registration",
    )
    expected = {
        "total_jobs": 1,
        "jobname": CRON_JOB_NAME,
        "schedule": CRON_SCHEDULE,
        "command": CRON_COMMAND,
        "database": "postgres",
        "username": "postgres",
        "active": True,
        "server_time_zone": "UTC",
        "cron_time_zone": "GMT",
    }
    if any(row.get(key) != value for key, value in expected.items()):
        raise HarnessFailure("cron registration or hosted timezone drifted")
    return row


def natural_cron_history(factory: ConnectionFactory) -> dict[str, Any]:
    rows = query_all(
        factory,
        """
        select
          history.runid::bigint,
          history.jobid::bigint,
          history.database,
          history.username,
          history.status,
          case
            when history.return_message = '1 row' then 'one_row'
            when history.return_message is null then null
            else 'other_sanitized_result'
          end as result_category,
          history.start_time,
          history.end_time,
          round(
            extract(epoch from (history.end_time - history.start_time))
              * 1000,
            3
          ) as duration_ms,
          coalesce(sum(run.account_days_processed), 0)::integer
            as application_account_days_processed,
          coalesce(sum(run.accrual_rows_created), 0)::integer
            as application_accrual_rows_created,
          coalesce(sum(run.components_created), 0)::integer
            as application_components_created,
          coalesce(sum(run.interest_posted_paise), 0)::bigint
            as application_interest_posted_paise
        from cron.job_run_details as history
        left join public.interest_accrual_runs as run
          on run.trigger_source = 'SCHEDULER'
         and run.requested_at >= history.start_time - interval '1 second'
         and run.requested_at <= coalesce(history.end_time, history.start_time)
                                  + interval '1 second'
        where history.jobid = (
          select jobid from cron.job where jobname = %s
        )
        group by history.runid, history.jobid, history.database,
                 history.username, history.status, history.return_message,
                 history.start_time, history.end_time
        order by history.runid desc
        limit 48
        """,
        (CRON_JOB_NAME,),
        application="phase-2e-scheduler-natural-history",
    )
    if not rows:
        raise HarnessFailure("registered cron job has no hosted run history")
    health = {"succeeded": 0, "failed": 0, "running": 0, "unknown": 0}
    for row in rows:
        status = str(row.get("status") or "unknown").lower()
        if status in health:
            health[status] += 1
        else:
            health["unknown"] += 1
    wall_clock = [row for row in rows if row.get("status") == "succeeded"]
    positive = [
        row
        for row in wall_clock
        if int(row.get("application_interest_posted_paise") or 0) > 0
           or int(row.get("application_accrual_rows_created") or 0) > 0
    ]
    zero_work = [
        row
        for row in wall_clock
        if int(row.get("application_account_days_processed") or 0) == 0
           and int(row.get("application_accrual_rows_created") or 0) == 0
    ]
    return {
        "recent_run_count": len(rows),
        "health": health,
        "stuck_running": health["running"],
        "wall_clock_execution_observed": bool(wall_clock),
        "positive_work_wall_clock_execution_observed": bool(positive),
        "latest": rows[0],
        "latest_positive_work": positive[0] if positive else None,
        "latest_zero_work": zero_work[0] if zero_work else None,
    }


def active_station_snapshot(factory: ConnectionFactory) -> list[dict[str, Any]]:
    rows = query_all(
        factory,
        """
        select station.id, station.organization_id, station.station_code,
               station.time_zone_name
        from public.stations as station
        join public.organizations as organization
          on organization.id = station.organization_id
        where station.is_active and organization.is_active
        order by station.id
        """,
        application="phase-2e-scheduler-active-stations",
    )
    if len(rows) != EXPECTED_ACTIVE_STATION_COUNT:
        raise HarnessFailure("active station set changed unexpectedly")
    if sum(row["id"] == uuid.UUID(EXPECTED_STATION_ID) for row in rows) != 1:
        raise HarnessFailure("approved primary station is not uniquely active")
    if any(row["time_zone_name"] != "Asia/Kolkata" for row in rows):
        raise HarnessFailure("an active station timezone changed unexpectedly")
    return rows


def application_run_health(factory: ConnectionFactory) -> dict[str, Any]:
    row = query_one(
        factory,
        """
        select
          count(*) filter (where status = 'STARTED')::integer
            as unfinished_runs,
          count(*) filter (
            where status = 'FAILED'
              and started_at >= statement_timestamp() - interval '48 hours'
          )::integer as recent_failed_runs,
          max(completed_at) filter (where status = 'FAILED')
            as latest_failed_at,
          (array_agg(result_code order by started_at desc)
             filter (where status = 'FAILED'))[1]
            as latest_failed_result_code,
          (array_agg(error_code order by started_at desc)
             filter (where status = 'FAILED'))[1]
            as latest_failed_error_code
        from public.interest_accrual_runs
        """,
        application="phase-2e-scheduler-application-run-health",
    )
    if int(row["unfinished_runs"]) != 0:
        raise HarnessFailure("an unfinished application interest run exists")
    return row


def fixture_labels(run_uuid: uuid.UUID) -> dict[str, str]:
    marker = run_uuid.hex[:12].upper()
    suffix = run_uuid.int % 1_000_000_000_000
    return {
        "run_id": marker,
        "display_name": f"DEVELOPMENT HOSTED SCHEDULER {marker} - NOT REAL",
        "phone": f"+999{suffix:012d}",
        "source_reference": f"P2E-SCHED-{marker}",
    }


def find_fixture(
    factory: ConnectionFactory, labels: dict[str, str]
) -> dict[str, Any] | None:
    rows = query_all(
        factory,
        """
        select
          customer.id as customer_id,
          account.id as credit_account_id,
          settings.credit_limit_paise,
          settings.default_annual_interest_rate,
          settings.grace_days,
          settings.grace_policy::text,
          transaction.id as fuel_transaction_id,
          transaction.amount_paise as principal_paise,
          transaction.occurred_at as fuel_posted_at,
          transaction.business_date as source_business_date,
          sale.source_reference
        from public.customers as customer
        join public.credit_accounts as account
          on account.customer_id = customer.id
         and account.organization_id = customer.organization_id
        join public.customer_account_settings as settings
          on settings.customer_id = customer.id
         and settings.organization_id = customer.organization_id
        left join public.fuel_credit_sales as sale
          on sale.credit_account_id = account.id
         and sale.source_reference = %s
        left join public.ledger_transactions as transaction
          on transaction.id = sale.transaction_id
        where customer.organization_id = %s
          and customer.home_station_id = %s
          and customer.display_name = %s
          and customer.phone = %s
        """,
        (
            labels["source_reference"],
            EXPECTED_ORGANIZATION_ID,
            EXPECTED_STATION_ID,
            labels["display_name"],
            labels["phone"],
        ),
        application="phase-2e-scheduler-find-fixture",
    )
    if not rows:
        return None
    if len(rows) != 1 or rows[0]["fuel_transaction_id"] is None:
        raise HarnessFailure("scheduler fixture is duplicated or only partially present")
    return rows[0]


def create_fixture(
    factory: ConnectionFactory,
    identities: dict[str, str],
    run_uuid: uuid.UUID,
    labels: dict[str, str],
) -> dict[str, Any]:
    existing = find_fixture(factory, labels)
    if existing is not None:
        return existing

    account_request_id = uuid.uuid5(run_uuid, "scheduler-account")
    fuel_idempotency_key = uuid.uuid5(run_uuid, "scheduler-fuel")

    def operation(cur: psycopg.Cursor[Any]) -> None:
        set_authenticated(cur, identities["owner-a"])
        cur.execute(
            """
            select customer_id, credit_account_id
            from public.create_customer_with_credit_account(
              %s, 'Scheduler', %s, %s, %s, null, null,
              %s, %s, %s, %s, 30, %s
            )
            """,
            (
                EXPECTED_STATION_ID,
                labels["run_id"],
                labels["phone"],
                labels["display_name"],
                CREDIT_LIMIT_PAISE,
                ANNUAL_RATE,
                GRACE_DAYS,
                GRACE_POLICY,
                account_request_id,
            ),
        )
        account = cur.fetchone()
        if account is None:
            raise HarnessFailure("trusted account creation returned no row")
        cur.execute(
            """
            select transaction_id, amount_paise,
                   outstanding_principal_paise, available_credit_paise,
                   idempotent_replay
            from public.post_fuel_credit_transaction(%s, %s, %s, %s, %s, %s)
            """,
            (
                account["credit_account_id"],
                EXPECTED_STATION_ID,
                EXPECTED_PRODUCT_ID,
                PRINCIPAL_PAISE,
                fuel_idempotency_key,
                labels["source_reference"],
            ),
        )
        posted = cur.fetchone()
        if posted is None:
            raise HarnessFailure("trusted fuel posting returned no row")
        if (
            int(posted["amount_paise"]) != PRINCIPAL_PAISE
            or int(posted["outstanding_principal_paise"]) != PRINCIPAL_PAISE
            or int(posted["available_credit_paise"])
               != CREDIT_LIMIT_PAISE - PRINCIPAL_PAISE
            or bool(posted["idempotent_replay"])
        ):
            raise HarnessFailure("trusted fuel posting returned unexpected balances")

    execute_transaction(
        factory, operation, application="phase-2e-scheduler-prepare-fixture"
    )
    created = find_fixture(factory, labels)
    if created is None:
        raise HarnessFailure("committed scheduler fixture could not be rediscovered")
    return created


def station_clock(factory: ConnectionFactory) -> dict[str, Any]:
    return query_one(
        factory,
        """
        select
          statement_timestamp() as hosted_now,
          station.time_zone_name,
          statement_timestamp() at time zone station.time_zone_name
            as station_local_timestamp,
          (statement_timestamp() at time zone station.time_zone_name)::date
            as station_local_date
        from public.stations as station where station.id = %s
        """,
        (EXPECTED_STATION_ID,),
        application="phase-2e-scheduler-station-clock",
    )


def calculate_window(source_business_date: date) -> dict[str, datetime]:
    # Asia/Kolkata has no DST.  The committed station and preflight both guard
    # this assumption, while hosted cron.timezone is separately fixed to GMT.
    eligible_at = datetime.combine(
        source_business_date + timedelta(days=1),
        time.min,
        tzinfo=timezone(timedelta(hours=5, minutes=30)),
    ).astimezone(timezone.utc)
    first_hour = eligible_at.replace(minute=7, second=0, microsecond=0)
    if first_hour <= eligible_at:
        first_hour += timedelta(hours=1)
    return {
        "eligible_at_utc": eligible_at,
        "first_natural_cron_at_utc": first_hour,
        "safe_deadline_utc": first_hour - timedelta(minutes=2),
    }


def fixture_snapshot(
    factory: ConnectionFactory,
    fixture: dict[str, Any],
    target_business_date: date,
) -> dict[str, Any]:
    account_id = fixture["credit_account_id"]
    row = query_one(
        factory,
        """
        with balances as (
          select * from app_private.calculate_credit_account_balance(%s)
        ), financial as (
          select
            coalesce(sum(
              case when entry.direction = 'DEBIT' then entry.amount_paise
                   else -entry.amount_paise end
            ) filter (
              where transaction.status = 'POSTED'
                and entry.account_code = 'CUSTOMER_INTEREST_RECEIVABLE'
            ), 0)::bigint as interest_due_paise
          from public.ledger_transactions as transaction
          left join public.ledger_entries as entry
            on entry.transaction_id = transaction.id
           and entry.organization_id = transaction.organization_id
          where transaction.credit_account_id = %s
        )
        select
          balances.credit_limit_paise,
          balances.outstanding_principal_paise,
          financial.interest_due_paise,
          balances.outstanding_principal_paise
            + financial.interest_due_paise as total_due_paise,
          balances.available_credit_paise,
          (select count(*)::integer from public.interest_accruals
           where credit_account_id = %s and business_date = %s)
            as accrual_count,
          (select count(distinct run_id)::integer
           from public.interest_accruals
           where credit_account_id = %s and business_date = %s)
            as accrual_run_count,
          (select count(*)::integer from public.interest_accrual_components
           where credit_account_id = %s and interest_business_date = %s)
            as component_count,
          (select count(*)::integer from public.ledger_transactions
           where credit_account_id = %s and transaction_type = 'INTEREST_CHARGE'
             and business_date = %s) as interest_transaction_count,
          (select count(*)::integer from public.ledger_entries as entry
           join public.ledger_transactions as transaction
             on transaction.id = entry.transaction_id
           where transaction.credit_account_id = %s
             and transaction.transaction_type = 'INTEREST_CHARGE'
             and transaction.business_date = %s) as interest_entry_count,
          (select count(*)::integer from public.audit_events as audit
           where audit.action = 'interest.accrued'
             and audit.after_state->>'credit_account_id' = %s::text
             and audit.after_state->>'business_date' = %s::text)
            as interest_audit_count,
          (select count(*)::integer from public.audit_events as audit
           where audit.after_state->>'credit_account_id' = %s::text
             and audit.action in (
               'customer.credit_account.created',
               'fuel_credit.posted',
               'interest.accrued'
             )) as fixture_gate_audit_count
        from balances cross join financial
        """,
        (
            account_id,
            account_id,
            account_id,
            target_business_date,
            account_id,
            target_business_date,
            account_id,
            target_business_date,
            account_id,
            target_business_date,
            account_id,
            target_business_date,
            account_id,
            target_business_date,
            account_id,
        ),
        application="phase-2e-scheduler-fixture-snapshot",
    )
    return row


def expected_database_interest(
    factory: ConnectionFactory,
    fixture: dict[str, Any],
    target_business_date: date,
) -> dict[str, Any]:
    row = query_one(
        factory,
        """
        select
          coalesce(sum(source_remaining_principal_paise), 0)::bigint
            as eligible_principal_paise,
          coalesce(sum(raw_interest_paise), 0)::numeric(38,18)
            as raw_interest_paise,
          count(*)::integer as component_count,
          min(annual_rate)::numeric(9,8) as annual_rate,
          min(grace_days)::integer as grace_days,
          min(grace_policy::text) as grace_policy,
          min(day_count_basis)::integer as day_count_basis
        from app_private.calculate_interest_components(%s, %s)
        """,
        (fixture["credit_account_id"], target_business_date),
        application="phase-2e-scheduler-expected-interest",
    )
    expected = expected_calculation()
    if (
        int(row["eligible_principal_paise"]) != PRINCIPAL_PAISE
        or Decimal(row["raw_interest_paise"]) != expected["raw_interest_paise"]
        or int(row["component_count"]) != 1
        or Decimal(row["annual_rate"]) != ANNUAL_RATE
        or int(row["grace_days"]) != GRACE_DAYS
        or row["grace_policy"] != GRACE_POLICY
        or int(row["day_count_basis"]) != DAY_COUNT_BASIS
    ):
        raise CriticalSchedulerFailure("database interest expectation did not match")
    return row


def assert_pre_cycle(
    snapshot: dict[str, Any], fixture: dict[str, Any]
) -> None:
    if (
        int(fixture["credit_limit_paise"]) != CREDIT_LIMIT_PAISE
        or Decimal(fixture["default_annual_interest_rate"]) != ANNUAL_RATE
        or int(fixture["grace_days"]) != GRACE_DAYS
        or fixture["grace_policy"] != GRACE_POLICY
        or int(fixture["principal_paise"]) != PRINCIPAL_PAISE
        or int(snapshot["outstanding_principal_paise"]) != PRINCIPAL_PAISE
        or int(snapshot["interest_due_paise"]) != 0
        or int(snapshot["total_due_paise"]) != PRINCIPAL_PAISE
        or int(snapshot["available_credit_paise"])
           != CREDIT_LIMIT_PAISE - PRINCIPAL_PAISE
        or any(
            int(snapshot[name]) != 0
            for name in (
                "accrual_count",
                "accrual_run_count",
                "component_count",
                "interest_transaction_count",
                "interest_entry_count",
                "interest_audit_count",
            )
        )
        or int(snapshot["fixture_gate_audit_count"]) != 2
    ):
        raise CriticalSchedulerFailure("pre-cycle fixture state is not empty")


def assert_execution_window(
    factory: ConnectionFactory,
    source_business_date: date,
) -> dict[str, Any]:
    clock = station_clock(factory)
    window = calculate_window(source_business_date)
    hosted_now = clock["hosted_now"]
    target_date = source_business_date + timedelta(days=1)
    if clock["station_local_date"] != target_date:
        raise TimingGate(
            "execute only on the next Asia/Kolkata date after fixture posting"
        )
    if not (
        window["eligible_at_utc"]
        <= hosted_now
        < window["safe_deadline_utc"]
    ):
        raise TimingGate(
            "execute only after India-local midnight and at least two minutes "
            "before the first natural cron firing"
        )
    overlap = query_one(
        factory,
        """
        select count(*)::integer as natural_runs_after_eligibility
        from cron.job_run_details
        where jobid = (select jobid from cron.job where jobname = %s)
          and start_time >= %s
        """,
        (CRON_JOB_NAME, window["eligible_at_utc"]),
        application="phase-2e-scheduler-window-history-guard",
    )
    if int(overlap["natural_runs_after_eligibility"]) != 0:
        raise TimingGate("a natural cron run already entered this fixture date")
    return {"clock": clock, "window": window}


def natural_fixture_consumption(
    factory: ConnectionFactory,
    state: dict[str, Any],
) -> dict[str, Any]:
    """Prove that pg_cron, rather than a controlled call, consumed a fixture."""
    if (
        state.get("phase") != "prepared"
        or int(state.get("controlled_calls_completed", -1)) != 0
    ):
        raise HarnessFailure("natural-consumption recovery requires a zero-call fixture")

    fixture = hydrate_fixture(factory, state)
    target_date = date.fromisoformat(str(state["target_business_date"]))
    if target_date != fixture["source_business_date"]:
        raise HarnessFailure("natural-consumption target date drifted")

    snapshot = fixture_snapshot(factory, fixture, target_date)
    if (
        int(snapshot["outstanding_principal_paise"]) != PRINCIPAL_PAISE
        or int(snapshot["interest_due_paise"]) < EXPECTED_POSTED_INTEREST
        or int(snapshot["total_due_paise"])
           != PRINCIPAL_PAISE + int(snapshot["interest_due_paise"])
        or int(snapshot["available_credit_paise"])
           != CREDIT_LIMIT_PAISE - PRINCIPAL_PAISE
        or int(snapshot["accrual_count"]) != 1
        or int(snapshot["accrual_run_count"]) != 1
        or int(snapshot["component_count"]) != 1
        or int(snapshot["interest_transaction_count"]) != 1
        or int(snapshot["interest_entry_count"]) != 2
        or int(snapshot["interest_audit_count"]) != 1
        or int(snapshot["fixture_gate_audit_count"]) < 3
    ):
        raise CriticalSchedulerFailure(
            "stale fixture was not consumed in the expected append-only shape"
        )

    evidence = interest_evidence(factory, fixture, target_date)
    correlation = query_one(
        factory,
        """
        select
          run.requested_at,
          history.runid::bigint as cron_run_id,
          history.jobid::bigint as cron_job_id,
          history.database as cron_database,
          history.username as cron_username,
          history.status as cron_status,
          case
            when history.return_message = '1 row' then 'one_row'
            when history.return_message is null then null
            else 'other_sanitized_result'
          end as cron_result_category,
          history.start_time as cron_start_time,
          history.end_time as cron_end_time
        from public.interest_accruals as accrual
        join public.interest_accrual_runs as run on run.id = accrual.run_id
        join cron.job_run_details as history
          on history.jobid = (
            select jobid from cron.job where jobname = %s
          )
         and run.requested_at >= history.start_time - interval '1 second'
         and run.requested_at <= coalesce(history.end_time, history.start_time)
                                  + interval '1 second'
        where accrual.credit_account_id = %s
          and accrual.business_date = %s
        """,
        (CRON_JOB_NAME, fixture["credit_account_id"], target_date),
        application="phase-2e-scheduler-natural-fixture-correlation",
    )
    if (
        correlation["cron_database"] != "postgres"
        or correlation["cron_username"] != "postgres"
        or correlation["cron_status"] != "succeeded"
        or correlation["cron_result_category"] != "one_row"
        or correlation["cron_start_time"] is None
        or correlation["cron_end_time"] is None
    ):
        raise CriticalSchedulerFailure(
            "fixture application evidence does not correlate to a healthy cron run"
        )

    runs = query_all(
        factory,
        """
        select id, station_id, request_id, requested_at,
               station_local_date, latest_completed_business_date,
               first_business_date, last_business_date,
               max_catch_up_days, accounts_examined,
               account_days_processed, accrual_rows_created,
               components_created, interest_posted_paise,
               more_dates_pending, status::text, result_code
        from public.interest_accrual_runs
        where trigger_source = 'SCHEDULER'
          and requested_at = %s
        order by station_id
        """,
        (correlation["requested_at"],),
        application="phase-2e-scheduler-natural-fixture-runs",
    )
    natural_cycle = {
        "invocation_at": correlation["requested_at"],
        "runs": runs,
    }
    assert_first_cycle(natural_cycle, fixture, target_date, evidence)
    return {
        "prior_run_id": state["run_id"],
        "controlled_calls_completed": 0,
        "fixture": fixture,
        "target_business_date": target_date,
        "current_fixture_snapshot": snapshot,
        "natural_cycle": natural_cycle,
        "interest_evidence": evidence,
        "cron_correlation": correlation,
    }


def invoke_controlled_cycle(
    factory: ConnectionFactory,
    *,
    application: str,
) -> dict[str, Any]:
    def operation(cur: psycopg.Cursor[Any]) -> dict[str, Any]:
        cur.execute(
            """
            select statement_timestamp() as invocation_at,
                   app_private.run_hourly_interest_accrual() as safe_void_result
            """
        )
        invocation = cur.fetchone()
        if invocation is None:
            raise CriticalSchedulerFailure("controlled cycle returned no statement row")
        cur.execute(
            """
            select id, station_id, request_id, requested_at,
                   station_local_date, latest_completed_business_date,
                   first_business_date, last_business_date,
                   max_catch_up_days, accounts_examined,
                   account_days_processed, accrual_rows_created,
                   components_created, interest_posted_paise,
                   more_dates_pending, status::text, result_code
            from public.interest_accrual_runs
            where trigger_source = 'SCHEDULER'
              and requested_at = %s
            order by station_id
            """,
            (invocation["invocation_at"],),
        )
        runs = [dict(row) for row in cur.fetchall()]
        if len(runs) != EXPECTED_ACTIVE_STATION_COUNT:
            raise CriticalSchedulerFailure(
                "controlled cycle did not create one run per active station"
            )
        if any(
            run["status"] not in {"COMPLETED", "COMPLETED_WITH_REMAINING"}
            or int(run["max_catch_up_days"]) != 31
            for run in runs
        ):
            raise CriticalSchedulerFailure("controlled cycle did not finish cleanly")
        return {"invocation_at": invocation["invocation_at"], "runs": runs}

    return execute_transaction(factory, operation, application=application)


def interest_evidence(
    factory: ConnectionFactory,
    fixture: dict[str, Any],
    target_business_date: date,
) -> dict[str, Any]:
    account_id = fixture["credit_account_id"]
    row = query_one(
        factory,
        """
        select
          accrual.id as interest_accrual_id,
          accrual.run_id,
          accrual.organization_id,
          accrual.station_id,
          accrual.credit_account_id,
          accrual.customer_id,
          accrual.active_policy_id,
          accrual.business_date,
          accrual.annual_rate,
          accrual.grace_days,
          accrual.grace_policy::text,
          accrual.day_count_basis,
          accrual.eligible_principal_paise,
          accrual.raw_interest_paise,
          accrual.opening_fractional_carry_paise,
          accrual.posted_interest_paise,
          accrual.closing_fractional_carry_paise,
          accrual.cumulative_raw_interest_paise,
          accrual.cumulative_posted_interest_paise,
          accrual.component_count,
          accrual.daily_component_count,
          accrual.retroactive_component_count,
          accrual.ledger_transaction_id,
          run.trigger_source::text,
          run.status::text as run_status,
          transaction.transaction_type::text,
          transaction.status::text as transaction_status,
          transaction.amount_paise as transaction_amount_paise,
          transaction.business_date as transaction_business_date,
          transaction.created_by as transaction_created_by,
          (select count(*)::integer from public.ledger_entries as entry
           where entry.transaction_id = transaction.id) as ledger_entry_count,
          (select coalesce(sum(entry.amount_paise)
                    filter (where entry.direction = 'DEBIT'), 0)::bigint
           from public.ledger_entries as entry
           where entry.transaction_id = transaction.id) as debit_paise,
          (select coalesce(sum(entry.amount_paise)
                    filter (where entry.direction = 'CREDIT'), 0)::bigint
           from public.ledger_entries as entry
           where entry.transaction_id = transaction.id) as credit_paise,
          (select count(*)::integer from public.ledger_entries as entry
           where entry.transaction_id = transaction.id
             and entry.account_code = 'CUSTOMER_INTEREST_RECEIVABLE'
             and entry.direction = 'DEBIT'
             and entry.amount_paise = accrual.posted_interest_paise)
            as expected_debit_count,
          (select count(*)::integer from public.ledger_entries as entry
           where entry.transaction_id = transaction.id
             and entry.account_code = 'INTEREST_INCOME'
             and entry.direction = 'CREDIT'
             and entry.amount_paise = accrual.posted_interest_paise)
            as expected_credit_count,
          (select count(*)::integer from public.audit_events as audit
           where audit.entity_id = accrual.id
             and audit.action = 'interest.accrued'
             and audit.request_id = run.request_id) as interest_audit_count
        from public.interest_accruals as accrual
        join public.interest_accrual_runs as run on run.id = accrual.run_id
        left join public.ledger_transactions as transaction
          on transaction.id = accrual.ledger_transaction_id
        where accrual.credit_account_id = %s
          and accrual.business_date = %s
          and accrual.calculation_version = 1
        """,
        (account_id, target_business_date),
        application="phase-2e-scheduler-interest-evidence",
    )
    components = query_all(
        factory,
        """
        select component_kind::text, source_transaction_id,
               organization_id, station_id, credit_account_id, customer_id,
               source_business_date, eligibility_business_date,
               interest_business_date, accrual_business_date,
               source_remaining_principal_paise, raw_interest_paise,
               source_policy_id, rate_policy_id,
               annual_rate, grace_days, grace_policy::text, interest_enabled,
               day_count_basis, calculation_version
        from public.interest_accrual_components
        where credit_account_id = %s and interest_business_date = %s
        order by source_transaction_id, component_kind
        """,
        (account_id, target_business_date),
        application="phase-2e-scheduler-component-evidence",
    )
    row["components"] = components
    return row


def assert_first_cycle(
    first: dict[str, Any],
    fixture: dict[str, Any],
    target_business_date: date,
    evidence: dict[str, Any],
) -> None:
    primary_runs = [
        run for run in first["runs"] if run["station_id"] == uuid.UUID(EXPECTED_STATION_ID)
    ]
    component = evidence["components"][0] if len(evidence["components"]) == 1 else {}
    if (
        any(
            run["status"] != "COMPLETED"
            or bool(run["more_dates_pending"])
            for run in first["runs"]
        )
        or len(primary_runs) != 1
        or evidence["run_id"] != primary_runs[0]["id"]
        or evidence["business_date"] != target_business_date
        or evidence["trigger_source"] != "SCHEDULER"
        or evidence["run_status"] != "COMPLETED"
        or evidence["organization_id"] != uuid.UUID(EXPECTED_ORGANIZATION_ID)
        or evidence["station_id"] != uuid.UUID(EXPECTED_STATION_ID)
        or evidence["credit_account_id"] != fixture["credit_account_id"]
        or evidence["customer_id"] != fixture["customer_id"]
        or int(evidence["eligible_principal_paise"]) != PRINCIPAL_PAISE
        or Decimal(evidence["raw_interest_paise"]) != EXPECTED_RAW_INTEREST
        or Decimal(evidence["opening_fractional_carry_paise"]) != Decimal(0)
        or int(evidence["posted_interest_paise"]) != EXPECTED_POSTED_INTEREST
        or Decimal(evidence["closing_fractional_carry_paise"])
           != EXPECTED_CLOSING_CARRY
        or Decimal(evidence["cumulative_raw_interest_paise"])
           != EXPECTED_RAW_INTEREST
        or int(evidence["cumulative_posted_interest_paise"])
           != EXPECTED_POSTED_INTEREST
        or int(evidence["component_count"]) != 1
        or int(evidence["daily_component_count"]) != 1
        or int(evidence["retroactive_component_count"]) != 0
        or evidence["transaction_type"] != "INTEREST_CHARGE"
        or evidence["transaction_status"] != "POSTED"
        or int(evidence["transaction_amount_paise"]) != EXPECTED_POSTED_INTEREST
        or evidence["transaction_business_date"] != target_business_date
        or evidence["transaction_created_by"] is not None
        or int(evidence["ledger_entry_count"]) != 2
        or int(evidence["debit_paise"]) != EXPECTED_POSTED_INTEREST
        or int(evidence["credit_paise"]) != EXPECTED_POSTED_INTEREST
        or int(evidence["expected_debit_count"]) != 1
        or int(evidence["expected_credit_count"]) != 1
        or int(evidence["interest_audit_count"]) != 1
        or component.get("component_kind") != "DAILY"
        or component.get("source_transaction_id") != fixture["fuel_transaction_id"]
        or component.get("organization_id") != uuid.UUID(EXPECTED_ORGANIZATION_ID)
        or component.get("station_id") != uuid.UUID(EXPECTED_STATION_ID)
        or component.get("credit_account_id") != fixture["credit_account_id"]
        or component.get("customer_id") != fixture["customer_id"]
        or component.get("source_business_date") != fixture["source_business_date"]
        or component.get("eligibility_business_date") != fixture["source_business_date"]
        or component.get("interest_business_date") != target_business_date
        or int(component.get("source_remaining_principal_paise", -1))
           != PRINCIPAL_PAISE
        or Decimal(component.get("raw_interest_paise", -1))
           != EXPECTED_RAW_INTEREST
        or component.get("source_policy_id") != evidence["active_policy_id"]
        or component.get("rate_policy_id") != evidence["active_policy_id"]
        or Decimal(component.get("annual_rate", -1)) != ANNUAL_RATE
        or int(component.get("grace_days", -1)) != GRACE_DAYS
        or component.get("grace_policy") != GRACE_POLICY
        or component.get("interest_enabled") is not True
        or int(component.get("day_count_basis", -1)) != DAY_COUNT_BASIS
        or int(component.get("calculation_version", -1)) != 1
    ):
        raise CriticalSchedulerFailure("first controlled cycle reconciliation failed")


def assert_second_cycle(
    second: dict[str, Any],
    first_evidence: dict[str, Any],
    second_evidence: dict[str, Any],
) -> None:
    if any(
        int(run["account_days_processed"]) != 0
        or int(run["accrual_rows_created"]) != 0
        or int(run["components_created"]) != 0
        or int(run["interest_posted_paise"]) != 0
        or bool(run["more_dates_pending"])
        for run in second["runs"]
    ):
        raise CriticalSchedulerFailure("immediate rerun was not globally zero-work")
    immutable_fields = (
        "interest_accrual_id",
        "run_id",
        "raw_interest_paise",
        "posted_interest_paise",
        "closing_fractional_carry_paise",
        "cumulative_raw_interest_paise",
        "cumulative_posted_interest_paise",
        "ledger_transaction_id",
        "ledger_entry_count",
        "interest_audit_count",
    )
    if any(first_evidence[field] != second_evidence[field] for field in immutable_fields):
        raise CriticalSchedulerFailure("immediate rerun changed fixture evidence")


def security_snapshot(factory: ConnectionFactory) -> dict[str, Any]:
    row = query_one(
        factory,
        """
        select
          has_function_privilege('authenticated',
            'app_private.run_hourly_interest_accrual()', 'execute')
            as authenticated_engine_execute,
          has_function_privilege('anon',
            'app_private.run_hourly_interest_accrual()', 'execute')
            as anon_engine_execute,
          has_function_privilege('service_role',
            'app_private.run_hourly_interest_accrual()', 'execute')
            as service_role_engine_execute,
          has_schema_privilege('authenticated', 'app_private', 'usage')
            as authenticated_app_private_usage,
          has_schema_privilege('anon', 'app_private', 'usage')
            as anon_app_private_usage,
          has_schema_privilege('service_role', 'app_private', 'usage')
            as service_role_app_private_usage,
          has_schema_privilege('authenticator', 'app_private', 'usage')
            as authenticator_app_private_usage,
          has_schema_privilege('authenticated', 'cron', 'usage')
            as authenticated_cron_usage,
          has_schema_privilege('anon', 'cron', 'usage') as anon_cron_usage,
          has_schema_privilege('service_role', 'cron', 'usage')
            as service_role_cron_usage,
          has_schema_privilege('authenticator', 'cron', 'usage')
            as authenticator_cron_usage
        """,
        application="phase-2e-scheduler-security",
    )
    # Authenticated intentionally has schema USAGE for RLS helper functions
    # (migration 20260724162946), but the private engine itself remains revoked
    # and the schema remains outside the Data API.  Every other checked access
    # path must remain false.
    if row.pop("authenticated_app_private_usage") is not True:
        raise HarnessFailure("authenticated RLS-helper schema usage drifted")
    enabled = sorted(name for name, value in row.items() if bool(value))
    if enabled:
        raise HarnessFailure(
            "private scheduler or cron privilege drifted: " + ", ".join(enabled)
        )
    row["authenticated_app_private_usage"] = True
    return row


def global_reconciliation(
    factory: ConnectionFactory,
    fixture: dict[str, Any],
    first_cycle: dict[str, Any],
) -> dict[str, Any]:
    run_ids = [run["id"] for run in first_cycle["runs"]]
    rows = query_all(
        factory,
        """
        with gate_transaction_ids as (
          select %s::uuid as id
          union
          select accrual.ledger_transaction_id
          from public.interest_accruals as accrual
          where accrual.run_id = any(%s::uuid[])
            and accrual.ledger_transaction_id is not null
        )
        select transaction.id, transaction.transaction_type::text,
               count(entry.id)::integer as entry_count,
               coalesce(sum(entry.amount_paise)
                 filter (where entry.direction = 'DEBIT'), 0)::bigint
                 as debit_paise,
               coalesce(sum(entry.amount_paise)
                 filter (where entry.direction = 'CREDIT'), 0)::bigint
                 as credit_paise
        from public.ledger_transactions as transaction
        join gate_transaction_ids as gate on gate.id = transaction.id
        left join public.ledger_entries as entry
          on entry.transaction_id = transaction.id
        group by transaction.id, transaction.transaction_type
        order by transaction.transaction_type
        """,
        (fixture["fuel_transaction_id"], run_ids),
        application="phase-2e-scheduler-global-reconciliation",
    )
    if (
        not rows
        or sum(row["transaction_type"] == "FUEL_CREDIT" for row in rows) != 1
        or any(
            int(row["entry_count"]) != 2
            or int(row["debit_paise"]) != int(row["credit_paise"])
            or int(row["debit_paise"]) <= 0
            for row in rows
        )
    ):
        raise CriticalSchedulerFailure("gate ledger transactions are not balanced")
    global_unbalanced = query_one(
        factory,
        """
        select count(*)::integer as unbalanced_transactions
        from (
          select transaction.id
          from public.ledger_transactions as transaction
          left join public.ledger_entries as entry
            on entry.transaction_id = transaction.id
          group by transaction.id
          having coalesce(sum(entry.amount_paise)
                   filter (where entry.direction = 'DEBIT'), 0)
              <> coalesce(sum(entry.amount_paise)
                   filter (where entry.direction = 'CREDIT'), 0)
        ) as unbalanced
        """,
        application="phase-2e-scheduler-global-balance",
    )
    if int(global_unbalanced["unbalanced_transactions"]) != 0:
        raise CriticalSchedulerFailure("hosted ledger has an unbalanced transaction")
    return {"gate_transactions": rows, **global_unbalanced}


def validate_fixture_shape(fixture: dict[str, Any]) -> None:
    required = {
        "customer_id",
        "credit_account_id",
        "fuel_transaction_id",
        "source_business_date",
    }
    if not required.issubset(fixture):
        raise HarnessFailure("scheduler state is missing fixture identifiers")
    for name in ("customer_id", "credit_account_id", "fuel_transaction_id"):
        uuid.UUID(str(fixture[name]))


def hydrate_fixture(
    factory: ConnectionFactory,
    state: dict[str, Any],
) -> dict[str, Any]:
    stored = dict(state.get("fixture") or {})
    validate_fixture_shape(stored)
    labels = fixture_labels(uuid.UUID(str(state["run_uuid"])))
    remote = find_fixture(factory, labels)
    if remote is None:
        raise HarnessFailure("stored scheduler fixture is missing remotely")
    for field in (
        "customer_id",
        "credit_account_id",
        "fuel_transaction_id",
        "source_business_date",
        "principal_paise",
    ):
        if str(remote[field]) != str(stored[field]):
            raise HarnessFailure(f"remote scheduler fixture drifted at {field}")
    return remote


def cycle_scope(
    factory: ConnectionFactory,
    cycle: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, Any]:
    run_ids = [run["id"] for run in cycle["runs"]]
    row = query_one(
        factory,
        """
        select
          count(*)::integer as accrual_count,
          count(*) filter (where accrual.credit_account_id = %s)::integer
            as fixture_accrual_count,
          count(*) filter (where accrual.posted_interest_paise > 0)::integer
            as positive_accrual_count,
          count(*) filter (
            where accrual.posted_interest_paise > 0
              and accrual.ledger_transaction_id is null
          )::integer as missing_ledger_link_count,
          count(*) filter (
            where accrual.organization_id <> run.organization_id
               or accrual.station_id <> run.station_id
               or accrual.business_date > run.latest_completed_business_date
          )::integer as out_of_scope_accrual_count,
          coalesce(sum(accrual.posted_interest_paise), 0)::bigint
            as posted_interest_paise,
          (select count(*)::integer
           from public.interest_accrual_components as component
           join public.interest_accruals as linked
             on linked.id = component.interest_accrual_id
           where linked.run_id = any(%s::uuid[])) as component_count,
          (select count(*)::integer
           from public.ledger_transactions as transaction
           join public.interest_accruals as linked
             on linked.ledger_transaction_id = transaction.id
           where linked.run_id = any(%s::uuid[]))
            as interest_transaction_count,
          (select count(*)::integer
           from public.audit_events as audit
           join public.interest_accruals as linked
             on linked.id = audit.entity_id
           where linked.run_id = any(%s::uuid[])
             and audit.action = 'interest.accrued') as interest_audit_count
        from public.interest_accruals as accrual
        join public.interest_accrual_runs as run on run.id = accrual.run_id
        where accrual.run_id = any(%s::uuid[])
        """,
        (
            fixture["credit_account_id"],
            run_ids,
            run_ids,
            run_ids,
            run_ids,
        ),
        application="phase-2e-scheduler-cycle-scope",
    )
    expected_accruals = sum(int(run["accrual_rows_created"]) for run in cycle["runs"])
    expected_components = sum(int(run["components_created"]) for run in cycle["runs"])
    expected_interest = sum(int(run["interest_posted_paise"]) for run in cycle["runs"])
    if (
        int(row["accrual_count"]) != expected_accruals
        or int(row["component_count"]) != expected_components
        or int(row["posted_interest_paise"]) != expected_interest
        or int(row["out_of_scope_accrual_count"]) != 0
        or int(row["missing_ledger_link_count"]) != 0
        or int(row["interest_transaction_count"])
           != int(row["positive_accrual_count"])
        or int(row["interest_audit_count"])
           != int(row["positive_accrual_count"])
    ):
        raise CriticalSchedulerFailure("controlled cycle touched unexpected scope")
    row["non_fixture_accrual_count"] = (
        int(row["accrual_count"]) - int(row["fixture_accrual_count"])
    )
    return row


def prepare_mode(
    factory: ConnectionFactory,
    identities: dict[str, str],
    state: dict[str, Any] | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if state is None:
        run_uuid = uuid.uuid4()
        labels = fixture_labels(run_uuid)
        state = {
            "project_ref": EXPECTED_PROJECT_REF,
            "run_uuid": str(run_uuid),
            "run_id": labels["run_id"],
            "phase": "preparing",
            "created_utc": utc_now(),
            "controlled_calls_completed": 0,
        }
        write_json_atomic(STATE_PATH, state)
    else:
        phase = state.get("phase")
        if phase not in {"preparing", "prepared"}:
            raise HarnessFailure(f"prepare refused from state phase {phase!r}")
        run_uuid = uuid.UUID(str(state["run_uuid"]))
        labels = fixture_labels(run_uuid)
        if state.get("run_id") != labels["run_id"]:
            raise HarnessFailure("scheduler state run marker drifted")

    fixture = create_fixture(factory, identities, run_uuid, labels)
    source_date = fixture["source_business_date"]
    target_date = source_date
    baseline = fixture_snapshot(factory, fixture, target_date)
    assert_pre_cycle(baseline, fixture)
    clock = station_clock(factory)
    if source_date != clock["station_local_date"]:
        raise TimingGate("new fixture did not land on the current India-local date")
    window = calculate_window(source_date)
    state.update(
        {
            "phase": "prepared",
            "prepared_utc": utc_now(),
            "fixture": fixture,
            "target_business_date": str(source_date),
            "window": window,
        }
    )
    write_json_atomic(STATE_PATH, state)
    return state, {
        "run_id": state["run_id"],
        "fixture": fixture,
        "baseline": baseline,
        "window": window,
        "cycle_invocations": 0,
    }


def rollover_mode(
    factory: ConnectionFactory,
    identities: dict[str, str],
    state: dict[str, Any] | None,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    """Archive a naturally consumed fixture, then prepare one replacement."""
    if (
        required_environment("PHASE_2E_SCHEDULER_ROLLOVER_APPROVAL")
        != ROLLOVER_APPROVAL
    ):
        raise HarnessFailure("the exact natural-consumption rollover sentinel is required")
    if state is None:
        raise HarnessFailure("rollover requires an existing prepared fixture")

    consumed = natural_fixture_consumption(factory, state)
    archive = {
        "status": "CONSUMED_BY_NATURAL_CRON",
        "classification": "deterministic synthetic development data only",
        "project_ref": EXPECTED_PROJECT_REF,
        "prior_state": state,
        "evidence": consumed,
        "archived_utc": utc_now(),
    }
    archive_path = EVIDENCE_DIR / (
        f"phase-2e-scheduler-natural-consumption-{state['run_id']}.json"
    )
    write_json_atomic(archive_path, archive)

    replacement_state, prepared = prepare_mode(factory, identities, None)
    prepared["replaces_natural_consumed_run_id"] = state["run_id"]
    return replacement_state, prepared, archive


def execute_mode(
    factory: ConnectionFactory,
    identities: dict[str, str],
    token: str,
    state: dict[str, Any] | None,
    cron_before: dict[str, Any],
    history_before: dict[str, Any],
    run_health_before: dict[str, Any],
) -> dict[str, Any]:
    if required_environment("PHASE_2E_SCHEDULER_TWO_CALL_APPROVAL") != EXECUTION_APPROVAL:
        raise HarnessFailure("the exact two-call execution sentinel is required")
    if state is None or state.get("phase") != "prepared":
        phase = None if state is None else state.get("phase")
        raise HarnessFailure(f"execute refused from state phase {phase!r}")
    if int(state.get("controlled_calls_completed", -1)) != 0:
        raise HarnessFailure("execute requires zero prior controlled calls")
    fixture = hydrate_fixture(factory, state)
    target_date = date.fromisoformat(str(state["target_business_date"]))
    if target_date != fixture["source_business_date"]:
        raise HarnessFailure("fixture target date drifted")

    timing = assert_execution_window(factory, target_date)
    baseline = fixture_snapshot(factory, fixture, target_date)
    assert_pre_cycle(baseline, fixture)
    database_expected = expected_database_interest(factory, fixture, target_date)

    state["phase"] = "first_call_started"
    state["first_call_started_utc"] = utc_now()
    write_json_atomic(STATE_PATH, state)
    first = invoke_controlled_cycle(
        factory, application="phase-2e-scheduler-controlled-call-one"
    )
    state["phase"] = "first_call_completed"
    state["controlled_calls_completed"] = 1
    state["first_call"] = first
    write_json_atomic(STATE_PATH, state)

    first_evidence = interest_evidence(factory, fixture, target_date)
    assert_first_cycle(first, fixture, target_date, first_evidence)
    first_scope = cycle_scope(factory, first, fixture)
    if int(first_scope["fixture_accrual_count"]) != 1:
        raise CriticalSchedulerFailure("first cycle did not include the fixture once")
    after_first = fixture_snapshot(factory, fixture, target_date)

    # Do not spend the approved idempotency call if call one approached the
    # natural pg_cron boundary or if a wall-clock job started meanwhile.
    second_call_timing = assert_execution_window(factory, target_date)

    state["phase"] = "second_call_started"
    state["second_call_started_utc"] = utc_now()
    write_json_atomic(STATE_PATH, state)
    second = invoke_controlled_cycle(
        factory, application="phase-2e-scheduler-controlled-call-two"
    )
    state["phase"] = "second_call_completed"
    state["controlled_calls_completed"] = 2
    state["second_call"] = second
    write_json_atomic(STATE_PATH, state)

    second_evidence = interest_evidence(factory, fixture, target_date)
    assert_second_cycle(second, first_evidence, second_evidence)
    second_scope = cycle_scope(factory, second, fixture)
    if int(second_scope["accrual_count"]) != 0:
        raise CriticalSchedulerFailure("second cycle created new accrual scope")
    final = fixture_snapshot(factory, fixture, target_date)
    if (
        int(final["outstanding_principal_paise"]) != PRINCIPAL_PAISE
        or int(final["interest_due_paise"]) != EXPECTED_POSTED_INTEREST
        or int(final["total_due_paise"])
           != PRINCIPAL_PAISE + EXPECTED_POSTED_INTEREST
        or int(final["available_credit_paise"])
           != CREDIT_LIMIT_PAISE - PRINCIPAL_PAISE
        or int(final["accrual_count"]) != 1
        or int(final["accrual_run_count"]) != 1
        or int(final["component_count"]) != 1
        or int(final["interest_transaction_count"]) != 1
        or int(final["interest_entry_count"]) != 2
        or int(final["interest_audit_count"]) != 1
        or int(final["fixture_gate_audit_count"]) != 3
    ):
        raise CriticalSchedulerFailure("final fixture balances or counts drifted")

    ledger = global_reconciliation(factory, fixture, first)
    management_after = management_preflight(token)
    database_after = database_preflight(factory, identities, phase="post-scheduler")
    security = security_snapshot(factory)
    cron_after = cron_registration(factory)
    if cron_after != cron_before:
        raise HarnessFailure("cron registration changed during controlled validation")
    history_after = natural_cron_history(factory)
    run_health_after = application_run_health(factory)

    state["phase"] = "completed"
    state["completed_utc"] = utc_now()
    write_json_atomic(STATE_PATH, state)
    return {
        "status": "PASS",
        "project": {
            "ref": EXPECTED_PROJECT_REF,
            "name": EXPECTED_PROJECT_NAME,
            "region": EXPECTED_REGION,
            "migration_count": EXPECTED_MIGRATION_COUNT,
            "data_api_schemas": sorted(EXPECTED_DATA_API_SCHEMAS),
        },
        "run_id": state["run_id"],
        "classification": "deterministic synthetic development data only",
        "timing": timing,
        "fixture": fixture,
        "expected": expected_calculation(),
        "database_expected": database_expected,
        "pre_cycle": baseline,
        "first_controlled_cycle": first,
        "first_cycle_scope": first_scope,
        "after_first": after_first,
        "interest_evidence": first_evidence,
        "second_controlled_cycle": second,
        "second_call_timing": second_call_timing,
        "second_cycle_scope": second_scope,
        "final": final,
        "ledger": ledger,
        "controlled_calls_completed": 2,
        "cron_mutations": 0,
        "cron_before": cron_before,
        "cron_after": cron_after,
        "natural_history_before": history_before,
        "natural_history_after": history_after,
        "application_run_health_before": run_health_before,
        "application_run_health_after": run_health_after,
        "post_verification": {
            "management": management_after,
            "database": database_after,
            "security": security,
        },
        "completed_utc": utc_now(),
    }


def verify_mode(
    factory: ConnectionFactory,
    identities: dict[str, str],
    token: str,
    state: dict[str, Any] | None,
) -> dict[str, Any]:
    report: dict[str, Any] = {
        "management": management_preflight(token),
        "database": database_preflight(factory, identities, phase="scheduler-verify"),
        "cron": cron_registration(factory),
        "natural_history": natural_cron_history(factory),
        "application_run_health": application_run_health(factory),
        "security": security_snapshot(factory),
        "state_phase": None if state is None else state.get("phase"),
        "cycle_invocations": 0,
    }
    if state is not None and state.get("phase") in {"prepared", "completed"}:
        fixture = hydrate_fixture(factory, state)
        target_date = date.fromisoformat(str(state["target_business_date"]))
        snapshot = fixture_snapshot(factory, fixture, target_date)
        report["fixture"] = snapshot
        if state.get("phase") == "prepared":
            if int(snapshot["accrual_count"]) == 0:
                assert_pre_cycle(snapshot, fixture)
                empty_cycle = {"runs": []}
                report["prepared_scope_self_check"] = cycle_scope(
                    factory, empty_cycle, fixture
                )
                report["prepared_ledger_reconciliation"] = global_reconciliation(
                    factory, fixture, empty_cycle
                )
            else:
                report["natural_fixture_consumption"] = natural_fixture_consumption(
                    factory, state
                )
        if state.get("phase") == "completed":
            report["interest_evidence"] = interest_evidence(
                factory, fixture, target_date
            )
    elif state is not None and state.get("phase") not in {"preparing"}:
        raise HarnessFailure(
            "read-only verification found an ambiguous controlled-call state"
        )
    return report


def main() -> int:
    mode = os.environ.get("PHASE_2E_SCHEDULER_MODE", "preflight").strip().lower()
    if mode not in VALID_MODES:
        print(f"FAIL: invalid scheduler harness mode {mode!r}", file=sys.stderr)
        return 1
    token = ""
    password = ""
    stage = "startup"
    try:
        stage = "target validation"
        host, database, port = validate_target_environment()
        identities = load_fake_identities()
        token = required_environment("SUPABASE_ACCESS_TOKEN")
        stage = "management preflight"
        management = management_preflight(token)
        stage = "temporary login"
        # Supabase's read-only CLI login role cannot assume postgres.  Use the
        # same short-lived admin role as the approved concurrency harness; all
        # inspection helpers still open explicit BEGIN READ ONLY transactions.
        role, password, ttl_seconds = temporary_login(token, read_only=False)
        factory = ConnectionFactory(
            host=host,
            database=database,
            port=port,
            role=role,
            password=password,
        )
        stage = "database preflight"
        database_state = database_preflight(factory, identities, phase="scheduler")
        stage = "cron and natural-history preflight"
        cron_before = cron_registration(factory)
        history_before = natural_cron_history(factory)
        run_health_before = application_run_health(factory)
        active_station_snapshot(factory)
        state = load_state()

        if mode == "preflight":
            print(
                "PASS: scheduler validation preflight only; "
                "no fixture or cycle was created"
            )
            return 0

        if mode == "prepare":
            stage = "fixture preparation"
            state, prepared = prepare_mode(factory, identities, state)
            evidence_path = EVIDENCE_DIR / (
                f"phase-2e-scheduler-prepared-{state['run_id']}.json"
            )
            report = {
                "status": "PREPARED",
                "management": management,
                "database": database_state,
                "cron": cron_before,
                "natural_history": history_before,
                "application_run_health": run_health_before,
                "connection_credential_ttl_seconds": ttl_seconds,
                **prepared,
            }
            write_json_atomic(evidence_path, report)
            print(
                "PASS: scheduler fixture prepared through trusted posting; "
                f"run_id={state['run_id']}; cycle_invocations=0"
            )
            print(
                "WAIT: execute after the next Asia/Kolkata midnight and before "
                "the guarded natural-cron deadline"
            )
            return 0

        if mode == "rollover":
            stage = "natural-consumption rollover"
            prior_run_id = None if state is None else state.get("run_id")
            state, prepared, archive = rollover_mode(factory, identities, state)
            report = {
                "status": "PREPARED_AFTER_NATURAL_CONSUMPTION",
                "management": management,
                "database": database_state,
                "cron": cron_before,
                "natural_history": history_before,
                "application_run_health": run_health_before,
                "connection_credential_ttl_seconds": ttl_seconds,
                "prior_natural_consumption": archive,
                **prepared,
            }
            evidence_path = EVIDENCE_DIR / (
                f"phase-2e-scheduler-prepared-{state['run_id']}.json"
            )
            write_json_atomic(evidence_path, report)
            print(
                "PASS: naturally consumed fixture archived and replacement "
                f"prepared; prior_run_id={prior_run_id}; "
                f"run_id={state['run_id']}; cycle_invocations=0"
            )
            print(
                "WAIT: execute after the next Asia/Kolkata midnight and before "
                "the guarded natural-cron deadline"
            )
            return 0

        if mode == "execute":
            stage = "controlled two-call execution"
            report = execute_mode(
                factory,
                identities,
                token,
                state,
                cron_before,
                history_before,
                run_health_before,
            )
            evidence_path = EVIDENCE_DIR / (
                f"phase-2e-scheduler-validation-{report['run_id']}.json"
            )
            write_json_atomic(evidence_path, report)
            print(
                "PASS: controlled scheduler interest validation reconciled; "
                f"run_id={report['run_id']}; controlled_calls=2"
            )
            return 0

        stage = "read-only verification"
        report = verify_mode(factory, identities, token, state)
        print(
            "PASS: scheduler validation read-only verification; "
            f"state_phase={report['state_phase']}; cycle_invocations=0"
        )
        return 0
    except TimingGate as exc:
        print(f"WAIT: scheduler timing gate: {exc}", file=sys.stderr)
        return 5
    except CriticalSchedulerFailure as exc:
        print(f"FAIL: critical scheduler blocker: {exc}", file=sys.stderr)
        return 2
    except InfrastructureFailure as exc:
        print(f"FAIL: scheduler infrastructure: {exc}", file=sys.stderr)
        return 3
    except psycopg.Error as exc:
        print(
            "FAIL: scheduler database error: "
            f"stage={stage}; sqlstate={exc.sqlstate or 'none'}",
            file=sys.stderr,
        )
        return 4
    except (HarnessFailure, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"FAIL: scheduler validation: stage={stage}; {exc}", file=sys.stderr)
        return 1
    finally:
        token = ""
        password = ""


if __name__ == "__main__":
    raise SystemExit(main())
