#!/usr/bin/env python3
"""Prove interest accrual serializes with itself, repayment, and fuel posting."""

from __future__ import annotations

import re
import os
import subprocess
import sys
import time
import uuid
from datetime import date, timedelta
from pathlib import Path

from psql_target import database_target, psql_command as target_psql_command


ROOT = Path(__file__).resolve().parents[3]
CONFIG = ROOT / "supabase" / "config.toml"
OWNER_ID = os.environ.get(
    "PHASE_2E_OWNER_ID", "10000000-0000-0000-0000-000000000001"
)
ORGANIZATION_ID = os.environ.get(
    "PHASE_2E_ORGANIZATION_ID", "a0000000-0000-0000-0000-000000000001"
)
STATION_ID = os.environ.get(
    "PHASE_2E_STATION_ID", "a1000000-0000-0000-0000-000000000001"
)
PRODUCT_ID = os.environ.get(
    "PHASE_2E_PRODUCT_ID", "af100000-0000-0000-0000-000000000001"
)
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


def database_container() -> str | None:
    try:
        return database_target(project_id())
    except RuntimeError as exc:
        raise HarnessFailure(str(exc)) from exc


def psql_command(container: str | None, sql: str) -> list[str]:
    return target_psql_command(container, sql)


def authenticated_sql(body: str) -> str:
    return f"""
begin;
set local role authenticated;
set local request.jwt.claim.sub = '{OWNER_ID}';
set local request.jwt.claim.role = 'authenticated';
{body}
commit;
"""


def execute(container: str, sql: str, purpose: str) -> str:
    result = run(psql_command(container, sql))
    if result.returncode != 0:
        raise HarnessFailure(f"{purpose} failed: {result.stderr.strip()}")
    return result.stdout


def station_local_date(container: str) -> date:
    output = execute(
        container,
        f"""
select (
  statement_timestamp() at time zone station.time_zone_name
)::date
from public.stations as station
where station.id = '{STATION_ID}';
""",
        "station-local date lookup",
    ).strip()
    return date.fromisoformat(output.splitlines()[-1])


def create_account(
    container: str,
    run_id: uuid.UUID,
    label: str,
    credit_limit_paise: int,
) -> tuple[str, str]:
    label_offset = sum(ord(character) for character in label)
    phone_suffix = str((run_id.int + label_offset) % 100_000_000_000).zfill(11)
    output = execute(
        container,
        authenticated_sql(
            f"""
select credit_account_id
from public.create_customer_with_credit_account(
  '{STATION_ID}',
  'InterestRace',
  '{label}',
  '+1666{phone_suffix}',
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
"""
        ),
        f"{label} account creation",
    )
    account_ids = UUID_PATTERN.findall(output)
    if len(account_ids) != 1:
        raise HarnessFailure(
            f"could not identify the {label} credit account: {output.strip()}"
        )
    account_id = account_ids[0]
    customer_id = execute(
        container,
        f"""
select customer_id
from public.credit_accounts
where id = '{account_id}';
""",
        f"{label} customer lookup",
    ).strip().splitlines()[-1]
    return account_id, customer_id


def add_policy_override(
    container: str,
    customer_id: str,
    effective_from: date,
    grace_days: int,
) -> None:
    execute(
        container,
        f"""
insert into public.interest_policies (
  organization_id,
  customer_id,
  annual_rate,
  grace_days,
  grace_policy,
  effective_from,
  is_active,
  interest_enabled,
  day_count_basis,
  created_by,
  updated_by
)
values (
  '{ORGANIZATION_ID}',
  '{customer_id}',
  0.18000000,
  {grace_days},
  'AFTER_GRACE_ONLY',
  '{effective_from.isoformat()}',
  true,
  true,
  365,
  '{OWNER_ID}',
  '{OWNER_ID}'
);
""",
        "interest policy override creation",
    )


