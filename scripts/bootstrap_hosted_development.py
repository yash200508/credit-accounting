#!/usr/bin/env python3
"""Create approved fake Auth users and deterministic hosted fixtures.

The script retrieves the project's secret API key into process memory through
the authenticated Supabase CLI. It never prints or writes that key. Generated
fake-user passwords are written only to the ignored local-state directory.
"""

from __future__ import annotations

import json
import os
import secrets
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
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
STATE_FILE = ROOT / ".local-state" / "phase-2e-auth.json"
FIXTURE_SQL = ROOT / "supabase" / "fixtures" / "development_bootstrap.sql"
EXPECTED_NAME = "credit-accounting-development"
FAKE_USERS = (
    ("owner-a", "owner-a@credit-accounting.example.test"),
    ("owner-checker", "owner-checker@credit-accounting.example.test"),
    ("manager-a", "manager-a@credit-accounting.example.test"),
    ("attendant-a", "attendant-a@credit-accounting.example.test"),
    ("customer-a", "customer-a@credit-accounting.example.test"),
    ("driver-a", "driver-a@credit-accounting.example.test"),
    ("isolation-owner", "isolation-owner@credit-accounting.example.test"),
)


class BootstrapFailure(RuntimeError):
    """Hosted development bootstrap failed closed."""


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise BootstrapFailure(f"required environment value is missing: {name}")
    return value


