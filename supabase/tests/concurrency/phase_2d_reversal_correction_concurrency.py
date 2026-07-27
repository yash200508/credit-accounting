#!/usr/bin/env python3
"""Prove correction execution serializes with approvals and financial posting."""

from __future__ import annotations

import re
import subprocess
import sys
import time
import uuid
from datetime import date, timedelta
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
CONFIG = ROOT / "supabase" / "config.toml"
OWNER_A = "10000000-0000-0000-0000-000000000001"
OWNER_CHECKER = "10000000-0000-0000-0000-000000000010"
MANAGER = "10000000-0000-0000-0000-000000000003"
ORGANIZATION_ID = "a0000000-0000-0000-0000-000000000001"
STATION_ID = "a1000000-0000-0000-0000-000000000001"
PRODUCT_ID = "af100000-0000-0000-0000-000000000001"
UUID_PATTERN = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"
)


class HarnessFailure(RuntimeError):
    """A deterministic concurrency assertion failed."""


def run(command: list[str], *, timeout: int = 45) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=timeout,
    )


def project_id() -> str:
    config_text = CONFIG.read_text(encoding="utf-8")
    match = re.search(r'^project_id\s*=\s*"([^"]+)"', config_text, re.MULTILINE)
    if not match:
        raise HarnessFailure("project_id is missing from supabase/config.toml")
    return match.group(1)


def database_container() -> str:
    result = run(
        [
            "docker",
            "ps",
            "--filter",
            f"label=com.supabase.cli.project={project_id()}",
            "--format",
            "{{.Names}}",
        ]
    )
    if result.returncode != 0:
        raise HarnessFailure(f"docker ps failed: {result.stderr.strip()}")
    candidates = [
        name.strip()
        for name in result.stdout.splitlines()
        if name.strip().startswith("supabase_db_")
    ]
    if len(candidates) != 1:
        raise HarnessFailure(
            f"expected one local database container, found {candidates}"
        )
    return candidates[0]


def psql_command(container: str, sql: str) -> list[str]:
    return [
        "docker",
        "exec",
        "-i",
        container,
        "psql",
        "-X",
        "-qAt",
        "-v",
        "ON_ERROR_STOP=1",
        "-U",
        "postgres",
        "-d",
        "postgres",
        "-c",
        sql,
    ]


def authenticated_sql(actor_id: str, body: str) -> str:
    return f"""
begin;
set local role authenticated;
set local request.jwt.claim.sub = '{actor_id}';
set local request.jwt.claim.role = 'authenticated';
{body}
commit;
"""


def execute(container: str, sql: str, purpose: str) -> str:
    result = run(psql_command(container, sql))
    if result.returncode != 0:
        raise HarnessFailure(f"{purpose} failed: {result.stderr.strip()}")
    return result.stdout


def final_line(output: str) -> str:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if not lines:
        raise HarnessFailure("expected command output but received none")
    return lines[-1]


def create_account(
    container: str,
    run_id: uuid.UUID,
    label: str,
    credit_limit_paise: int,
) -> str:
    suffix = str((run_id.int + sum(map(ord, label))) % 100_000_000_000).zfill(11)
    output = execute(
        container,
        authenticated_sql(
            OWNER_A,
            f"""
select credit_account_id
from public.create_customer_with_credit_account(
  '{STATION_ID}',
  'CorrectionRace',
  '{label}',
  '+1777{suffix}',
  null,
  null,
  null,
  {credit_limit_paise},
  0.18000000,
  0,
  'AFTER_GRACE_ONLY',
  30,
  '{uuid.uuid4()}'
);
""",
        ),
        f"{label} account creation",
    )
    ids = UUID_PATTERN.findall(output)
    if len(ids) != 1:
        raise HarnessFailure(f"could not identify {label} account: {output!r}")
    return ids[0]


def post_fuel(
    container: str,
    account_id: str,
    amount_paise: int,
    reference: str,
) -> str:
    output = execute(
        container,
        authenticated_sql(
            OWNER_A,
            f"""
select transaction_id
from public.post_fuel_credit_transaction(
  '{account_id}',
  '{STATION_ID}',
  '{PRODUCT_ID}',
  {amount_paise},
  '{uuid.uuid4()}',
  '{reference}'
);
""",
        ),
        f"{reference} fuel posting",
    )
    ids = UUID_PATTERN.findall(output)
    if len(ids) != 1:
        raise HarnessFailure(f"could not identify {reference} transaction: {output!r}")
    return ids[0]