def post_historical_fuel(
    container: str,
    transaction_id: uuid.UUID,
    account_id: str,
    customer_id: str,
    business_date: date,
    amount_paise: int,
) -> None:
    execute(
        container,
        f"""
begin;
insert into public.ledger_transactions (
  id,
  organization_id,
  station_id,
  credit_account_id,
  customer_id,
  transaction_type,
  status,
  amount_paise,
  currency_code,
  occurred_at,
  business_date,
  created_by,
  created_at
)
values (
  '{transaction_id}',
  '{ORGANIZATION_ID}',
  '{STATION_ID}',
  '{account_id}',
  '{customer_id}',
  'FUEL_CREDIT',
  'POSTED',
  {amount_paise},
  'INR',
  (
    '{business_date.isoformat()}'::date::timestamp + interval '12 hours'
  ) at time zone 'Asia/Kolkata',
  '{business_date.isoformat()}',
  '{OWNER_ID}',
  statement_timestamp()
);
insert into public.ledger_entries (
  organization_id,
  transaction_id,
  account_code,
  direction,
  amount_paise,
  currency_code
)
values
  (
    '{ORGANIZATION_ID}',
    '{transaction_id}',
    'CUSTOMER_ACCOUNTS_RECEIVABLE',
    'DEBIT',
    {amount_paise},
    'INR'
  ),
  (
    '{ORGANIZATION_ID}',
    '{transaction_id}',
    'FUEL_SALES_REVENUE',
    'CREDIT',
    {amount_paise},
    'INR'
  );
commit;
""",
        "historical fuel fixture",
    )


def create_run(container: str, latest_date: date) -> str:
    run_id = str(uuid.uuid4())
    execute(
        container,
        f"""
insert into public.interest_accrual_runs (
  id,
  organization_id,
  station_id,
  trigger_source,
  request_id,
  requested_at,
  station_time_zone_name,
  station_local_date,
  latest_completed_business_date,
  max_catch_up_days,
  status
)
values (
  '{run_id}',
  '{ORGANIZATION_ID}',
  '{STATION_ID}',
  'TEST',
  '{uuid.uuid4()}',
  (
    ('{latest_date.isoformat()}'::date + 1)::timestamp
      + interval '12 hours'
  ) at time zone 'Asia/Kolkata',
  'Asia/Kolkata',
  '{(latest_date + timedelta(days=1)).isoformat()}',
  '{latest_date.isoformat()}',
  3660,
  'STARTED'
);
""",
        "interest run fixture",
    )
    return run_id


def accrue_dates(
    container: str,
    run_id: str,
    account_id: str,
    first_date: date,
    last_date: date,
) -> None:
    execute(
        container,
        f"""
select posting.*
from generate_series(
  '{first_date.isoformat()}'::date,
  '{last_date.isoformat()}'::date,
  interval '1 day'
) as generated_date
cross join lateral app_private.post_interest_for_account_date(
  '{run_id}',
  '{account_id}',
  generated_date::date
) as posting;
""",
        "prior daily accrual fixture",
    )


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
        raise HarnessFailure(
            "concurrent interest sessions did not finish within 40 seconds"
        ) from error
    return (
        (session_a.returncode, stdout_a, stderr_a),
        (session_b.returncode, stdout_b, stderr_b),
    )


def assert_success(
    session: tuple[int, str, str],
    marker: str,
    scenario: str,
) -> None:
    returncode, stdout, stderr = session
    if returncode != 0 or marker not in stdout:
        raise HarnessFailure(
            f"{scenario} did not commit: "
            f"stdout={stdout.strip()!r} stderr={stderr.strip()!r}"
        )


