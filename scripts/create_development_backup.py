#!/usr/bin/env python3
"""Create a sanitized logical backup of the approved hosted development project."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

from phase_2e_target_safety import (
    TargetSafetyFailure,
    npx_executable,
    verify_local_link,
    verify_postgres_environment,
)


ROOT = Path(__file__).resolve().parents[1]
CLI_VERSION = "2.109.1"
BACKUP_ROOT = ROOT / ".local-backups"
EXPECTED_NAME = "credit-accounting-development"
EXPECTED_EMAIL = re.compile(r"^[a-z0-9-]+@credit-accounting\.example\.test$")
SECRET_PATTERNS = {
    "JWT": re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\."),
    "Supabase secret key": re.compile(r"\bsb_secret_[A-Za-z0-9_-]{16,}\b"),
    "Supabase access token": re.compile(r"\bsbp_[A-Za-z0-9_-]{16,}\b"),
    "credentialed PostgreSQL URI": re.compile(
        r"\bpostgres(?:ql)?://[^ \t\r\n\"']+:[^ \t\r\n\"']+@",
        re.IGNORECASE,
    ),
}


class BackupFailure(RuntimeError):
    """Backup safety or integrity validation failed."""


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise BackupFailure(f"required environment value is missing: {name}")
    return value


def run(command: list[str], *, timeout: int = 180) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=timeout,
    )


def cli_json(*arguments: str) -> Any:
    result = run(
        [
            npx_executable(),
            "--yes",
            f"supabase@{CLI_VERSION}",
            *arguments,
            "--output",
            "json",
        ],
        timeout=60,
    )
    if result.returncode != 0:
        raise BackupFailure("Supabase CLI project inspection failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise BackupFailure("Supabase CLI returned unexpected project data") from exc


def verify_target(project_ref: str, expected_region: str) -> None:
    projects = cli_json("projects", "list")
    matches = [
        item
        for item in projects
        if isinstance(item, dict)
        and (item.get("ref") == project_ref or item.get("id") == project_ref)
    ]
    if len(matches) != 1:
        raise BackupFailure("selected project is not uniquely accessible")
    project = matches[0]
    if project.get("name") != EXPECTED_NAME:
        raise BackupFailure("selected project is not the approved development project")
    if project.get("region") != expected_region:
        raise BackupFailure("selected project is not in the approved region")


def fake_auth_users() -> list[dict[str, str]]:
    for name in ("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"):
        required_env(name)
    sql = """
select coalesce(
  json_agg(
    json_build_object('id', id::text, 'email', email)
    order by email
  )::text,
  '[]'
)
from auth.users;
"""
    result = run(
        [
            "psql",
            "-X",
            "--no-psqlrc",
            "-qAt",
            "-v",
            "ON_ERROR_STOP=1",
            "-c",
            sql,
        ],
        timeout=30,
    )
    if result.returncode != 0:
        raise BackupFailure("unable to inspect fake Auth identities")
    try:
        users = json.loads(result.stdout.strip())
    except json.JSONDecodeError as exc:
        raise BackupFailure("unexpected Auth identity response") from exc
    if not users:
        raise BackupFailure("no fake Auth identities were found")
    for user in users:
        if not EXPECTED_EMAIL.fullmatch(str(user.get("email", ""))):
            raise BackupFailure("non-fake Auth email detected; backup refused")
        try:
            import uuid

            uuid.UUID(str(user["id"]))
        except (KeyError, ValueError) as exc:
            raise BackupFailure("invalid fake Auth identity") from exc
    return users


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def write_auth_stubs(path: Path, users: list[dict[str, str]]) -> None:
    rows = []
    for user in users:
        label = user["email"].split("@", 1)[0]
        rows.append(
            "("
            + ", ".join(
                (
                    "'00000000-0000-0000-0000-000000000000'",
                    sql_literal(user["id"]),
                    "'authenticated'",
                    "'authenticated'",
                    sql_literal(user["email"]),
                    "null",
                    "'2026-01-01T00:00:00Z'",
                    "'{\"provider\":\"email\",\"providers\":[\"email\"]}'::jsonb",
                    sql_literal(
                        json.dumps(
                            {
                                "fixture": label,
                                "environment": "DEVELOPMENT",
                                "fake_data": True,
                            },
                            separators=(",", ":"),
                        )
                    )
                    + "::jsonb",
                    "'2026-01-01T00:00:00Z'",
                    "'2026-01-01T00:00:00Z'",
                )
            )
            + ")"
        )
    content = """-- Sanitized fake Auth stubs for local restore only.
