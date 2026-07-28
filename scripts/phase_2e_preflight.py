#!/usr/bin/env python3
"""Fail-closed Phase 2E migration and repository preflight.

This command is intentionally local-only. It never connects to Supabase and
never reads credentials.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "supabase" / "migrations"
EXPECTED_BASE = "0bae407cfda8a973393d306d313006e083596e81"
MIGRATION_NAME = re.compile(r"^(?P<version>\d{14})_[a-z0-9_]+\.sql$")
FORBIDDEN = {
    "local hostname": re.compile(
        r"(?:localhost|127\.0\.0\.1|host\.docker\.internal)", re.IGNORECASE
    ),
    "embedded Supabase JWT": re.compile(
        r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\."
    ),
    "embedded Supabase secret key": re.compile(
        r"\bsb_secret_[A-Za-z0-9_-]{16,}\b"
    ),
    "embedded personal access token": re.compile(
        r"\bsbp_[A-Za-z0-9_-]{16,}\b"
    ),
    "embedded PostgreSQL credential": re.compile(
        r"\bpostgres(?:ql)?://[^ \t\r\n\"']+:[^ \t\r\n\"']+@",
        re.IGNORECASE,
    ),
    "HTTP credential in cron SQL": re.compile(
        r"(?:cron\.schedule|run_hourly_interest_accrual)[\s\S]{0,500}"
        r"(?:authorization|bearer|apikey|http://|https://)",
        re.IGNORECASE,
    ),
}


class PreflightFailure(RuntimeError):
    """The deployment preflight found a fail-closed condition."""


def git(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )


def migration_versions() -> tuple[list[Path], list[str]]:
    files = sorted(MIGRATIONS.glob("*.sql"))
    if not files:
        raise PreflightFailure("no committed SQL migrations found")

    versions: list[str] = []
    for path in files:
        match = MIGRATION_NAME.fullmatch(path.name)
        if not match:
            raise PreflightFailure(f"invalid migration filename: {path.name}")
        versions.append(match.group("version"))
    if len(versions) != len(set(versions)):
        raise PreflightFailure("duplicate migration version detected")
    if versions != sorted(versions):
        raise PreflightFailure("migration versions are not ordered")
    return files, versions


def verify_base(base: str, migration_files: list[Path]) -> None:
    base_check = git("cat-file", "-e", f"{base}^{{commit}}")
    if base_check.returncode != 0:
        raise PreflightFailure(f"reviewed base commit is unavailable: {base}")

    base_files = git("ls-tree", "-r", "--name-only", base, "--", "supabase/migrations")
    if base_files.returncode != 0:
        raise PreflightFailure(base_files.stderr.strip() or "git ls-tree failed")
    base_names = {line.strip() for line in base_files.stdout.splitlines() if line.strip()}

    changed = git("diff", "--name-status", base, "--", "supabase/migrations")
    if changed.returncode != 0:
        raise PreflightFailure(changed.stderr.strip() or "git diff failed")
    rewritten: list[str] = []
    for line in changed.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status, name = parts[0], parts[-1]
        if name in base_names and not status.startswith("A"):
            rewritten.append(f"{status} {name}")
    if rewritten:
        raise PreflightFailure(
            "existing migrations were rewritten: " + ", ".join(rewritten)
        )

    tracked = git("ls-files", "--", "supabase/migrations/*.sql")
    if tracked.returncode != 0:
        raise PreflightFailure(tracked.stderr.strip() or "git ls-files failed")
    tracked_names = {line.strip() for line in tracked.stdout.splitlines() if line.strip()}
    missing = [
        str(path.relative_to(ROOT)).replace("\\", "/")
        for path in migration_files
        if str(path.relative_to(ROOT)).replace("\\", "/") not in tracked_names
    ]
    if missing:
        raise PreflightFailure(
            "uncommitted migration files are not deployable: " + ", ".join(missing)
        )


def verify_migration_content(files: list[Path]) -> dict[str, str]:
    digest = hashlib.sha256()
    combined: list[str] = []
    for path in files:
        content = path.read_text(encoding="utf-8")
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(content.encode("utf-8"))
        combined.append(content)
        for label, pattern in FORBIDDEN.items():
            if pattern.search(content):
                raise PreflightFailure(f"{label} found in {path.name}")

    sql = "\n".join(combined)
    required_fragments = {
        "private schema": "create schema if not exists app_private",
        "cron extension": "create extension if not exists pg_cron",
        "hourly cron registration": "select cron.schedule(",
        "private schema revocation": "revoke all on schema app_private",
        "forced RLS": "force row level security",
    }
    for label, fragment in required_fragments.items():
        if fragment.lower() not in sql.lower():
            raise PreflightFailure(f"required {label} declaration is missing")
    if sql.lower().count("select cron.schedule(") != 1:
        raise PreflightFailure("expected exactly one committed cron registration")

    return {
        "migration_set_sha256": digest.hexdigest(),
        "migration_head": files[-1].name[:14],
    }


def parse_migration_list(path: Path) -> tuple[set[str], set[str]]:
    local: set[str] = set()
    remote: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        versions = re.findall(r"\b\d{14}\b", line)
        if not versions:
            continue
        if len(versions) >= 1:
            local.add(versions[0])
        if len(versions) >= 2:
            remote.add(versions[1])
    return local, remote


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=EXPECTED_BASE)
    parser.add_argument("--migration-list")
    parser.add_argument("--expect-remote", choices=("empty", "matching"))
    parser.add_argument("--report")
    args = parser.parse_args()

    try:
        files, versions = migration_versions()
        verify_base(args.base, files)
        details = verify_migration_content(files)

        remote_state = "not-inspected"
        if args.migration_list:
            local, remote = parse_migration_list(Path(args.migration_list))
            expected = set(versions)
            if local and local != expected:
                raise PreflightFailure("CLI local migration list differs from Git")
            if args.expect_remote == "empty" and remote:
                raise PreflightFailure("remote migration history is not empty")
            if args.expect_remote == "matching" and remote != expected:
                raise PreflightFailure("remote migration history differs from Git")
            remote_state = (
                "empty" if not remote else "matches-git" if remote == expected else "partial"
            )

        report = {
            "status": "pass",
            "reviewed_base": args.base,
            "migration_count": len(files),
            "migration_head": details["migration_head"],
            "migration_set_sha256": details["migration_set_sha256"],
            "remote_migration_state": remote_state,
            "checks": [
                "existing migration immutability",
                "tracked migration set",
                "forbidden credential and local-host patterns",
                "private schema and cron declarations",
                "single cron registration",
            ],
        }
        if args.report:
            Path(args.report).write_text(
                json.dumps(report, indent=2) + "\n", encoding="utf-8"
            )
        print(
            "PASS: Phase 2E preflight checked "
            f"{len(files)} committed migrations; head={details['migration_head']}; "
            f"remote={remote_state}."
        )
        return 0
    except (OSError, PreflightFailure) as exc:
        print(f"FAIL: Phase 2E preflight: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
