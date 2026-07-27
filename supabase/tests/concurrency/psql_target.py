"""Select a local Docker or approved remote PostgreSQL psql target."""

from __future__ import annotations

import os
import subprocess


class TargetFailure(RuntimeError):
    """A database target is unavailable or unsafe."""


def _required_environment() -> None:
    for name in ("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"):
        if not os.environ.get(name, "").strip():
            raise TargetFailure(f"required remote database value is missing: {name}")
    if os.environ.get("PGSSLMODE", "").lower() not in {"require", "verify-ca", "verify-full"}:
        raise TargetFailure("remote database connections must require TLS")


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