def post_repayment(
    container: str,
    account_id: str,
    amount_paise: int,
    reference: str,
) -> str:
    output = execute(
        container,
        authenticated_sql(
            OWNER_A,
            f"""
select transaction_id
from public.post_customer_repayment(
  '{account_id}',
  '{STATION_ID}',
  {amount_paise},
  'PRINCIPAL_ONLY',
  '{uuid.uuid4()}',
  {amount_paise},
  0,
  null,
  '{reference}',
  'CASH'
);
""",
        ),
        f"{reference} repayment posting",
    )
    ids = UUID_PATTERN.findall(output)
    if len(ids) != 1:
        raise HarnessFailure(f"could not identify {reference} repayment: {output!r}")
    return ids[0]


def submit_reversal(
    container: str,
    transaction_id: str,
    *,
    replacement_amount_paise: int | None = None,
) -> str:
    if replacement_amount_paise is None:
        proposal = "null,null,null,null,null,null,null,null,null,null"
        action = "REVERSAL_ONLY"
    else:
        proposal = (
            f"'{PRODUCT_ID}',{replacement_amount_paise},"
            "'phase2d-concurrent-replacement',"
            "null,null,null,null,null,null,null"
        )
        action = "REVERSE_AND_REPLACE"
    output = execute(
        container,
        authenticated_sql(
            MANAGER,
            f"""
select request_id
from public.submit_financial_correction_request(
  '{transaction_id}',
  '{action}',
  'OPERATIONAL_ERROR',
  'Concurrent harness correction request with independent review.',
  '{uuid.uuid4()}',
  {proposal}
);
""",
        ),
        "correction request submission",
    )
    ids = UUID_PATTERN.findall(output)
    if len(ids) != 1:
        raise HarnessFailure(f"could not identify correction request: {output!r}")
    return ids[0]