def prove_duplicate_accrual_race(
    container: str,
    run_id: uuid.UUID,
    local_date: date,
) -> None:
    account_id, customer_id = create_account(
        container,
        run_id,
        "Duplicate",
        200_000,
    )
    source_date = local_date - timedelta(days=1)
    post_historical_fuel(
        container,
        uuid.uuid4(),
        account_id,
        customer_id,
        source_date,
        36_500,
    )
    run_a = create_run(container, source_date)
    run_b = create_run(container, source_date)

    session_a_sql = f"""
begin;
select 'DUPLICATE_A|' || was_created::text
from app_private.post_interest_for_account_date(
  '{run_a}',
  '{account_id}',
  '{source_date.isoformat()}'
);
select pg_sleep(3);
commit;
"""
    session_b_sql = f"""
begin;
select 'DUPLICATE_B|' || was_created::text
from app_private.post_interest_for_account_date(
  '{run_b}',
  '{account_id}',
  '{source_date.isoformat()}'
);
commit;
"""
    session_a, session_b = run_concurrently(
        container,
        session_a_sql,
        session_b_sql,
    )
    assert_success(session_a, "DUPLICATE_A|true", "first duplicate worker")
    assert_success(session_b, "DUPLICATE_B|false", "second duplicate worker")

    actual = execute(
        container,
        f"""
select concat_ws(
  '|',
  (select count(*) from public.interest_accruals
   where credit_account_id = '{account_id}'
     and business_date = '{source_date.isoformat()}'),
  (select count(*) from public.ledger_transactions
   where credit_account_id = '{account_id}'
     and transaction_type = 'INTEREST_CHARGE'),
  (select count(*) from public.ledger_entries as entry
   join public.ledger_transactions as transaction
     on transaction.id = entry.transaction_id
   where transaction.credit_account_id = '{account_id}'
     and transaction.transaction_type = 'INTEREST_CHARGE'),
  (select count(*) from public.audit_events
   where action = 'interest.accrued'
     and after_state->>'credit_account_id' = '{account_id}'),
  obligations.outstanding_principal_paise,
  obligations.outstanding_interest_paise,
  obligations.total_due_paise
)
from app_private.calculate_credit_account_obligations(
  '{account_id}'
) as obligations;
""",
        "duplicate-accrual validation",
    ).strip().splitlines()[-1]
    expected = "1|1|2|1|36500|18|36518"
    if actual != expected:
        raise HarnessFailure(
            "duplicate-accrual invariants mismatch; expected "
            f"{expected!r}, received {actual!r}"
        )


def prove_accrual_repayment_serialization(
    container: str,
    run_id: uuid.UUID,
    local_date: date,
) -> None:
    account_id, customer_id = create_account(
        container,
        run_id,
        "Repayment",
        200_000,
    )
    post_historical_fuel(
        container,
        uuid.uuid4(),
        account_id,
        customer_id,
        local_date,
        100_000,
    )
    accrual_run = create_run(container, local_date)
    repayment_key = uuid.uuid4()

    repayment_sql = authenticated_sql(
        f"""
select 'REPAYMENT|' || transaction_id::text
from public.post_customer_repayment(
  '{account_id}',
  '{STATION_ID}',
  70000,
  'PRINCIPAL_ONLY',
  '{repayment_key}',
  null,
  null,
  null,
  'IAC-RACE-REPAYMENT-{run_id.hex[:12].upper()}'
);
select pg_sleep(3);
"""
    )
    accrual_sql = f"""
begin;
select 'ACCRUAL_AFTER_REPAYMENT|' || was_created::text
from app_private.post_interest_for_account_date(
  '{accrual_run}',
  '{account_id}',
  '{local_date.isoformat()}'
);
commit;
"""
    repayment, accrual = run_concurrently(
        container,
        repayment_sql,
        accrual_sql,
    )
    assert_success(repayment, "REPAYMENT|", "concurrent principal repayment")
    assert_success(
        accrual,
        "ACCRUAL_AFTER_REPAYMENT|true",
        "accrual waiting for repayment",
    )

    actual = execute(
        container,
        f"""
select concat_ws(
  '|',
  accrual.eligible_principal_paise,
  accrual.posted_interest_paise,
  obligations.outstanding_principal_paise,
  obligations.outstanding_interest_paise,
  obligations.total_due_paise,
  obligations.available_credit_paise,
  (select count(*) from public.customer_repayments
   where credit_account_id = '{account_id}'),
  (select count(*) from public.interest_accruals
   where credit_account_id = '{account_id}'),
  (select count(*) from public.ledger_entries as entry
   join public.ledger_transactions as transaction
     on transaction.id = entry.transaction_id
   where transaction.credit_account_id = '{account_id}'
     and transaction.transaction_type = 'INTEREST_CHARGE')
)
from public.interest_accruals as accrual
cross join app_private.calculate_credit_account_obligations(
  '{account_id}'
) as obligations
where accrual.credit_account_id = '{account_id}'
  and accrual.business_date = '{local_date.isoformat()}';
""",
        "accrual-versus-repayment validation",
    ).strip().splitlines()[-1]
    expected = "30000|15|30000|15|30015|170000|1|1|2"
    if actual != expected:
        raise HarnessFailure(
            "accrual-versus-repayment invariants mismatch; expected "
            f"{expected!r}, received {actual!r}"
        )


