#!/usr/bin/env python3
"""Run all four independent-session harnesses against hosted development."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
STATE_FILE = ROOT / ".local-state" / "phase-2e-auth.json"
HARNESSES = (
    ("fuel-credit overspending", "phase_2a_credit_limit_concurrency.py"),
    ("competing repayment", "phase_2b_repayment_concurrency.py"),
    ("duplicate interest accrual", "phase_2c_interest_accrual_concurrency.py"),
    ("concurrent correction approval", "phase_2d_reversal_correction_concurrency.py"),
)


class RemoteConcurrencyFailure(RuntimeError):
    """A remote concurrency precondition or harness failed."""


def credentials() -> dict[str, str]:
    try:
        payload = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RemoteConcurrencyFailure("ignored fake-Auth state is unavailable") from exc
    users = {
        item["label"]: item["user_id"]
        for item in payload.get("users", [])
        if isinstance(item, dict) and "label" in item and "user_id" in item
    }
    for label in ("owner-a", "owner-checker", "manager-a"):
        if label not in users:
            raise RemoteConcurrencyFailure(f"fake identity is missing: {label}")
    return users


def sanitize(message: str, environment: dict[str, str]) -> str:
    cleaned = message
    for name in ("PGPASSWORD", "PGHOST", "PGUSER", "SUPABASE_PROJECT_ID"):
        value = environment.get(name, "")
        if value:
            cleaned = cleaned.replace(value, "[redacted]")
    cleaned = re.sub(
        r"postgres(?:ql)?://\S+",
        "postgresql://[redacted]",
        cleaned,
        flags=re.IGNORECASE,
    )
    return cleaned[-500:]


def main() -> int:
    try:
        if os.environ.get("PHASE_2E_REMOTE_DATABASE") != "1":
            raise RemoteConcurrencyFailure(
                "PHASE_2E_REMOTE_DATABASE=1 is required for the hosted smoke"
            )
        for name in ("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"):
            if not os.environ.get(name, "").strip():
                raise RemoteConcurrencyFailure(f"missing remote database value: {name}")
        if os.environ.get("PGSSLMODE", "").lower() not in {
            "require",
            "verify-ca",
            "verify-full",
        }:
            raise RemoteConcurrencyFailure("TLS is required for hosted concurrency")

        users = credentials()
        environment = dict(os.environ)
        environment.update(
            {
                "PHASE_2E_OWNER_ID": users["owner-a"],
                "PHASE_2E_OWNER_CHECKER_ID": users["owner-checker"],
                "PHASE_2E_MANAGER_ID": users["manager-a"],
                "PHASE_2E_ORGANIZATION_ID": "e0000000-0000-0000-0000-000000000001",
                "PHASE_2E_STATION_ID": "e1000000-0000-0000-0000-000000000001",
                "PHASE_2E_PRODUCT_ID": "ef100000-0000-0000-0000-000000000001",
            }
        )
        harness_dir = ROOT / "supabase" / "tests" / "concurrency"
        for label, filename in HARNESSES:
            result = subprocess.run(
                [sys.executable, str(harness_dir / filename)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=180,
            )
            if result.returncode != 0:
                detail = sanitize(result.stderr or result.stdout, environment)
                raise RemoteConcurrencyFailure(f"{label} failed: {detail}")
            print(f"PASS: hosted {label} race")
        print(
            "PASS: all four hosted races used independent TLS database sessions; "
            "no load or stress test was run."
        )
        return 0
    except (RemoteConcurrencyFailure, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: hosted concurrency smoke: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
