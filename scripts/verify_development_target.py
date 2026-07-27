#!/usr/bin/env python3
"""Verify the selected hosted project without disclosing its reference."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from phase_2e_target_safety import TargetSafetyFailure, verify_postgres_environment


API_ROOT = "https://api.supabase.com/v1"
ALLOWED_EXTERNAL_AUTH_KEYS = {
    "external_email_enabled",
    "external_anonymous_users_enabled",
}


class TargetFailure(RuntimeError):
    """The selected target could not be proven to be development-only."""


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise TargetFailure(f"required environment value is missing: {name}")
    return value


def api_get(path: str, token: str) -> Any:
    request = urllib.request.Request(
        f"{API_ROOT}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "credit-accounting-phase-2e",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise TargetFailure(
            f"Supabase Management API request failed with HTTP {exc.code}"
        ) from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise TargetFailure("Supabase Management API request failed") from exc


def exposed_schemas(config: dict[str, Any]) -> list[str]:
    raw = (
        config.get("db_schema")
        or config.get("db_schemas")
        or config.get("schemas")
        or config.get("dbSchema")
        or ""
    )
    if isinstance(raw, str):
        return sorted(item.strip() for item in raw.split(",") if item.strip())
    if isinstance(raw, list):
        return sorted(str(item).strip() for item in raw if str(item).strip())
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-closed-auth", action="store_true")
    parser.add_argument("--report")
    args = parser.parse_args()

    try:
        token = required_env("SUPABASE_ACCESS_TOKEN")
        project_ref = required_env("SUPABASE_PROJECT_ID")
        expected_name = required_env("SUPABASE_EXPECTED_PROJECT_NAME")
        expected_region = required_env("SUPABASE_EXPECTED_REGION")
        verify_postgres_environment(project_ref)

        projects = api_get("/projects", token)
        if not isinstance(projects, list):
            raise TargetFailure("unexpected project-list response")
        matches = [
            project
            for project in projects
            if isinstance(project, dict)
            and (project.get("ref") == project_ref or project.get("id") == project_ref)
        ]
        if len(matches) != 1:
            raise TargetFailure("selected project is not uniquely accessible")
        project = matches[0]
        name = str(project.get("name", ""))
        region = str(project.get("region", ""))
        status = str(project.get("status", ""))
        if name != expected_name:
            raise TargetFailure("selected project name is not the approved development name")
        if region != expected_region:
            raise TargetFailure("selected project region is not the approved development region")
        if "development" not in name.lower():
            raise TargetFailure("selected project name lacks a development marker")
        if status and status not in {"ACTIVE_HEALTHY", "ACTIVE"}:
            raise TargetFailure(f"selected project is not healthy: {status}")

        auth = api_get(f"/projects/{project_ref}/config/auth", token)
        postgrest = api_get(f"/projects/{project_ref}/postgrest", token)
        if not isinstance(auth, dict) or not isinstance(postgrest, dict):
            raise TargetFailure("unexpected configuration response")

        schemas = exposed_schemas(postgrest)
        if not schemas:
            raise TargetFailure("Data API exposed schemas could not be determined")
        if "app_private" in schemas:
            raise TargetFailure("app_private is exposed through the Data API")
        if "public" not in schemas:
            raise TargetFailure("public is not present in the Data API schema list")

        signup_disabled = auth.get("disable_signup") is True
        anonymous_disabled = auth.get("external_anonymous_users_enabled") is not True
        email_signin_enabled = auth.get("external_email_enabled") is True
        social_enabled = sorted(
            key.removeprefix("external_").removesuffix("_enabled")
            for key, value in auth.items()
            if key.startswith("external_")
            and key.endswith("_enabled")
            and key not in ALLOWED_EXTERNAL_AUTH_KEYS
            and value is True
        )
        if args.require_closed_auth:
            if not signup_disabled:
                raise TargetFailure("public Auth signup is not disabled")
            if not anonymous_disabled:
                raise TargetFailure("anonymous Auth sign-in is not disabled")
            if not email_signin_enabled:
                raise TargetFailure("email sign-in is not enabled for fake test users")
            if social_enabled:
                raise TargetFailure(
                    "social Auth providers are enabled: " + ", ".join(social_enabled)
                )

        report = {
            "status": "pass",
            "safe_alias": "credit-accounting-development",
            "project_name": name,
            "region": region,
            "project_status": status or "available",
            "data_api_schemas": schemas,
            "auth": {
                "public_signup_disabled": signup_disabled,
                "anonymous_sign_in_disabled": anonymous_disabled,
                "email_sign_in_enabled": email_signin_enabled,
                "social_providers_enabled": social_enabled,
            },
        }
        if args.report:
            Path(args.report).write_text(
                json.dumps(report, indent=2) + "\n", encoding="utf-8"
            )
        print(
            "PASS: target is the approved development project; "
            f"region={region}; Data API schemas={','.join(schemas)}; "
            f"closed_auth={'verified' if args.require_closed_auth else 'reported'}."
        )
        return 0
    except (OSError, TargetFailure, TargetSafetyFailure) as exc:
        print(f"FAIL: development target verification: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