-- No password hash, API key, token, or login identity is included.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values
  %s
on conflict (id) do nothing;
""" % ",\n  ".join(rows)
    path.write_text(content, encoding="utf-8")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def scan(paths: list[Path]) -> None:
    for path in paths:
        text = path.read_text(encoding="utf-8", errors="replace")
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                raise BackupFailure(f"{label} detected in {path.name}")
        for email in re.findall(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+", text):
            if not EXPECTED_EMAIL.fullmatch(email.lower()):
                raise BackupFailure(f"non-fake email detected in {path.name}")
        for phone in re.findall(r"\+\d{7,15}", text):
            if not re.fullmatch(r"\+155501\d{5}", phone):
                raise BackupFailure(
                    f"unexpected phone-shaped data detected in {path.name}"
                )


def main() -> int:
    try:
        project_ref = required_env("SUPABASE_PROJECT_ID")
        expected_region = required_env("SUPABASE_EXPECTED_REGION")
        verify_target(project_ref, expected_region)
        verify_local_link(ROOT, project_ref)
        verify_postgres_environment(project_ref)
        users = fake_auth_users()

        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        destination = BACKUP_ROOT / f"{stamp}-credit-accounting-development"
        destination.mkdir(parents=True, exist_ok=False)
        schema = destination / "schema.sql"
        data = destination / "data.sql"
        auth_stubs = destination / "auth-stubs.sql"

        for arguments, target in (
            (
                (
                    "db",
                    "dump",
                    "--linked",
                    "--schema",
                    "public,app_private",
                    "--file",
                    str(schema),
                ),
                schema,
            ),
            (
                (
                    "db",
                    "dump",
                    "--linked",
                    "--data-only",
                    "--schema",
                    "public,app_private",
                    "--file",
                    str(data),
                ),
                data,
            ),
        ):
            result = run(
                [npx_executable(), "--yes", f"supabase@{CLI_VERSION}", *arguments]
            )
            if result.returncode != 0 or not target.exists():
                raise BackupFailure(f"logical dump failed: {target.name}")

        write_auth_stubs(auth_stubs, users)
        scan([schema, data, auth_stubs])
        migration_files = sorted((ROOT / "supabase" / "migrations").glob("*.sql"))
        if not migration_files:
            raise BackupFailure("migration head could not be determined")
        manifest = {
            "created_at_utc": stamp,
            "safe_project_alias": "credit-accounting-development",
            "data_classification": "DEVELOPMENT - FAKE DATA ONLY",
            "migration_head": migration_files[-1].name[:14],
            "supabase_cli_version": CLI_VERSION,
            "backup_scope": [
                "public schema",
                "app_private schema",
                "public and app_private fake data",
                "sanitized fake Auth stubs without credentials",
            ],
            "files": {
                path.name: {"sha256": sha256(path), "bytes": path.stat().st_size}
                for path in (schema, data, auth_stubs)
            },
            "scan": "pass: fake domains only; no token, secret key, access token, credentialed URI, or unexpected phone-shaped data",
            "sensitivity": "Treat as sensitive development data; store outside Git.",
        }
        manifest_path = destination / "manifest.json"
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        try:
            for path in destination.iterdir():
                path.chmod(stat.S_IRUSR | stat.S_IWUSR)
        except OSError:
            pass
        print(
            "PASS: logical development backup created outside Git; "
            f"manifest={manifest_path}; checksum={sha256(manifest_path)}"
        )
        return 0
    except (
        BackupFailure,
        OSError,
        subprocess.TimeoutExpired,
        TargetSafetyFailure,
    ) as exc:
        print(f"FAIL: development logical backup: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
