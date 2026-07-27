"""Select a local Docker or approved remote PostgreSQL psql target."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from phase_2e_target_safety import (  # noqa: E402
    TargetSafetyFailure,
    verify_cli_project,
    verify_local_link,
    verify_postgres_environment,
)


class TargetFailure(RuntimeError):
    """A database target is unavailable or unsafe."""


def _required_environment() -> None:
    project_ref = os.environ.get("SUPABASE_PROJECT_ID", "").strip()
    if not project_ref:
        raise TargetFailure(
            "required remote database value is missing: SUPABASE_PROJECT_ID"
        )
    expected_region = os.environ.get("SUPABASE_EXPECTED_REGION", "").strip()
    if not expected_region:
        raise TargetFailure(
            "required remote database value is missing: SUPABASE_EXPECTED_REGION"
        )
    try:
        verify_cli_project(ROOT, project_ref, expected_region)
        verify_local_link(ROOT, project_ref)
        verify_postgres_environment(project_ref)
    except TargetSafetyFailure as exc:
        raise TargetFailure(str(exc)) from exc


def database_target(project_id: str) -> str | None:
    if os.environ.get("PHASE_2E_REMOTE_DATABASE") == "1":
        _required_environment()
        return None

    result = subprocess.run(
        [
            "docker",
            "ps",
            "--filter",
            f"label=com.supabase.cli.project={project_id}",
            "--format",
            "{{.Names}}",
        ],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        raise TargetFailure(f"docker ps failed: {result.stderr.strip()}")
    candidates = [
        name.strip()
        for name in result.stdout.splitlines()
        if name.strip().startswith("supabase_db_")
    ]
    if len(candidates) != 1:
        raise TargetFailure(
            f"expected one running local Supabase database container, found {candidates}"
        )
    return candidates[0]


def psql_command(target: str | None, sql: str) -> list[str]:
    common = [
        "psql",
        "-X",
        "--no-psqlrc",
        "-qAt",
        "-v",
        "ON_ERROR_STOP=1",
        "-c",
        sql,
    ]
    if target is None:
        return common
    return [
        "docker",
        "exec",
        "-i",
        target,
        *common,
        "-U",
        "postgres",
        "-d",
        "postgres",
    ]
