#!/usr/bin/env python3
"""Restore a Phase 2E logical backup into a disposable local Supabase stack."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI_VERSION = "2.109.1"
RECONCILIATION = (
    ROOT / "supabase" / "validation" / "phase_2e_restore_reconciliation.sql"
)


class RestoreFailure(RuntimeError):
    """The disposable local restore rehearsal failed."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(
    command: list[str],
    *,
    cwd: Path,
    timeout: int = 300,
    stdin: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    handle = stdin.open("r", encoding="utf-8") if stdin else None
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            check=False,
            stdin=handle,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=timeout,
        )
    finally:
        if handle:
            handle.close()


def verify_backup(directory: Path) -> dict[str, object]:
    manifest_path = directory / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RestoreFailure("backup manifest is missing or invalid") from exc
    if manifest.get("safe_project_alias") != "credit-accounting-development":
        raise RestoreFailure("backup is not labeled for approved development")
    for name, metadata in manifest.get("files", {}).items():
        path = directory / name
        if not path.is_file() or sha256(path) != metadata.get("sha256"):
            raise RestoreFailure(f"backup checksum mismatch: {name}")
    for required in ("schema.sql", "data.sql", "auth-stubs.sql"):
        if required not in manifest.get("files", {}):
            raise RestoreFailure(f"backup file is missing from manifest: {required}")
    return manifest


def copy_repository(destination: Path) -> None:
    ignored = shutil.ignore_patterns(
        ".git",
        ".local-backups",
        ".local-state",
        ".temp",
        "target",
        "node_modules",
        "__pycache__",
    )
    shutil.copytree(ROOT, destination, ignore=ignored)


def isolate_config(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    project_id = f"credit-accounting-phase2e-restore-{uuid.uuid4().hex[:8]}"
    text = re.sub(
        r'^project_id\s*=\s*"[^"]+"',
        f'project_id = "{project_id}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    offset = random.randint(1000, 4000)

    def port(match: re.Match[str]) -> str:
        return f"{match.group(1)}{int(match.group(2)) + offset}"

    text = re.sub(
        r"^(\s*(?:port|shadow_port|inspector_port)\s*=\s*)(\d+)\s*$",
        port,
        text,
        flags=re.MULTILINE,
    )
    path.write_text(text, encoding="utf-8")
    return project_id


def database_container(project_id: str) -> str:
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
    candidates = [
        item.strip()
        for item in result.stdout.splitlines()
        if item.strip().startswith("supabase_db_")
    ]
    if result.returncode != 0 or len(candidates) != 1:
        raise RestoreFailure("disposable local database container was not found")
    return candidates[0]


def apply_sql(container: str, path: Path, cwd: Path) -> None:
    result = run(
        [
            "docker",
            "exec",
            "-i",
            container,
            "psql",
            "-X",
            "--no-psqlrc",
            "--quiet",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            "postgres",
            "-d",
            "postgres",
        ],
        cwd=cwd,
        stdin=path,
        timeout=180,
    )
    if result.returncode != 0:
        raise RestoreFailure(f"SQL restore failed: {path.name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("backup_directory")
    args = parser.parse_args()
    backup = Path(args.backup_directory).resolve()
    work_root = Path(tempfile.mkdtemp(prefix="phase2e-restore-"))
    repository = work_root / "credit-accounting-restore"
    start_attempted = False
    try:
        verify_backup(backup)
        copy_repository(repository)
        project_id = isolate_config(repository / "supabase" / "config.toml")

        start_attempted = True
        start = run(
            ["npx", "--yes", f"supabase@{CLI_VERSION}", "start"],
            cwd=repository,
            timeout=300,
        )
        if start.returncode != 0:
            raise RestoreFailure("disposable local Supabase start failed")
        reset = run(
            ["npx", "--yes", f"supabase@{CLI_VERSION}", "db", "reset", "--local"],
            cwd=repository,
            timeout=300,
        )
        if reset.returncode != 0:
            raise RestoreFailure("disposable local migration reset failed")

        container = database_container(project_id)
        prepare = """
drop schema if exists app_private cascade;
drop schema if exists public cascade;
create schema public authorization pg_database_owner;
delete from auth.users;
"""
        prepared = run(
            [
                "docker",
                "exec",
                "-i",
                container,
                "psql",
                "-X",
                "--no-psqlrc",
                "--quiet",
                "-v",
                "ON_ERROR_STOP=1",
                "-U",
                "postgres",
                "-d",
                "postgres",
                "-c",
                prepare,
            ],
            cwd=repository,
            timeout=60,
        )
        if prepared.returncode != 0:
            raise RestoreFailure("disposable database preparation failed")

        for name in ("schema.sql", "auth-stubs.sql", "data.sql"):
            apply_sql(container, backup / name, repository)
        apply_sql(container, RECONCILIATION, repository)
        apply_sql(
            container,
            repository
            / "supabase"
            / "validation"
            / "phase_2e_catalog_security.sql",
            repository,
        )
        print(
            "PASS: logical backup restored into a disposable local Supabase "
            "database; schema, fake data, migration head, RLS, functions, "
            "triggers, ledger, interest, correction evidence, and cron reconciled."
        )
        return 0
    except (OSError, RestoreFailure, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: disposable local restore rehearsal: {exc}", file=sys.stderr)
        return 1
    finally:
        if start_attempted:
            run(
                [
                    "npx",
                    "--yes",
                    f"supabase@{CLI_VERSION}",
                    "stop",
                    "--no-backup",
                ],
                cwd=repository,
                timeout=180,
            )
        resolved_work = work_root.resolve()
        resolved_temp = Path(tempfile.gettempdir()).resolve()
        if resolved_work.parent == resolved_temp and resolved_work.name.startswith(
            "phase2e-restore-"
        ):
            shutil.rmtree(resolved_work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
