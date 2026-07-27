#!/usr/bin/env python3
"""Prove that concurrent fuel-credit posts cannot overspend one account."""

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


def main() -> int:
    container = database_container()
    run_id = uuid.uuid4()
    phone_suffix = str(run_id.int % 100_000_000_000).zfill(11)
    phone = f"+1999{phone_suffix}"
    key_a = uuid.uuid4()
    key_b = uuid.uuid4()
    reference_a = f"CONC-A-{run_id.hex[:12].upper()}"
    reference_b = f"CONC-B-{run_id.hex[:12].upper()}"

    create_sql = authenticated_sql(
        f"""
select credit_account_id
from public.create_customer_with_credit_account(
  '{STATION_ID}',
  'Concurrency',
  'Fixture',
  '{phone}',
  null,
  null,
  null,
  100000,
  0.18000000,
  0,
  'AFTER_GRACE_ONLY',
  30,
  '{uuid.uuid4()}'
);
"""
    )
    created = run(psql_command(container, create_sql))
    if created.returncode != 0:
        raise HarnessFailure(f"fixture creation failed: {created.stderr.strip()}")

    account_ids = re.findall(
        r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
        created.stdout,
    )
    if len(account_ids) != 1:
        raise HarnessFailure(
            f"could not identify the new credit account: {created.stdout.strip()}"
        )
    account_id = account_ids[0]

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
from public.post_fuel_credit_transaction(
  '{account_id}',
  '{STATION_ID}',
  '{PRODUCT_ID}',
  70000,
  '{key_a}',
  '{reference_a}'
);
commit;
"""
    session_b_sql = authenticated_sql(
        f"""
select 'SUCCESS_B|' || transaction_id::text
from public.post_fuel_credit_transaction(
  '{account_id}',
  '{STATION_ID}',
  '{PRODUCT_ID}',
  70000,
  '{key_b}',
  '{reference_b}'
);
"""
    )

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
        raise HarnessFailure("concurrent sessions did not finish within 30 seconds") from error

    if session_a.returncode != 0 or "SUCCESS_A|" not in stdout_a:
        raise HarnessFailure(
            "first session did not commit its INR 700 posting: "
            f"stdout={stdout_a.strip()!r} stderr={stderr_a.strip()!r}"
        )
    if session_b.returncode == 0:
        raise HarnessFailure(
            "second INR 700 posting unexpectedly committed: "
            f"stdout={stdout_b.strip()!r}"
        )
    if "FCP_INSUFFICIENT_CREDIT" not in f"{stdout_b}\n{stderr_b}":
        raise HarnessFailure(
            "losing session did not return the stable insufficient-credit error: "
            f"stdout={stdout_b.strip()!r} stderr={stderr_b.strip()!r}"
        )

    validation_sql = f"""
select concat_ws(
  '|',
  balance.credit_limit_paise,
  balance.outstanding_principal_paise,
  balance.available_credit_paise,
  (
    select count(*)
    from public.ledger_transactions
    where credit_account_id = '{account_id}'
  ),
  (
    select count(*)
    from public.ledger_entries as entry
    join public.ledger_transactions as transaction
      on transaction.id = entry.transaction_id
    where transaction.credit_account_id = '{account_id}'
  ),
  (
    select count(*)
    from public.fuel_credit_sales
    where credit_account_id = '{account_id}'
  ),
  (
    select count(*)
    from public.audit_events
    where request_id in ('{key_a}', '{key_b}')
      and action = 'fuel_credit.posted'
  ),
  (
    select count(*)
    from public.idempotency_keys
    where idempotency_key = '{key_a}'
      and status = 'COMPLETED'
  ),
  (
    select count(*)
    from public.idempotency_keys
    where idempotency_key = '{key_b}'
  )
)
from app_private.calculate_credit_account_balance('{account_id}') as balance;
"""
    validated = run(psql_command(container, validation_sql))
    if validated.returncode != 0:
        raise HarnessFailure(f"validation query failed: {validated.stderr.strip()}")

    actual = validated.stdout.strip().splitlines()[-1]
    expected = "100000|70000|30000|1|2|1|1|1|0"
    if actual != expected:
        raise HarnessFailure(
            "concurrency invariant mismatch; expected "
            f"{expected!r}, received {actual!r}"
        )

    print(
        "PASS: concurrent INR 700 + INR 700 requests against an INR 1,000 limit "
        "produced one success, one FCP_INSUFFICIENT_CREDIT failure, "
        "INR 700 principal, INR 300 available credit, and no losing partial rows."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (HarnessFailure, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