def run_concurrently(
    container: str,
    session_a_sql: str,
    session_b_sql: str,
) -> tuple[tuple[int, str, str], tuple[int, str, str]]:
    session_a = subprocess.Popen(
        psql_command(container, session_a_sql),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    time.sleep(0.75)
    session_b = subprocess.Popen(
        psql_command(container, session_b_sql),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    try:
        stdout_a, stderr_a = session_a.communicate(timeout=40)
        stdout_b, stderr_b = session_b.communicate(timeout=40)
    except subprocess.TimeoutExpired as error:
        session_a.kill()
        session_b.kill()
        raise HarnessFailure("concurrent correction sessions timed out") from error
    return (
        (session_a.returncode, stdout_a, stderr_a),
        (session_b.returncode, stdout_b, stderr_b),
    )


def assert_success(session: tuple[int, str, str], marker: str, scenario: str) -> None:
    returncode, stdout, stderr = session
    if returncode != 0 or marker not in stdout:
        raise HarnessFailure(
            f"{scenario} failed: stdout={stdout.strip()!r} stderr={stderr.strip()!r}"
        )


def assert_error(session: tuple[int, str, str], code: str, scenario: str) -> None:
    returncode, stdout, stderr = session
    if returncode == 0 or code not in stderr:
        raise HarnessFailure(
            f"{scenario} did not fail with {code}: "
            f"stdout={stdout.strip()!r} stderr={stderr.strip()!r}"
        )


def prove_two_approvals(container: str, run_id: uuid.UUID) -> None:
    account_id = create_account(container, run_id, "DoubleApproval", 500_000)
    original_id = post_fuel(container, account_id, 100_000, "cor-race-double")
    request_id = submit_reversal(
        container,
        original_id,
        replacement_amount_paise=120_000,
    )
    session_a_sql = authenticated_sql(
        OWNER_A,
        f"""
select 'APPROVAL_A|' || idempotent_replay::text
from public.approve_and_execute_financial_correction('{request_id}', 1);
select pg_sleep(3);
""",
    )
    session_b_sql = authenticated_sql(
        OWNER_CHECKER,
        f"""
select 'APPROVAL_B|' || idempotent_replay::text
from public.approve_and_execute_financial_correction('{request_id}', 1);
""",
    )
    session_a, session_b = run_concurrently(
        container,
        session_a_sql,
        session_b_sql,
    )
    assert_success(session_a, "APPROVAL_A|false", "winning approval")
    assert_success(session_b, "APPROVAL_B|true", "losing approval replay")

    actual = final_line(
        execute(
            container,
            f"""
select concat_ws(
  '|',
  (select count(*) from public.financial_reversals
   where request_id = '{request_id}'),
  (select count(*) from public.financial_reversals
   where request_id = '{request_id}'
     and replacement_transaction_id is not null),
  (select count(*) from public.financial_correction_events
   where request_id = '{request_id}'
     and event_type = 'APPROVED_AND_EXECUTED'),
  (select count(*) from public.ledger_transactions
   where id = '{original_id}' and amount_paise = 100000),
  obligations.outstanding_principal_paise,
  obligations.available_credit_paise
)
from app_private.calculate_credit_account_obligations('{account_id}') obligations;
""",
            "double approval validation",
        )
    )
    expected = "1|1|1|1|120000|380000"
    if actual != expected:
        raise HarnessFailure(
            f"double approval invariants mismatch: expected {expected!r}, got {actual!r}"
        )


def prove_reversal_vs_fuel(container: str, run_id: uuid.UUID) -> None:
    account_id = create_account(container, run_id, "FuelRace", 100_000)
    post_fuel(container, account_id, 100_000, "cor-race-limit-base")
    repayment_id = post_repayment(
        container,
        account_id,
        100_000,
        "cor-race-limit-payment",
    )
    request_id = submit_reversal(container, repayment_id)
    fuel_key = uuid.uuid4()
    reversal_sql = authenticated_sql(
        OWNER_CHECKER,
        f"""
select 'REPAYMENT_REVERSAL|' || idempotent_replay::text
from public.approve_and_execute_financial_correction('{request_id}', 1);
select pg_sleep(3);
""",
    )
    fuel_sql = authenticated_sql(
        OWNER_A,
        f"""
select 'FUEL_RACE|' || transaction_id::text
from public.post_fuel_credit_transaction(
  '{account_id}',
  '{STATION_ID}',
  '{PRODUCT_ID}',
  50000,
  '{fuel_key}',
  'cor-race-after-reversal'
);
""",
    )
    reversal, fuel = run_concurrently(container, reversal_sql, fuel_sql)
    assert_success(reversal, "REPAYMENT_REVERSAL|false", "repayment reversal")
    assert_error(fuel, "FCP_INSUFFICIENT_CREDIT", "fuel after reversal")

    actual = final_line(
        execute(
            container,
            f"""
select concat_ws(
  '|',
  (select count(*) from public.financial_reversals
   where request_id = '{request_id}'),
  (select count(*) from public.idempotency_keys
   where idempotency_key = '{fuel_key}'),
  obligations.outstanding_principal_paise,
  obligations.available_credit_paise
)
from app_private.calculate_credit_account_obligations('{account_id}') obligations;
""",
            "reversal-versus-fuel validation",
        )
    )
    expected = "1|0|100000|0"
    if actual != expected:
        raise HarnessFailure(
            f"reversal-versus-fuel mismatch: expected {expected!r}, got {actual!r}"
        )


def create_interest_run(container: str, business_date: date) -> str:
    run_id = str(uuid.uuid4())
    execute(
        container,
        f"""
insert into public.interest_accrual_runs (
  id, organization_id, station_id, trigger_source, request_id,
  requested_at, station_time_zone_name, station_local_date,
  latest_completed_business_date, max_catch_up_days, status
)
values (
  '{run_id}', '{ORGANIZATION_ID}', '{STATION_ID}', 'TEST', '{uuid.uuid4()}',
  (
    ('{business_date.isoformat()}'::date + 1)::timestamp
      + interval '12 hours'
  ) at time zone 'Asia/Kolkata',
  'Asia/Kolkata', '{(business_date + timedelta(days=1)).isoformat()}',
  '{business_date.isoformat()}', 3660, 'STARTED'
);
""",
        "interest run creation",
    )
    return run_id


def station_local_date(container: str) -> date:
    output = execute(
        container,
        f"""
select (statement_timestamp() at time zone time_zone_name)::date
from public.stations where id = '{STATION_ID}';
""",
        "station date lookup",
    )
    return date.fromisoformat(final_line(output))


def prove_reversal_vs_interest(
    container: str,
    run_id: uuid.UUID,
    local_date: date,
) -> None:
    account_id = create_account(container, run_id, "InterestRace", 500_000)
    original_id = post_fuel(container, account_id, 200_000, "cor-race-interest")
    request_id = submit_reversal(container, original_id)
    interest_run_id = create_interest_run(container, local_date)
    reversal_sql = authenticated_sql(
        OWNER_CHECKER,
        f"""
select 'FUEL_REVERSAL|' || idempotent_replay::text
from public.approve_and_execute_financial_correction('{request_id}', 1);
select pg_sleep(3);
""",
    )
    accrual_sql = f"""
begin;
select 'INTEREST_AFTER_REVERSAL|' || was_created::text
from app_private.post_interest_for_account_date(
  '{interest_run_id}', '{account_id}', '{local_date.isoformat()}'
);
commit;
"""
    reversal, accrual = run_concurrently(container, reversal_sql, accrual_sql)
    assert_success(reversal, "FUEL_REVERSAL|false", "fuel reversal")
    assert_success(
        accrual,
        "INTEREST_AFTER_REVERSAL|true",
        "interest after reversal",
    )

    actual = final_line(
        execute(
            container,
            f"""
select concat_ws(
  '|',
  (select count(*) from public.financial_reversals
   where request_id = '{request_id}'),
  (select count(*) from public.interest_accruals
   where credit_account_id = '{account_id}'),
  (select coalesce(sum(component_count), 0)
   from public.interest_accruals
   where credit_account_id = '{account_id}'),
  (select coalesce(sum(posted_interest_paise), 0)
   from public.interest_accruals
   where credit_account_id = '{account_id}'),
  obligations.outstanding_principal_paise,
  obligations.outstanding_interest_paise
)
from app_private.calculate_credit_account_obligations('{account_id}') obligations;
""",
            "reversal-versus-interest validation",
        )
    )
    expected = "1|1|0|0|0|0"
    if actual != expected:
        raise HarnessFailure(
            f"reversal-versus-interest mismatch: expected {expected!r}, got {actual!r}"
        )


def prove_approval_vs_cancellation(
    container: str,
    run_id: uuid.UUID,
) -> None:
    account_id = create_account(container, run_id, "CancelRace", 500_000)
    original_id = post_fuel(container, account_id, 90_000, "cor-race-cancel")
    request_id = submit_reversal(container, original_id)
    approval_sql = authenticated_sql(
        OWNER_A,
        f"""
select 'APPROVAL_WINS|' || idempotent_replay::text
from public.approve_and_execute_financial_correction('{request_id}', 1);
select pg_sleep(3);
""",
    )
    cancellation_sql = authenticated_sql(
        MANAGER,
        f"""
select 'CANCEL|' || status::text
from public.cancel_financial_correction_request(
  '{request_id}', 1, 'Concurrent cancellation loses to committed approval.'
);
""",
    )
    approval, cancellation = run_concurrently(
        container,
        approval_sql,
        cancellation_sql,
    )
    assert_success(approval, "APPROVAL_WINS|false", "approval/cancel winner")
    assert_error(
        cancellation,
        "COR_REQUEST_NOT_PENDING",
        "approval/cancel loser",
    )
    actual = final_line(
        execute(
            container,
            f"""
select concat_ws(
  '|',
  status,
  (select count(*) from public.financial_reversals
   where request_id = '{request_id}'),
  (select count(*) from public.financial_correction_events
   where request_id = '{request_id}' and event_type = 'CANCELLED'),
  (select count(*) from public.financial_correction_events
   where request_id = '{request_id}'
     and event_type = 'APPROVED_AND_EXECUTED')
)
from public.financial_correction_requests where id = '{request_id}';
""",
            "approval-versus-cancellation validation",
        )
    )
    expected = "APPROVED_AND_EXECUTED|1|0|1"
    if actual != expected:
        raise HarnessFailure(
            f"approval/cancel mismatch: expected {expected!r}, got {actual!r}"
        )


def main() -> int:
    container = database_container()
    run_id = uuid.uuid4()
    local_date = station_local_date(container)
    prove_two_approvals(container, run_id)
    prove_reversal_vs_fuel(container, run_id)
    prove_reversal_vs_interest(container, run_id, local_date)
    prove_approval_vs_cancellation(container, run_id)
    print(
        "PASS: two independent owners approved one reverse-and-replace request; "
        "one execution and one safe replay produced exactly one reversal, one "
        "replacement, and one approval-success event."
    )
    print(
        "PASS: repayment reversal serialized ahead of a new fuel purchase; "
        "the purchase failed safely at the credit limit with no partial rows."
    )
    print(
        "PASS: fuel reversal serialized ahead of interest accrual; the waiting "
        "calculation saw no principal lot and posted zero interest."
    )
    print(
        "PASS: approval serialized ahead of requester cancellation; exactly "
        "one terminal state and one financial effect remained."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (HarnessFailure, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