def prove_accrual_fuel_serialization(
    container: str,
    run_id: uuid.UUID,
    local_date: date,
) -> None:
    account_id, customer_id = create_account(
        container,
        run_id,
        "Fuel",
        300_000,
    )
    source_date = local_date - timedelta(days=5)
    add_policy_override(
        container,
        customer_id,
        source_date - timedelta(days=1),
        3,
    )
    initial_transaction_id = uuid.uuid4()
    post_historical_fuel(
        container,
        initial_transaction_id,
        account_id,
        customer_id,
        source_date,
        50_000,
    )
    prior_run = create_run(container, local_date - timedelta(days=1))
    accrue_dates(
        container,
        prior_run,
        account_id,
        source_date,
        local_date - timedelta(days=1),
    )
    target_run = create_run(container, local_date)
    fuel_key = uuid.uuid4()

    fuel_sql = authenticated_sql(
        f"""
select 'FUEL|' || transaction_id::text
from public.post_fuel_credit_transaction(
  '{account_id}',
  '{STATION_ID}',
  '{PRODUCT_ID}',
  100000,
  '{fuel_key}',
  'IAC-RACE-FUEL-{run_id.hex[12:24].upper()}'
);
select pg_sleep(3);
"""
    )
    accrual_sql = f"""
begin;
select 'ACCRUAL_AFTER_FUEL|' || was_created::text
from app_private.post_interest_for_account_date(
  '{target_run}',
  '{account_id}',
  '{local_date.isoformat()}'
);
commit;
"""
    fuel, accrual = run_concurrently(
        container,
        fuel_sql,
        accrual_sql,
    )
    assert_success(fuel, "FUEL|", "concurrent fuel posting")
    assert_success(
        accrual,
        "ACCRUAL_AFTER_FUEL|true",
        "accrual waiting for fuel",
    )

    actual = execute(
        container,
        f"""
select concat_ws(
  '|',
  accrual.eligible_principal_paise,
  accrual.raw_interest_paise,
  obligations.outstanding_principal_paise,
  obligations.available_credit_paise,
  (select count(*) from public.interest_accrual_components
   where interest_accrual_id = accrual.id),
  (select count(*) from public.interest_accrual_components
   where interest_accrual_id = accrual.id
     and source_business_date = '{local_date.isoformat()}'),
  (select count(*) from public.interest_accruals
   where credit_account_id = '{account_id}'
     and business_date = '{local_date.isoformat()}'),
  (select count(*) from public.ledger_transactions
   where credit_account_id = '{account_id}'
     and transaction_type = 'FUEL_CREDIT')
)
from public.interest_accruals as accrual
cross join app_private.calculate_credit_account_obligations(
  '{account_id}'
) as obligations
where accrual.credit_account_id = '{account_id}'
  and accrual.business_date = '{local_date.isoformat()}';
""",
        "accrual-versus-fuel validation",
    ).strip().splitlines()[-1]
    expected = "50000|24.657534246575342466|150000|150000|1|0|1|2"
    if actual != expected:
        raise HarnessFailure(
            "accrual-versus-fuel invariants mismatch; expected "
            f"{expected!r}, received {actual!r}"
        )


def main() -> int:
    container = database_container()
    run_id = uuid.uuid4()
    local_date = station_local_date(container)
    prove_duplicate_accrual_race(container, run_id, local_date)
    prove_accrual_repayment_serialization(container, run_id, local_date)
    prove_accrual_fuel_serialization(container, run_id, local_date)
    print(
        "PASS: two account/date accrual workers serialized on one account lock; "
        "one created the immutable calculation, ledger charge, and audit event "
        "while the other returned a safe no-op."
    )
    print(
        "PASS: a same-day INR 700 principal repayment committed before accrual; "
        "the waiting calculation used INR 300 closing principal and left no "
        "partial or duplicate financial rows."
    )
    print(
        "PASS: a same-day fuel purchase committed before accrual; the waiting "
        "calculation saw the complete ledger state while excluding the new "
        "purchase until its independent grace threshold."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (HarnessFailure, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
