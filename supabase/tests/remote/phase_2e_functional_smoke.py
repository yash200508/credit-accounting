#!/usr/bin/env python3
"""Run fake-data functional smoke tests through hosted Auth and PostgREST."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from phase_2e_target_safety import (  # noqa: E402
    TargetSafetyFailure,
    npx_executable,
    verify_cli_project,
    verify_local_link,
    verify_postgres_environment,
)

STATE_FILE = ROOT / ".local-state" / "phase-2e-auth.json"
CLI_VERSION = "2.109.1"
STATION_ID = "e1000000-0000-0000-0000-000000000001"
PRODUCT_ID = "ef100000-0000-0000-0000-000000000001"


class SmokeFailure(RuntimeError):
    """A hosted functional assertion failed."""


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SmokeFailure(f"required environment value is missing: {name}")
    return value


def api_keys(project_ref: str) -> list[dict[str, Any]]:
    result = subprocess.run(
        [
            npx_executable(),
            "--yes",
            f"supabase@{CLI_VERSION}",
            "projects",
            "api-keys",
            "--project-ref",
            project_ref,
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
        raise SmokeFailure("unable to obtain the hosted publishable key")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SmokeFailure("unexpected API-key response") from exc
    return payload if isinstance(payload, list) else payload.get("api_keys", [])


def publishable_key(project_ref: str) -> str:
    candidates: list[tuple[int, str]] = []
    for item in api_keys(project_ref):
        if not isinstance(item, dict):
            continue
        value = str(item.get("api_key", item.get("key", "")))
        label = " ".join(
            str(item.get(name, "")) for name in ("name", "type", "prefix")
        ).lower()
        if value.startswith("sb_publishable_"):
            candidates.append((0, value))
        elif "anon" in label and value.count(".") == 2:
            candidates.append((1, value))
    if not candidates:
        raise SmokeFailure("no publishable project key was available")
    return sorted(candidates)[0][1]


class HostedApi:
    def __init__(self, project_ref: str, key: str) -> None:
        self.base = f"https://{project_ref}.supabase.co"
        self.key = key

    def request(
        self,
        method: str,
        path: str,
        *,
        token: str | None = None,
        body: Any = None,
        prefer: str | None = None,
        expected: tuple[int, ...] = (200,),
    ) -> Any:
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = {
            "apikey": self.key,
            "Authorization": f"Bearer {token or self.key}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "credit-accounting-phase-2e-smoke",
        }
        if prefer:
            headers["Prefer"] = prefer
        request = urllib.request.Request(
            f"{self.base}{path}", method=method, data=data, headers=headers
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
                if response.status not in expected:
                    raise SmokeFailure(f"unexpected HTTP status {response.status}")
                return json.loads(payload) if payload else None
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            try:
                error = json.loads(payload.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                error = {}
            if exc.code in expected:
                return error
            safe_code = error.get("code") or error.get("error_code") or "unclassified"
            safe_message = str(error.get("message", ""))[:120]
            raise SmokeFailure(
                f"HTTP {exc.code}; code={safe_code}; message={safe_message}"
            ) from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise SmokeFailure("hosted API request failed") from exc

    def login(self, email: str, password: str) -> str:
        payload = self.request(
            "POST",
            "/auth/v1/token?grant_type=password",
            body={"email": email, "password": password},
        )
        token = str(payload.get("access_token", ""))
        if not token:
            raise SmokeFailure(f"fake identity could not sign in: {email}")
        return token

    def rpc(self, token: str, name: str, body: dict[str, Any]) -> list[dict[str, Any]]:
        payload = self.request(
            "POST",
            f"/rest/v1/rpc/{name}",
            token=token,
            body=body,
        )
        if not isinstance(payload, list) or not payload:
            raise SmokeFailure(f"RPC returned no rows: {name}")
        return payload

    def select(self, token: str | None, table: str, query: str) -> list[dict[str, Any]]:
        payload = self.request(
            "GET",
            f"/rest/v1/{table}?{query}",
            token=token,
            expected=(200,),
        )
        if not isinstance(payload, list):
            raise SmokeFailure(f"unexpected table response: {table}")
        return payload


def load_credentials() -> dict[str, dict[str, str]]:
    try:
        payload = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SmokeFailure("ignored fake-Auth state is missing or invalid") from exc
    users = {
        item["label"]: item
        for item in payload.get("users", [])
        if isinstance(item, dict)
    }
    required = {
        "owner-a",
        "owner-checker",
        "manager-a",
        "attendant-a",
        "isolation-owner",
    }
    if not required.issubset(users):
        raise SmokeFailure("fake-Auth state does not contain all required identities")
    return users


def expect_rpc_denied(
    api: HostedApi,
    token: str,
    name: str,
    body: dict[str, Any],
    expected_marker: str,
) -> None:
    try:
        api.rpc(token, name, body)
    except SmokeFailure as exc:
        if expected_marker not in str(exc):
            raise
        return
    raise SmokeFailure(f"denied RPC unexpectedly succeeded: {name}")


def run_interest_cycle() -> None:
    if os.environ.get("PHASE_2E_INTEREST_CYCLE_APPROVED") != "YES":
        raise SmokeFailure(
            "hosted interest-cycle approval flag is absent; refusing to invoke it"
        )
    for name in ("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"):
        required_env(name)
    sql = """
