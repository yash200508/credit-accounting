#!/usr/bin/env python3
"""Fail-closed helpers that bind Phase 2E operations to one hosted project."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Mapping


CLI_VERSION = "2.109.1"
EXPECTED_NAME = "credit-accounting-development"


class TargetSafetyFailure(RuntimeError):
    """A hosted operation could not prove its target is the approved project."""


def npx_executable() -> str:
    """Resolve npx across Unix executables and Windows npx.cmd shims."""

    executable = shutil.which("npx")
    if not executable:
        raise TargetSafetyFailure("npx is not available on PATH")
    return executable


def verify_cli_project(root: Path, project_ref: str, expected_region: str) -> None:
    """Prove the CLI session can see exactly the approved development project."""

    result = subprocess.run(
        [
            npx_executable(),
            "--yes",
            f"supabase@{CLI_VERSION}",
            "projects",
            "list",
            "--output",
            "json",
        ],
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=60,
    )
    if result.returncode != 0:
        raise TargetSafetyFailure("Supabase CLI project inspection failed")
    try:
        projects = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise TargetSafetyFailure(
            "Supabase CLI returned unexpected project data"
        ) from exc
    matches = [
        item
        for item in projects
        if isinstance(item, dict)
        and (item.get("ref") == project_ref or item.get("id") == project_ref)
    ]
    if len(matches) != 1:
        raise TargetSafetyFailure("selected project is not uniquely accessible")
    project = matches[0]
    if project.get("name") != EXPECTED_NAME:
        raise TargetSafetyFailure(
            "selected project is not the approved development project"
        )
    if project.get("region") != expected_region:
        raise TargetSafetyFailure("selected project is not in the approved region")


def verify_postgres_environment(
    project_ref: str, environment: Mapping[str, str] | None = None
) -> None:
    """Prove libpq environment values identify the same TLS Supabase project."""

    values = os.environ if environment is None else environment
    required = ("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD")
    for name in required:
        if not str(values.get(name, "")).strip():
            raise TargetSafetyFailure(
                f"required remote database value is missing: {name}"
            )

    if not re.fullmatch(r"[a-z0-9]+", project_ref):
        raise TargetSafetyFailure("the selected project identifier is invalid")

    host = str(values["PGHOST"]).strip().lower().rstrip(".")
    user = str(values["PGUSER"]).strip().lower()
    database = str(values["PGDATABASE"]).strip().lower()
    sslmode = str(values.get("PGSSLMODE", "")).strip().lower()

    if host in {"localhost", "127.0.0.1", "::1"}:
        raise TargetSafetyFailure("a hosted operation cannot target a local database")
    if sslmode not in {"require", "verify-ca", "verify-full"}:
        raise TargetSafetyFailure("hosted database connections must require TLS")
    if database != "postgres":
        raise TargetSafetyFailure("the hosted database name must be postgres")
    try:
        port = int(str(values["PGPORT"]).strip())
    except ValueError as exc:
        raise TargetSafetyFailure("the hosted database port is invalid") from exc
    if not 1 <= port <= 65535:
        raise TargetSafetyFailure("the hosted database port is invalid")

    direct_host = host == f"db.{project_ref}.supabase.co"
    pooler_user = user == f"postgres.{project_ref}"
    if not (direct_host or pooler_user):
        raise TargetSafetyFailure(
            "PostgreSQL host/user values do not identify the selected project"
        )


def verify_local_link(root: Path, project_ref: str) -> None:
    """Prove the repository's ignored CLI link points at the selected project."""

    link_file = root / "supabase" / ".temp" / "project-ref"
    try:
        linked_ref = link_file.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise TargetSafetyFailure(
            "the repository is not linked to the selected development project"
        ) from exc
    if linked_ref != project_ref:
        raise TargetSafetyFailure(
            "the repository link does not match the selected development project"
        )
