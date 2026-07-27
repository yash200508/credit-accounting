#!/usr/bin/env python3
"""Prove repayment and fuel-credit posting serialize on one account lock."""

from __future__ import annotations

import re
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

from psql_target import database_target, psql_command as target_psql_command


ROOT = Path(__file__).resolve().parents[3]
CONFIG = ROOT / "supabase" / "config.toml"
OWNER_ID = os.environ.get(
    "PHASE_2E_OWNER_ID", "10000000-0000-0000-0000-000000000001"
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


def run(command: list[str], *, timeout: int = 30) -> subprocess.CompletedProcess[str]:
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


def create_account(
    container: str,
    run_id: uuid.UUID,
    label: str,
    credit_limit_paise: int,
) -> str:
    label_offset = sum(ord(character) for character in label)
    phone_suffix = str((run_id.int + label_offset) % 100_000_000_000).zfill(11)
    output = execute(
        container,
        authenticated_sql(
            f"""
select credit_account_id
from public.create_customer_with_credit_account(
  '{STATION_ID}',
  'Concurrency',
  '{label}',
  '+1888{phone_suffix}',
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
        f"{label} fixture creation",
    )
    account_ids = UUID_PATTERN.findall(output)
    if len(account_ids) != 1:
        raise HarnessFailure(
            f"could not identify the {label} credit account: {output.strip()}"
        )
    return account_ids[0]


def post_initial_principal(
    container: str,
    account_id: str,
    amount_paise: int,
    request_key: uuid.UUID,
    reference: str,
) -> None:
    execute(
        container,
        authenticated_sql(
            f"""
select transaction_id
from public.post_fuel_credit_transaction(
  '{account_id}',
  '{STATION_ID}',
  '{PRODUCT_ID}',
  {amount_paise},
  '{request_key}',
  '{reference}'
);
"""
        ),
        "initial principal posting",
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
        stdout_a, stderr_a = session_a.communicate(timeout=30)
        stdout_b, stderr_b = session_b.communicate(timeout=30)
    except subprocess.TimeoutExpired as error:
        session_a.kill()
        session_b.kill()
        raise HarnessFailure(
            "concurrent sessions did not finish within 30 seconds"
        ) from error
    return (
        (session_a.returncode, stdout_a, stderr_a),
        (session_b.returncode, stdout_b, stderr_b),
    )


def prove_competing_repayments(container: str, run_id: uuid.UUID) -> None:
    account_id = create_account(container, run_id, "Repayment", 200_000)
    initial_key = uuid.uuid4()
    key_a = uuid.uuid4()
    key_b = uuid.uuid4()
    reference_prefix = run_id.hex[:12].upper()
    post_initial_principal(
        container,
        account_id,
        100_000,
        initial_key,
        f"RPP-INITIAL-{reference_prefix}",
    )

    session_a_sql = f"""
begin;
select id
from public.credit_accounts
where id = '{account_id}'
for update;
select pg_sleep(3);
set local role authenticated;
set local request.jwt.claim.sub = '{OWNER_ID}';
set local request.jwt.claim.role = 'authenticated';
select 'SUCCESS_A|' || transaction_id::text
from public.post_customer_repayment(
  '{account_id}',
  '{STATION_ID}',
  70000,
  'PRINCIPAL_ONLY',
  '{key_a}',
  null,
  null,
  null,
  'RPP-A-{reference_prefix}'
);
commit;
"""
    session_b_sql = authenticated_sql(
        f"""
select 'SUCCESS_B|' || transaction_id::text
from public.post_customer_repayment(
  '{account_id}',
  '{STATION_ID}',
  70000,
  'PRINCIPAL_ONLY',
  '{key_b}',
  null,
  null,
  null,
  'RPP-B-{reference_prefix}'
);
"""
    )
    session_a, session_b = run_concurrently(
        container,
        session_a_sql,
        session_b_sql,
    )
    returncode_a, stdout_a, stderr_a = session_a
    returncode_b, stdout_b, stderr_b = session_b
    if returncode_a != 0 or "SUCCESS_A|" not in stdout_a:
        raise HarnessFailure(
            "first repayment did not commit: "
            f"stdout={stdout_a.strip()!r} stderr={stderr_a.strip()!r}"
        )
    if returncode_b == 0:
        raise HarnessFailure(
            "second INR 700 repayment unexpectedly committed: "
            f"stdout={stdout_b.strip()!r}"
        )
    if "RPP_PRINCIPAL_EXCEEDS_DUE" not in f"{stdout_b}\n{stderr_b}":
        raise HarnessFailure(
            "losing repayment did not return RPP_PRINCIPAL_EXCEEDS_DUE: "
            f"stdout={stdout_b.strip()!r} stderr={stderr_b.strip()!r}"
        )

    validation_sql = f"""
select concat_ws(
  '|',
  obligations.credit_limit_paise,
  obligations.outstanding_principal_paise,
  obligations.outstanding_interest_paise,
  obligations.total_due_paise,
  obligations.available_credit_paise,
  (
    select count(*)
    from public.customer_repayments
    where credit_account_id = '{account_id}'
  ),
  (
    select count(*)
    from public.repayment_allocations
    where credit_account_id = '{account_id}'
  ),
  (
    select count(*)
    from public.ledger_transactions
    where credit_account_id = '{account_id}'
      and transaction_type = 'CUSTOMER_REPAYMENT'
  ),
  (
    select count(*)
    from public.ledger_entries as entry
    join public.ledger_transactions as transaction
      on transaction.id = entry.transaction_id
    where transaction.credit_account_id = '{account_id}'
      and transaction.transaction_type = 'CUSTOMER_REPAYMENT'
  ),
  (
    select count(*)
    from public.audit_events
    where request_id in ('{key_a}', '{key_b}')
      and action = 'customer_repayment.posted'
  ),
  (
    select count(*)
    from public.idempotency_keys
    where idempotency_key = '{key_a}'
      and status = 'COMPLETED'
      and response_repayment_id is not null
  ),
  (
    select count(*)
    from public.idempotency_keys
    where idempotency_key = '{key_b}'
  )
)
from app_private.calculate_credit_account_obligations(
  '{account_id}'
) as obligations;
"""
    actual = execute(
        container,
        validation_sql,
        "competing-repayment validation",
    ).strip().splitlines()[-1]
    expected = "200000|30000|0|30000|170000|1|1|1|2|1|1|0"
    if actual != expected:
        raise HarnessFailure(
            "competing-repayment invariant mismatch; expected "
            f"{expected!r}, received {actual!r}"
        )


def prove_fuel_repayment_serialization(container: str, run_id: uuid.UUID) -> None:
    account_id = create_account(container, run_id, "MixedRace", 100_000)
    initial_key = uuid.uuid4()
    repayment_key = uuid.uuid4()
    fuel_key = uuid.uuid4()
    reference_prefix = run_id.hex[12:24].upper()
    post_initial_principal(
        container,
        account_id,
        80_000,
        initial_key,
        f"MIX-INITIAL-{reference_prefix}",
    )

    repayment_sql = f"""
begin;
select id
from public.credit_accounts
where id = '{account_id}'
for update;
select pg_sleep(3);
set local role authenticated;
set local request.jwt.claim.sub = '{OWNER_ID}';
set local request.jwt.claim.role = 'authenticated';
select 'REPAYMENT_SUCCESS|' || transaction_id::text
from public.post_customer_repayment(
  '{account_id}',
  '{STATION_ID}',
  40000,
  'PRINCIPAL_ONLY',
  '{repayment_key}',
  null,
  null,
  null,
  'MIX-RPP-{reference_prefix}'
);
commit;
"""
    fuel_sql = authenticated_sql(
        f"""
select 'FUEL_SUCCESS|' || transaction_id::text
from public.post_fuel_credit_transaction(
  '{account_id}',
  '{STATION_ID}',
  '{PRODUCT_ID}',
  50000,
  '{fuel_key}',
  'MIX-FUEL-{reference_prefix}'
);
"""
    )
    repayment, fuel = run_concurrently(container, repayment_sql, fuel_sql)
    repayment_code, repayment_out, repayment_error = repayment
    fuel_code, fuel_out, fuel_error = fuel
    if repayment_code != 0 or "REPAYMENT_SUCCESS|" not in repayment_out:
        raise HarnessFailure(
            "mixed-race repayment did not commit: "
            f"stdout={repayment_out.strip()!r} stderr={repayment_error.strip()!r}"
        )
    if fuel_code != 0 or "FUEL_SUCCESS|" not in fuel_out:
        raise HarnessFailure(
            "mixed-race fuel posting did not commit after repayment: "
            f"stdout={fuel_out.strip()!r} stderr={fuel_error.strip()!r}"
        )

    validation_sql = f"""
select concat_ws(
  '|',
  obligations.credit_limit_paise,
  obligations.outstanding_principal_paise,
  obligations.outstanding_interest_paise,
  obligations.total_due_paise,
  obligations.available_credit_paise,
  (
    select count(*)
    from public.ledger_transactions
    where credit_account_id = '{account_id}'
      and transaction_type = 'FUEL_CREDIT'
  ),
  (
    select count(*)
    from public.ledger_transactions
    where credit_account_id = '{account_id}'
      and transaction_type = 'CUSTOMER_REPAYMENT'
  ),
  (
    select count(*)
    from public.idempotency_keys
    where idempotency_key in ('{repayment_key}', '{fuel_key}')
      and status = 'COMPLETED'
  )
)
from app_private.calculate_credit_account_obligations(
  '{account_id}'
) as obligations;
"""
    actual = execute(
        container,
        validation_sql,
        "fuel-versus-repayment validation",
    ).strip().splitlines()[-1]
    expected = "100000|90000|0|90000|10000|2|1|2"
    if actual != expected:
        raise HarnessFailure(
            "fuel-versus-repayment invariant mismatch; expected "
            f"{expected!r}, received {actual!r}"
        )


def prove_driver_revocation_serialization(
    container: str,
    run_id: uuid.UUID,
) -> None:
    account_id = create_account(container, run_id, "DriverRace", 100_000)
    driver_id = uuid.uuid4()
    initial_key = uuid.uuid4()
    repayment_key = uuid.uuid4()
    reference_prefix = run_id.hex[20:32].upper()
    phone_suffix = str((run_id.int + 97) % 100_000_000_000).zfill(11)

    create_driver_sql = f"""
with target_account as (
  select customer_id, organization_id
  from public.credit_accounts
  where id = '{account_id}'
)
insert into public.customer_drivers (
  id,
  organization_id,
  customer_id,
  auth_user_id,
  first_name,
  last_name,
  phone,
  status,
  created_by,
  updated_by
)
select
  '{driver_id}',
  target_account.organization_id,
  target_account.customer_id,
  null,
  'Concurrency',
  'Driver',
  '+1777{phone_suffix}',
  'ACTIVE',
  '{OWNER_ID}',
  '{OWNER_ID}'
from target_account;

insert into public.driver_permissions (
  driver_id,
  customer_id,
  organization_id,
  transaction_limit_paise,
  daily_limit_paise,
  valid_from,
  expires_on,
  created_by,
  updated_by
)
select
  driver.id,
  driver.customer_id,
  driver.organization_id,
  null,
  null,
  current_date,
  '2099-12-31',
  '{OWNER_ID}',
  '{OWNER_ID}'
from public.customer_drivers as driver
where driver.id = '{driver_id}';
"""
    execute(container, create_driver_sql, "driver-race fixture creation")
    post_initial_principal(
        container,
        account_id,
        50_000,
        initial_key,
        f"DRV-INITIAL-{reference_prefix}",
    )

    repayment_sql = authenticated_sql(
        f"""
select 'DRIVER_REPAYMENT_SUCCESS|' || transaction_id::text
from public.post_customer_repayment(
  '{account_id}',
  '{STATION_ID}',
  10000,
  'PRINCIPAL_ONLY',
  '{repayment_key}',
  null,
  null,
  '{driver_id}',
  'DRV-RPP-{reference_prefix}'
);
select pg_sleep(3);
select 'STATUS_BEFORE_COMMIT|' || status::text
from public.customer_drivers
where id = '{driver_id}';
"""
    )
    revocation_sql = f"""
begin;
update public.customer_drivers
set
  status = 'REVOKED',
  updated_by = '{OWNER_ID}'
where id = '{driver_id}'
returning 'REVOCATION_SUCCESS|' || status::text;
commit;
"""
    repayment, revocation = run_concurrently(
        container,
        repayment_sql,
        revocation_sql,
    )
    repayment_code, repayment_out, repayment_error = repayment
    revocation_code, revocation_out, revocation_error = revocation
    if (
        repayment_code != 0
        or "DRIVER_REPAYMENT_SUCCESS|" not in repayment_out
        or "STATUS_BEFORE_COMMIT|ACTIVE" not in repayment_out
    ):
        raise HarnessFailure(
            "driver repayment did not retain active attribution through commit: "
            f"stdout={repayment_out.strip()!r} "
            f"stderr={repayment_error.strip()!r}"
        )
    if revocation_code != 0 or "REVOCATION_SUCCESS|REVOKED" not in revocation_out:
        raise HarnessFailure(
            "driver revocation did not commit after the repayment: "
            f"stdout={revocation_out.strip()!r} "
            f"stderr={revocation_error.strip()!r}"
        )

    validation_sql = f"""
select concat_ws(
  '|',
  driver.status,
  repayment.payer_type,
  repayment.payer_driver_id,
  obligations.outstanding_principal_paise,
  obligations.available_credit_paise
)
from public.customer_drivers as driver
join public.customer_repayments as repayment
  on repayment.payer_driver_id = driver.id
cross join app_private.calculate_credit_account_obligations(
  '{account_id}'
) as obligations
where driver.id = '{driver_id}'
  and repayment.credit_account_id = '{account_id}';
"""
    actual = execute(
        container,
        validation_sql,
        "driver-revocation validation",
    ).strip().splitlines()[-1]
    expected = f"REVOKED|DRIVER|{driver_id}|40000|60000"
    if actual != expected:
        raise HarnessFailure(
            "driver-revocation invariant mismatch; expected "
            f"{expected!r}, received {actual!r}"
        )


def main() -> int:
    container = database_container()
    run_id = uuid.uuid4()
    prove_competing_repayments(container, run_id)
    prove_fuel_repayment_serialization(container, run_id)
    prove_driver_revocation_serialization(container, run_id)
    print(
        "PASS: competing INR 700 repayments against INR 1,000 principal "
        "produced one success, one RPP_PRINCIPAL_EXCEEDS_DUE failure, "
        "INR 300 principal, INR 1,700 available credit, and no losing rows."
    )
    print(
        "PASS: a repayment holding the account lock serialized a concurrent "
        "fuel-credit post; both committed in order with INR 900 principal "
        "and INR 100 available credit."
    )
    print(
        "PASS: driver attribution held share locks through commit, so a "
        "concurrent non-key status revocation waited and could not invalidate "
        "the posted repayment mid-transaction."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (HarnessFailure, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