begin;
set local statement_timeout = '30s';
set local lock_timeout = '5s';
select count(*)
from app_private.run_interest_accrual_cycle(
  statement_timestamp() + interval '2 days',
  'TEST',
  3
);
commit;
"""
    result = subprocess.run(
        [
            "psql",
            "-X",
            "--no-psqlrc",
            "--quiet",
            "--set",
            "ON_ERROR_STOP=1",
            "--command",
            sql,
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=45,
    )
    if result.returncode != 0:
        raise SmokeFailure("approved controlled interest cycle failed")


def one(rows: list[dict[str, Any]], label: str) -> dict[str, Any]:
    if len(rows) != 1:
        raise SmokeFailure(f"expected one row for {label}, found {len(rows)}")
    return rows[0]


def main() -> int:
    try:
        project_ref = required_env("SUPABASE_PROJECT_ID")
        expected_region = required_env("SUPABASE_EXPECTED_REGION")
        verify_cli_project(ROOT, project_ref, expected_region)
        verify_local_link(ROOT, project_ref)
        verify_postgres_environment(project_ref)
        key = publishable_key(project_ref)
        credentials = load_credentials()
        api = HostedApi(project_ref, key)
        tokens = {
            label: api.login(user["email"], user["password"])
            for label, user in credentials.items()
            if label in {
                "owner-a",
                "owner-checker",
                "manager-a",
                "attendant-a",
                "isolation-owner",
            }
        }
        owner = tokens["owner-a"]
        checker = tokens["owner-checker"]
        manager = tokens["manager-a"]
        attendant = tokens["attendant-a"]
        isolation = tokens["isolation-owner"]
        run_marker = uuid.uuid4().hex[:12]

        auth_settings = api.request("GET", "/auth/v1/settings")
        if auth_settings.get("disable_signup") is not True:
            raise SmokeFailure("public Auth signup is not disabled")

        def create_customer(token: str, role_marker: str, limit: int) -> dict[str, Any]:
            return one(
                api.rpc(
                    token,
                    "create_customer_with_credit_account",
                    {
                        "p_station_id": STATION_ID,
                        "p_first_name": "Development",
                        "p_last_name": role_marker,
                        "p_phone": f"fake-phone-{run_marker}-{role_marker.lower()}",
                        "p_display_name": f"DEVELOPMENT {role_marker} CUSTOMER - NOT REAL",
                        "p_alternate_phone": None,
                        "p_address": None,
                        "p_credit_limit_paise": limit,
                        "p_default_annual_interest_rate": "0.18000000",
                        "p_grace_days": 0,
                        "p_grace_policy": "AFTER_GRACE_ONLY",
                        "p_due_days": 30,
                        "p_request_id": str(uuid.uuid4()),
                    },
                ),
                f"{role_marker} customer creation",
            )

        owner_customer = create_customer(owner, "OWNER", 30000)
        manager_customer = create_customer(manager, "MANAGER", 15000)
        denied_customer_body = {
            "p_station_id": STATION_ID,
            "p_first_name": "Development",
            "p_last_name": "DENIED",
            "p_phone": f"fake-phone-{run_marker}-denied",
            "p_display_name": "DEVELOPMENT DENIED CUSTOMER - NOT REAL",
            "p_alternate_phone": None,
            "p_address": None,
            "p_credit_limit_paise": 1000,
            "p_default_annual_interest_rate": "0.18000000",
            "p_grace_days": 0,
            "p_grace_policy": "AFTER_GRACE_ONLY",
            "p_due_days": 30,
            "p_request_id": str(uuid.uuid4()),
        }
        expect_rpc_denied(
            api,
            attendant,
            "create_customer_with_credit_account",
            denied_customer_body,
            "CUST_FORBIDDEN",
        )

        owner_account = owner_customer["credit_account_id"]
        fuel_key = str(uuid.uuid4())
        fuel_body = {
            "p_credit_account_id": owner_account,
            "p_station_id": STATION_ID,
            "p_fuel_product_id": PRODUCT_ID,
            "p_amount_paise": 10000,
            "p_idempotency_key": fuel_key,
            "p_source_reference": f"P2E-FUEL-{run_marker.upper()}",
        }
        fuel = one(api.rpc(attendant, "post_fuel_credit_transaction", fuel_body), "fuel")
        if int(fuel["available_credit_paise"]) != 20000:
            raise SmokeFailure("fuel posting did not reduce available credit")
        replay = one(
            api.rpc(attendant, "post_fuel_credit_transaction", fuel_body),
            "fuel replay",
        )
        if replay["transaction_id"] != fuel["transaction_id"] or not replay[
            "idempotent_replay"
        ]:
            raise SmokeFailure("same fuel request did not replay safely")
        changed = dict(fuel_body)
        changed["p_amount_paise"] = 10001
        expect_rpc_denied(
            api,
            attendant,
            "post_fuel_credit_transaction",
            changed,
            "IDEMPOTENCY",
        )

        repayment = one(
            api.rpc(
                attendant,
                "post_customer_repayment",
                {
                    "p_credit_account_id": owner_account,
                    "p_station_id": STATION_ID,
                    "p_total_amount_paise": 2000,
                    "p_allocation_mode": "PRINCIPAL_ONLY",
                    "p_idempotency_key": str(uuid.uuid4()),
                    "p_principal_allocation_paise": 2000,
                    "p_interest_allocation_paise": None,
                    "p_payer_driver_id": None,
                    "p_source_reference": f"P2E-REPAY-{run_marker.upper()}",
                    "p_payment_method": "CASH",
                },
            ),
            "principal repayment",
        )
        if int(repayment["outstanding_principal_paise"]) != 8000:
            raise SmokeFailure("principal repayment produced the wrong balance")
        if int(repayment["available_credit_paise"]) != 22000:
            raise SmokeFailure("principal repayment produced the wrong available credit")

        try:
            api.rpc(
                attendant,
                "run_interest_accrual_cycle",
                {
                    "target_requested_at": "2026-01-01T00:00:00Z",
                    "target_trigger_source": "TEST",
                    "target_max_catch_up_days": 1,
                },
            )
        except SmokeFailure:
            pass
        else:
            raise SmokeFailure("private interest engine was callable over the public API")

        run_interest_cycle()
        obligations = one(
            api.rpc(
                attendant,
                "get_credit_account_obligations",
                {"p_credit_account_id": owner_account},
            ),
            "post-interest obligations",
        )
        interest_due = int(obligations["outstanding_interest_paise"])
        if interest_due <= 0:
            raise SmokeFailure("controlled interest cycle did not create fake interest")
        interest_payment = one(
            api.rpc(
                attendant,
                "post_customer_repayment",
                {
                    "p_credit_account_id": owner_account,
                    "p_station_id": STATION_ID,
                    "p_total_amount_paise": interest_due,
                    "p_allocation_mode": "INTEREST_ONLY",
                    "p_idempotency_key": str(uuid.uuid4()),
                    "p_principal_allocation_paise": None,
                    "p_interest_allocation_paise": interest_due,
                    "p_payer_driver_id": None,
                    "p_source_reference": f"P2E-INT-{run_marker.upper()}",
                    "p_payment_method": "CASH",
                },
            ),
            "interest repayment",
        )
        if int(interest_payment["available_credit_paise"]) != 22000:
            raise SmokeFailure("interest repayment incorrectly changed available credit")

        correction_fuel = one(
            api.rpc(
                attendant,
                "post_fuel_credit_transaction",
                {
                    "p_credit_account_id": manager_customer["credit_account_id"],
                    "p_station_id": STATION_ID,
                    "p_fuel_product_id": PRODUCT_ID,
                    "p_amount_paise": 5000,
                    "p_idempotency_key": str(uuid.uuid4()),
                    "p_source_reference": f"P2E-COR-{run_marker.upper()}",
                },
            ),
            "correction source fuel",
        )
        submit_body = {
            "p_original_transaction_id": correction_fuel["transaction_id"],
            "p_action": "REVERSAL_ONLY",
            "p_reason_category": "OPERATIONAL_ERROR",
            "p_explanation": "Development smoke fixture duplicate entry; fake data only.",
            "p_submission_idempotency_key": str(uuid.uuid4()),
            "p_replacement_fuel_product_id": None,
            "p_replacement_fuel_amount_paise": None,
            "p_replacement_fuel_source_reference": None,
            "p_replacement_repayment_amount_paise": None,
            "p_replacement_allocation_mode": None,
            "p_replacement_principal_allocation_paise": None,
            "p_replacement_interest_allocation_paise": None,
            "p_replacement_payer_driver_id": None,
            "p_replacement_source_reference": None,
            "p_replacement_payment_method": None,
        }
        correction = one(
            api.rpc(manager, "submit_financial_correction_request", submit_body),
            "correction submission",
        )
        expect_rpc_denied(
            api,
            manager,
            "approve_and_execute_financial_correction",
            {
                "p_request_id": correction["request_id"],
                "p_expected_version": correction["version"],
            },
            "COR_SELF_APPROVAL_FORBIDDEN",
        )
        approved = one(
            api.rpc(
                checker,
                "approve_and_execute_financial_correction",
                {
                    "p_request_id": correction["request_id"],
                    "p_expected_version": correction["version"],
                },
            ),
            "correction approval",
        )
        if approved["status"] != "APPROVED_AND_EXECUTED":
            raise SmokeFailure("correction did not reach approved/executed status")

        original = one(
            api.select(
                checker,
                "ledger_transactions",
                urllib.parse.urlencode(
                    {
                        "id": f"eq.{correction_fuel['transaction_id']}",
                        "select": "id,amount_paise,status",
                    }
                ),
            ),
            "original immutable transaction",
        )
        if int(original["amount_paise"]) != 5000 or original["status"] != "POSTED":
            raise SmokeFailure("original transaction was mutated")

        reversals = api.select(
            checker,
            "financial_reversals",
            urllib.parse.urlencode(
                {
                    "original_transaction_id": f"eq.{correction_fuel['transaction_id']}",
                    "select": "reversal_transaction_id",
                }
            ),
        )
        reversal = one(reversals, "financial reversal evidence")
        if reversal["reversal_transaction_id"] != approved["reversal_transaction_id"]:
            raise SmokeFailure("reversal evidence does not match approval result")
        entry_query = lambda transaction_id: urllib.parse.urlencode(
            {
                "transaction_id": f"eq.{transaction_id}",
                "select": "account_code,direction,amount_paise",
                "order": "account_code.asc",
            }
        )
        original_entries = api.select(
            checker,
            "ledger_entries",
            entry_query(correction_fuel["transaction_id"]),
        )
        reversal_entries = api.select(
            checker,
            "ledger_entries",
            entry_query(approved["reversal_transaction_id"]),
        )
        expected_reversal = sorted(
            (
                entry["account_code"],
                "CREDIT" if entry["direction"] == "DEBIT" else "DEBIT",
                int(entry["amount_paise"]),
            )
            for entry in original_entries
        )
        actual_reversal = sorted(
            (
                entry["account_code"],
                entry["direction"],
                int(entry["amount_paise"]),
            )
            for entry in reversal_entries
        )
        if actual_reversal != expected_reversal:
            raise SmokeFailure("reversal ledger entries are not exact opposites")

        cross_tenant = api.select(
            isolation,
            "credit_accounts",
            urllib.parse.urlencode({"id": f"eq.{owner_account}", "select": "id"}),
        )
        if cross_tenant:
            raise SmokeFailure("cross-tenant account read was not denied")

        anonymous_denied = False
        try:
            rows = api.select(None, "organizations", "select=id")
            anonymous_denied = not rows
        except SmokeFailure:
            anonymous_denied = True
        if not anonymous_denied:
            raise SmokeFailure("anonymous organization access was not denied")

        for table, row_id, mutation in (
            ("ledger_transactions", fuel["transaction_id"], {"amount_paise": 1}),
            (
                "audit_events",
                "e9000000-0000-0000-0000-000000000001",
                {"reason": "forbidden mutation"},
            ),
            (
                "financial_correction_events",
                None,
                {"event_type": "CANCELLED"},
            ),
        ):
            path = f"/rest/v1/{table}"
            if row_id:
                path += "?" + urllib.parse.urlencode({"id": f"eq.{row_id}"})
            denied = api.request(
                "PATCH",
                path,
                token=attendant,
                body=mutation,
                prefer="return=minimal",
                expected=(401, 403, 404),
            )
            if isinstance(denied, list):
                raise SmokeFailure(f"direct mutation unexpectedly succeeded: {table}")

        print(
            "PASS: 23 hosted functional checks passed for fake owner/manager/"
            "attendant workflows, idempotency, repayment, approved interest, "
            "maker-checker correction, exact reversal, isolation, and raw-write denial."
        )
        return 0
    except (
        SmokeFailure,
        KeyError,
        OSError,
        subprocess.TimeoutExpired,
        TargetSafetyFailure,
    ) as exc:
        print(f"FAIL: hosted functional smoke: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
