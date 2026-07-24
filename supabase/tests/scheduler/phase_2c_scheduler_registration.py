#!/usr/bin/env python3
"""Verify the committed pg_cron registration without claiming cron execution."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
CONFIG = ROOT / "supabase" / "config.toml"


class SchedulerCheckFailure(RuntimeError):
    """The local scheduler registration does not match the controlled design."""


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
    )


def project_id() -> str:
    config_text = CONFIG.read_text(encoding="utf-8")
    match = re.search(r'^project_id\s*=\s*"([^"]+)"', config_text, re.MULTILINE)
    if not match:
        raise SchedulerCheckFailure("project_id is missing from config.toml")
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
    candidates = [
        name.strip()
        for name in result.stdout.splitlines()
        if name.strip().startswith("supabase_db_")
    ]
    if result.returncode != 0 or len(candidates) != 1:
        raise SchedulerCheckFailure(
            f"expected one local database container, found {candidates}"
        )
    return candidates[0]


def main() -> int:
    container = database_container()
    sql = """
select concat_ws(
  '|',
  (select count(*) from pg_extension where extname = 'pg_cron'),
  (select count(*) from cron.job
   where jobname = 'credit-accounting-hourly-interest-accrual'),
  (select schedule from cron.job
   where jobname = 'credit-accounting-hourly-interest-accrual'),
  (select command from cron.job
   where jobname = 'credit-accounting-hourly-interest-accrual'),
  has_function_privilege(
    'anon',
    'app_private.run_hourly_interest_accrual()',
    'execute'
  ),
  has_function_privilege(
    'authenticated',
    'app_private.run_hourly_interest_accrual()',
    'execute'
  ),
  has_function_privilege(
    'service_role',
    'app_private.run_hourly_interest_accrual()',
    'execute'
  ),
  has_schema_privilege('anon', 'cron', 'usage'),
  has_schema_privilege('authenticated', 'cron', 'usage'),
  has_schema_privilege('service_role', 'cron', 'usage')
);
"""
    result = run(
        [
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
    )
    if result.returncode != 0:
        raise SchedulerCheckFailure(result.stderr.strip())

    actual = result.stdout.strip().splitlines()[-1]
    expected = (
        "1|1|7 * * * *|select app_private.run_hourly_interest_accrual();"
        "|f|f|f|f|f|f"
    )
    if actual != expected:
        raise SchedulerCheckFailure(
            f"expected {expected!r}, received {actual!r}"
        )
    lowered = actual.lower()
    if re.search(r"(https?://|secret|password|token|service[_-]?role[_-]?key)", lowered):
        raise SchedulerCheckFailure("scheduler command contains secret-like material")

    print(
        "PASS: pg_cron is enabled with exactly one hourly named job targeting "
        "the fixed private function; anon, authenticated, and service_role "
        "cannot execute it or use the cron schema. Registration was inspected; "
        "wall-clock cron execution was not exercised."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SchedulerCheckFailure, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