def cli(*arguments: str) -> Any:
    result = subprocess.run(
        [
            npx_executable(),
            "--yes",
            f"supabase@{CLI_VERSION}",
            *arguments,
            "--output",
            "json",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=60,
    )
    if result.returncode != 0:
        raise BootstrapFailure(
            result.stderr.strip().splitlines()[-1]
            if result.stderr.strip()
            else "Supabase CLI request failed"
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise BootstrapFailure("Supabase CLI returned unexpected output") from exc


def verify_project(project_ref: str, expected_region: str) -> None:
    projects = cli("projects", "list")
    matches = [
        item
        for item in projects
        if isinstance(item, dict)
        and (item.get("ref") == project_ref or item.get("id") == project_ref)
    ]
    if len(matches) != 1:
        raise BootstrapFailure("selected project is not uniquely accessible")
    project = matches[0]
    if project.get("name") != EXPECTED_NAME:
        raise BootstrapFailure("selected project is not the approved development project")
    if project.get("region") != expected_region:
        raise BootstrapFailure("selected project is not in the approved region")


def project_secret(project_ref: str) -> str:
    payload = cli("projects", "api-keys", "--project-ref", project_ref, "--reveal")
    candidates: list[tuple[int, str]] = []
    items = payload if isinstance(payload, list) else payload.get("api_keys", [])
    for item in items:
        if not isinstance(item, dict):
            continue
        value = str(item.get("api_key", item.get("key", "")))
        label = " ".join(
            str(item.get(name, "")) for name in ("name", "type", "prefix")
        ).lower()
        if value.startswith("sb_secret_"):
            candidates.append((0, value))
        elif "service_role" in label and value.count(".") == 2:
            candidates.append((1, value))
    if not candidates:
        raise BootstrapFailure("no server-only project API key was available")
    return sorted(candidates)[0][1]


def auth_request(
    project_ref: str,
    secret_key: str,
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
) -> Any:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        f"https://{project_ref}.supabase.co/auth/v1{path}",
        method=method,
        data=data,
        headers={
            "apikey": secret_key,
            "Authorization": f"Bearer {secret_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "credit-accounting-phase-2e-bootstrap",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        message = f"Auth Admin API failed with HTTP {exc.code}"
        try:
            body = json.loads(exc.read().decode("utf-8"))
            safe_code = body.get("code") or body.get("error_code")
            if safe_code:
                message += f" ({safe_code})"
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass
        raise BootstrapFailure(message) from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise BootstrapFailure("Auth Admin API request failed") from exc


def existing_users(project_ref: str, secret_key: str) -> dict[str, dict[str, Any]]:
    found: dict[str, dict[str, Any]] = {}
    page = 1
    while True:
        payload = auth_request(
            project_ref,
            secret_key,
            "GET",
            f"/admin/users?page={page}&per_page=100",
        )
        users = payload.get("users", []) if isinstance(payload, dict) else []
        for user in users:
            email = str(user.get("email", "")).lower()
            if email:
                found[email] = user
        if len(users) < 100:
            break
        page += 1
    return found


def create_users(project_ref: str, secret_key: str) -> list[dict[str, str]]:
    existing = existing_users(project_ref, secret_key)
    credentials: list[dict[str, str]] = []
    prior_credentials: dict[str, dict[str, str]] = {}
    if STATE_FILE.exists():
        try:
            prior = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            prior_credentials = {
                item["email"]: item
                for item in prior.get("users", [])
                if isinstance(item, dict) and "email" in item
            }
        except (OSError, json.JSONDecodeError, KeyError):
            prior_credentials = {}

    for label, email in FAKE_USERS:
        current = existing.get(email)
        prior = prior_credentials.get(email)
        if current is not None and prior is None:
            metadata = current.get("user_metadata") or current.get("raw_user_meta_data")
            if not isinstance(metadata, dict) or (
                metadata.get("environment") != "DEVELOPMENT"
                or metadata.get("fake_data") is not True
            ):
                raise BootstrapFailure(
                    "an expected fake Auth email exists without the development marker"
                )
            password = secrets.token_urlsafe(24) + "!Aa7"
            updated = auth_request(
                project_ref,
                secret_key,
                "PUT",
                f"/admin/users/{current['id']}",
                {"password": password, "email_confirm": True},
            )
            credentials.append(
                {
                    "label": label,
                    "email": email,
                    "password": password,
                    "user_id": str(updated["id"]),
                }
            )
            write_state(credentials)
            continue
        if current is not None:
            credentials.append(
                {
                    "label": label,
                    "email": email,
                    "password": prior["password"],
                    "user_id": str(current["id"]),
                }
            )
            write_state(credentials)
            continue

        password = secrets.token_urlsafe(24) + "!Aa7"
        created = auth_request(
            project_ref,
            secret_key,
            "POST",
            "/admin/users",
            {
                "email": email,
                "password": password,
                "email_confirm": True,
                "user_metadata": {
                    "fixture": label,
                    "environment": "DEVELOPMENT",
                    "fake_data": True,
                },
            },
        )
        credentials.append(
            {
                "label": label,
                "email": email,
                "password": password,
                "user_id": str(created["id"]),
            }
        )
        write_state(credentials)
    return credentials


def write_state(users: list[dict[str, str]]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "safe_project_alias": "credit-accounting-development",
        "classification": "DEVELOPMENT - FAKE DATA ONLY",
        "users": users,
    }
    STATE_FILE.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    try:
        STATE_FILE.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def apply_application_fixtures() -> None:
    for name in ("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"):
        required_env(name)
    result = subprocess.run(
        [
            "psql",
            "-X",
            "--no-psqlrc",
            "--quiet",
            "--set",
            "ON_ERROR_STOP=1",
            "--file",
            str(FIXTURE_SQL),
        ],
        cwd=ROOT,
        check=False,
        text=True,
        encoding="utf-8",
        timeout=60,
    )
    if result.returncode != 0:
        raise BootstrapFailure("application fixture transaction failed")


def main() -> int:
    try:
        project_ref = required_env("SUPABASE_PROJECT_ID")
        expected_region = required_env("SUPABASE_EXPECTED_REGION")
        verify_project(project_ref, expected_region)
        verify_local_link(ROOT, project_ref)
        verify_postgres_environment(project_ref)
        secret_key = project_secret(project_ref)
        users = create_users(project_ref, secret_key)
        write_state(users)
        apply_application_fixtures()
        print(
            "PASS: created or verified 7 fake development Auth users and "
            "deterministic application fixtures; credentials remain in ignored local state."
        )
        return 0
    except (
        BootstrapFailure,
        KeyError,
        OSError,
        subprocess.TimeoutExpired,
        TargetSafetyFailure,
    ) as exc:
        print(f"FAIL: hosted development bootstrap: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
