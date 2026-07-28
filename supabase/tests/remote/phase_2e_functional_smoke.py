#!/usr/bin/env python3
"""Run the approved Phase 2E hosted functional and authorization smoke.

The harness is deliberately bound to one fake-data development project. It
uses password sign-in and each actor's ordinary JWT for application behavior.
The only database-owner operations are the repository-controlled isolation
fixture and the separately approved deterministic private interest cycle.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from decimal import Decimal, ROUND_HALF_UP, getcontext
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

from phase_2e_target_safety import (  # noqa: E402
    TargetSafetyFailure,
    npx_executable,
    verify_local_link,
)


CLI_VERSION = "2.109.1"
EXPECTED_PROJECT_REF = "pjjbjeqkktxnphavolvf"
EXPECTED_ORGANIZATION_ID = "etuzckorqalyqcmcdcyv"
EXPECTED_PROJECT_NAME = "credit-accounting-development"
EXPECTED_REGION = "ap-south-1"
EXPECTED_STATUS = "ACTIVE_HEALTHY"
EXPECTED_MIGRATIONS = 25

PRIMARY_ORGANIZATION_ID = "e0000000-0000-0000-0000-000000000001"
PRIMARY_STATION_ID = "e1000000-0000-0000-0000-000000000001"
ISOLATION_ORGANIZATION_ID = "e0000000-0000-0000-0000-000000000002"
ISOLATION_STATION_ID = "e1000000-0000-0000-0000-000000000002"
PETROL_PRODUCT_ID = "ef100000-0000-0000-0000-000000000001"
BASELINE_CUSTOMER_ID = "e2000000-0000-0000-0000-000000000001"
BASELINE_ACCOUNT_ID = "e3000000-0000-0000-0000-000000000001"
BASELINE_DRIVER_ID = "e4000000-0000-0000-0000-000000000001"

STATE_FILE = ROOT / ".local-state" / "phase-2e-auth.json"
EVIDENCE_FILE = ROOT / ".local-state" / "phase-2e-smoke-latest.json"
ISOLATION_FIXTURE = (
    ROOT / "supabase" / "fixtures" / "development_smoke_isolation.sql"
)
EXPECTED_LABELS = {
    "owner-a",
    "owner-b",
    "manager",
    "attendant",
    "customer",
    "driver",
    "unauthorized",
}
FINANCIAL_TABLES = (
    "fuel_credit_sales",
    "ledger_transactions",
    "ledger_entries",
    "customer_repayments",
    "repayment_allocations",
    "interest_accruals",
    "interest_accrual_components",
    "idempotency_keys",
    "financial_correction_requests",
    "financial_correction_events",
    "financial_reversals",
    "audit_events",
)
NUMERIC_API_TOLERANCE = Decimal("0.000000000001")


class SmokeFailure(RuntimeError):
    """A functional, accounting, or security assertion failed."""


class ApiError(RuntimeError):
    """A sanitized hosted API failure (never contains credentials)."""

    def __init__(self, status: int, code: str, message: str) -> None:
        self.status = status
        self.code = code
        self.safe_message = message[:180]
        super().__init__(
            f"HTTP {status}; code={code}; message={self.safe_message}"
        )


def cli_result(*arguments: str, timeout: int = 90) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            npx_executable(),
            "--yes",
            f"supabase@{CLI_VERSION}",
            *arguments,
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=timeout,
    )


def cli_json(*arguments: str) -> Any:
    result = cli_result(*arguments, "--output", "json")
    if result.returncode != 0:
        raise SmokeFailure("Supabase CLI inspection failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SmokeFailure("Supabase CLI returned unexpected project data") from exc


def verify_target() -> None:
    project_ref = os.environ.get("SUPABASE_PROJECT_ID", "").strip()
    expected_region = os.environ.get("SUPABASE_EXPECTED_REGION", "").strip()
    if (
        project_ref != EXPECTED_PROJECT_REF
        or expected_region != EXPECTED_REGION
    ):
        raise SmokeFailure("selected target is not the approved development project")

    projects = cli_json("projects", "list")
    matches = [
        item
        for item in projects
        if isinstance(item, dict)
        and (item.get("ref") == project_ref or item.get("id") == project_ref)
    ]
    if len(matches) != 1:
        raise SmokeFailure("approved project is not uniquely accessible")
    project = matches[0]
    expected = {
        "name": EXPECTED_PROJECT_NAME,
        "organization_id": EXPECTED_ORGANIZATION_ID,
        "region": EXPECTED_REGION,
        "status": EXPECTED_STATUS,
    }
    if any(project.get(key) != value for key, value in expected.items()):
        raise SmokeFailure("approved project identity or health does not match")
    verify_local_link(ROOT, EXPECTED_PROJECT_REF)

    local_versions = sorted(
        path.name.split("_", 1)[0]
        for path in (ROOT / "supabase" / "migrations").glob("*.sql")
    )
    migrations = cli_result("migration", "list", "--linked")
    if migrations.returncode != 0:
        raise SmokeFailure("could not verify hosted migration history")
    try:
        migration_payload = json.loads(migrations.stdout)
        pairs = [
            (str(item.get("local", "")), str(item.get("remote", "")))
            for item in migration_payload.get("migrations", [])
            if isinstance(item, dict)
        ]
    except (json.JSONDecodeError, AttributeError):
        pairs = re.findall(
            r"`?(\d{14})`?\s*\|\s*`?(\d{14})`?",
            migrations.stdout,
        )
    remote_versions = [remote for local, remote in pairs if local == remote]
    if (
        len(pairs) != EXPECTED_MIGRATIONS
        or len(remote_versions) != EXPECTED_MIGRATIONS
        or local_versions != remote_versions
    ):
        raise SmokeFailure("local and hosted migration histories differ")


def project_publishable_key() -> str:
    payload = cli_json(
        "projects",
        "api-keys",
        "--project-ref",
        EXPECTED_PROJECT_REF,
    )
    items = payload if isinstance(payload, list) else payload.get("api_keys", [])
    candidates: list[tuple[int, str]] = []
    for item in items:
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
        raise SmokeFailure("no normal public project key was available")
    return sorted(candidates)[0][1]


class HostedApi:
    def __init__(self, publishable_key: str) -> None:
        self.base = f"https://{EXPECTED_PROJECT_REF}.supabase.co"
        self.key = publishable_key

    def request(
        self,
        method: str,
        path: str,
        *,
        token: str | None = None,
        body: Any = None,
        prefer: str | None = None,
        profile: str | None = None,
    ) -> Any:
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = {
            "apikey": self.key,
            "Authorization": f"Bearer {token or self.key}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "credit-accounting-phase-2e-functional-smoke",
        }
        if prefer:
            headers["Prefer"] = prefer
        if profile:
            headers["Accept-Profile"] = profile
            headers["Content-Profile"] = profile
        request = urllib.request.Request(
            f"{self.base}{path}",
            method=method,
            data=data,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = response.read()
                return json.loads(payload) if payload else None
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            try:
                error = json.loads(payload.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                error = {}
            raise ApiError(
                exc.code,
                str(
                    error.get("code")
                    or error.get("error_code")
                    or "unclassified"
                ),
                str(error.get("message") or error.get("msg") or ""),
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
            raise SmokeFailure("a fake development identity could not sign in")
        return token

    def rpc(
        self,
        token: str | None,
        name: str,
        body: dict[str, Any],
        *,
        profile: str | None = None,
    ) -> list[dict[str, Any]]:
        payload = self.request(
            "POST",
            f"/rest/v1/rpc/{name}",
            token=token,
            body=body,
            profile=profile,
        )
        if not isinstance(payload, list) or not payload:
            raise SmokeFailure(f"RPC returned no rows: {name}")
        return payload

    def select(
        self,
        token: str | None,
        table: str,
        *,
        select: str = "id",
        filters: dict[str, str] | None = None,
        order: str | None = None,
    ) -> list[dict[str, Any]]:
        query: dict[str, str] = {"select": select}
        if filters:
            query.update(filters)
        if order:
            query["order"] = order
        payload = self.request(
            "GET",
            f"/rest/v1/{table}?{urllib.parse.urlencode(query)}",
            token=token,
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
        item.get("label"): item
        for item in payload.get("users", [])
        if isinstance(item, dict)
    }
    if set(users) != EXPECTED_LABELS:
        raise SmokeFailure("fake-Auth state is not the exact seven-user set")
    for item in users.values():
        if not all(str(item.get(key, "")).strip() for key in ("email", "password", "user_id")):
            raise SmokeFailure("fake-Auth state is incomplete")
    return users


def execute_isolation_fixture() -> None:
    if not ISOLATION_FIXTURE.is_file():
        raise SmokeFailure("repository-controlled isolation fixture is missing")
    result = cli_result(
        "db",
        "query",
        "--linked",
        "--file",
        str(ISOLATION_FIXTURE),
        "--output-format",
        "json",
    )
    if result.returncode != 0:
        raise SmokeFailure("approved isolation fixture failed")


def database_query_rows(sql: str) -> tuple[int, list[dict[str, Any]]]:
    normalized_sql = " ".join(sql.split())
    result = cli_result(
        "db",
        "query",
        "--linked",
        normalized_sql,
        "--output-format",
        "json",
    )
    try:
        rows = json.loads(result.stdout).get("rows", [])
    except (json.JSONDecodeError, AttributeError):
        rows = []
    return result.returncode, rows


def run_interest_cycle(account_id: str) -> dict[str, Any]:
    if os.environ.get("PHASE_2E_INTEREST_CYCLE_APPROVED") != "YES":
        raise SmokeFailure(
            "approved private interest-cycle safety flag is absent"
        )
    result_code, rows = database_query_rows(
        f"""
do $phase_2e$
begin
  if not exists (
    select 1
    from public.interest_accruals
    where credit_account_id = '{account_id}'::uuid
      and posted_interest_paise > 0
  ) then
    perform *
    from app_private.run_interest_accrual_cycle(
      statement_timestamp() + interval '2 days',
      'TEST',
      3
    );
  end if;
end
$phase_2e$;

select
  run.id as interest_accrual_run_id,
  run.station_id,
  run.status as run_status,
  run.result_code,
  run.more_dates_pending,
  run.request_id,
  run.accounts_examined,
  run.account_days_processed,
  run.accrual_rows_created,
  run.components_created,
  run.interest_posted_paise
from public.interest_accrual_runs as run
where run.station_id = '{PRIMARY_STATION_ID}'::uuid
  and run.trigger_source = 'TEST'
  and exists (
    select 1
    from public.interest_accruals as accrual
    where accrual.run_id = run.id
      and accrual.credit_account_id = '{account_id}'::uuid
      and accrual.posted_interest_paise > 0
  )
order by run.created_at desc
limit 1;
"""
    )
    if result_code != 0:
        raise SmokeFailure("approved controlled private interest cycle failed")
    if not rows:
        raise SmokeFailure("controlled interest cycle created no positive account run")
    return one(rows, "account-scoped controlled interest run")


def one(rows: list[dict[str, Any]], label: str) -> dict[str, Any]:
    if len(rows) != 1:
        raise SmokeFailure(f"expected one row for {label}, found {len(rows)}")
    return rows[0]


def query_ids(values: list[str]) -> str:
    return f"in.({','.join(values)})"


def expect_api_denied(
    operation: Callable[[], Any],
    label: str,
    marker: str | None = None,
) -> dict[str, Any]:
    try:
        operation()
    except ApiError as exc:
        if marker and marker not in f"{exc.code} {exc.safe_message}":
            raise SmokeFailure(
                f"{label} returned the wrong deterministic denial"
            ) from exc
        return {"status": exc.status, "code": exc.code, "marker": marker}
    raise SmokeFailure(f"{label} unexpectedly succeeded")


def assert_empty(rows: list[dict[str, Any]], label: str) -> None:
    if rows:
        raise SmokeFailure(f"{label} unexpectedly exposed rows")


def assert_nonempty(rows: list[dict[str, Any]], label: str) -> None:
    if not rows:
        raise SmokeFailure(f"{label} did not prove a positive same-scope read")


def balances(api: HostedApi, token: str, account_id: str) -> dict[str, Any]:
    return one(
        api.rpc(
            token,
            "get_credit_account_obligations",
            {"p_credit_account_id": account_id},
        ),
        "account obligations",
    )


def count_snapshot(api: HostedApi, token: str) -> dict[str, int]:
    return {
        table: len(api.select(token, table))
        for table in FINANCIAL_TABLES
    }


def assert_snapshot(
    before: dict[str, int],
    after: dict[str, int],
    label: str,
) -> None:
    if before != after:
        changed = sorted(key for key in before if before[key] != after[key])
        raise SmokeFailure(f"{label} left partial rows in: {', '.join(changed)}")


def assert_obligations(
    row: dict[str, Any],
    *,
    principal: int,
    interest: int,
    available: int,
    label: str,
) -> None:
    actual = (
        int(row["outstanding_principal_paise"]),
        int(row["outstanding_interest_paise"]),
        int(row["total_due_paise"]),
        int(row["available_credit_paise"]),
    )
    expected = (principal, interest, principal + interest, available)
    if actual != expected:
        raise SmokeFailure(f"{label} obligation reconciliation failed")


def ledger_entries(
    api: HostedApi,
    token: str,
    transaction_id: str,
) -> list[dict[str, Any]]:
    return api.select(
        token,
        "ledger_entries",
        select="id,account_code,direction,amount_paise,currency_code",
        filters={"transaction_id": f"eq.{transaction_id}"},
        order="account_code.asc",
    )


def assert_posting(
    entries: list[dict[str, Any]],
    expected: set[tuple[str, str, int]],
    label: str,
) -> None:
    actual = {
        (
            str(item["account_code"]),
            str(item["direction"]),
            int(item["amount_paise"]),
        )
        for item in entries
    }
    debits = sum(
        int(item["amount_paise"])
        for item in entries
        if item["direction"] == "DEBIT"
    )
    credits = sum(
        int(item["amount_paise"])
        for item in entries
        if item["direction"] == "CREDIT"
    )
    if actual != expected or debits != credits or debits <= 0:
        raise SmokeFailure(f"{label} ledger reconciliation failed")


def customer_body(
    station_id: str,
    run_marker: str,
    actor: str,
    limit: int,
    request_id: str,
    phone_suffix: int,
) -> dict[str, Any]:
    return {
        "p_station_id": station_id,
        "p_first_name": "Development",
        "p_last_name": actor,
        "p_phone": f"+999{phone_suffix:012d}",
        "p_display_name": f"DEVELOPMENT {actor} {run_marker} - NOT REAL",
        "p_alternate_phone": None,
        "p_address": None,
        "p_credit_limit_paise": limit,
        "p_default_annual_interest_rate": "0.18000000",
        "p_grace_days": 0,
        "p_grace_policy": "AFTER_GRACE_ONLY",
        "p_due_days": 30,
        "p_request_id": request_id,
    }


def repayment_body(
    account_id: str,
    amount: int,
    mode: str,
    idempotency_key: str,
    source: str,
    *,
    principal: int | None,
    interest: int | None,
) -> dict[str, Any]:
    return {
        "p_credit_account_id": account_id,
        "p_station_id": PRIMARY_STATION_ID,
        "p_total_amount_paise": amount,
        "p_allocation_mode": mode,
        "p_idempotency_key": idempotency_key,
        "p_principal_allocation_paise": principal,
        "p_interest_allocation_paise": interest,
        "p_payer_driver_id": None,
        "p_source_reference": source,
        "p_payment_method": "CASH",
    }


def submit_correction(
    api: HostedApi,
    token: str,
    transaction_id: str,
    run_marker: str,
    actor: str,
) -> dict[str, Any]:
    return one(
        api.rpc(
            token,
            "submit_financial_correction_request",
            {
                "p_original_transaction_id": transaction_id,
                "p_action": "REVERSAL_ONLY",
                "p_reason_category": "OPERATIONAL_ERROR",
                "p_explanation": (
                    f"Development {actor} smoke correction {run_marker}; "
                    "synthetic data only."
                ),
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
            },
        ),
        f"{actor} correction submission",
    )


def verify_read_matrix(
    api: HostedApi,
    tokens: dict[str, str],
    owner_customer_id: str,
    owner_account_id: str,
    isolation_customer_id: str,
    isolation_account_id: str,
    primary_transaction_id: str,
) -> None:
    owner = tokens["owner-a"]
    manager = tokens["manager"]
    attendant = tokens["attendant"]
    customer = tokens["customer"]
    driver = tokens["driver"]
    isolation = tokens["unauthorized"]

    assert_nonempty(
        api.select(
            owner,
            "customers",
            filters={"id": f"eq.{owner_customer_id}"},
        ),
        "primary owner same-tenant customer read",
    )
    assert_nonempty(
        api.select(
            isolation,
            "customers",
            filters={"id": f"eq.{isolation_customer_id}"},
        ),
        "isolation owner same-tenant customer read",
    )
    for actor, token in (("owner", owner), ("manager", manager)):
        assert_empty(
            api.select(
                token,
                "organizations",
                filters={"id": f"eq.{ISOLATION_ORGANIZATION_ID}"},
            ),
            f"{actor} isolation-organization read",
        )
        assert_empty(
            api.select(
                token,
                "customers",
                filters={"id": f"eq.{isolation_customer_id}"},
            ),
            f"{actor} isolation-customer read",
        )
        assert_empty(
            api.select(
                token,
                "credit_accounts",
                filters={"id": f"eq.{isolation_account_id}"},
            ),
            f"{actor} isolation-account read",
        )

    assert_empty(
        api.select(
            isolation,
            "customers",
            filters={"id": f"eq.{owner_customer_id}"},
        ),
        "isolation actor primary customer read",
    )
    assert_empty(
        api.select(
            isolation,
            "credit_accounts",
            filters={"id": f"eq.{owner_account_id}"},
        ),
        "isolation actor primary account read",
    )
    assert_empty(
        api.select(
            isolation,
            "ledger_transactions",
            filters={"id": f"eq.{primary_transaction_id}"},
        ),
        "isolation actor primary financial read",
    )

    assert_nonempty(
        api.select(
            manager,
            "customers",
            filters={"id": f"eq.{owner_customer_id}"},
        ),
        "manager same-station customer read",
    )
    assert_nonempty(
        api.select(
            manager,
            "ledger_transactions",
            filters={"id": f"eq.{primary_transaction_id}"},
        ),
        "manager same-station financial read",
    )
    assert_nonempty(
        api.select(
            attendant,
            "stations",
            filters={"id": f"eq.{PRIMARY_STATION_ID}"},
        ),
        "attendant own-station read",
    )
    assert_nonempty(
        api.select(
            attendant,
            "fuel_products",
            filters={"id": f"eq.{PETROL_PRODUCT_ID}"},
        ),
        "attendant own-station product read",
    )
    assert_empty(
        api.select(
            attendant,
            "customers",
            filters={"id": f"eq.{owner_customer_id}"},
        ),
        "attendant customer read",
    )
    assert_empty(
        api.select(
            attendant,
            "ledger_transactions",
            filters={"id": f"eq.{primary_transaction_id}"},
        ),
        "attendant financial read",
    )

    assert_nonempty(
        api.select(
            customer,
            "customers",
            filters={"id": f"eq.{BASELINE_CUSTOMER_ID}"},
        ),
        "linked customer self read",
    )
    assert_nonempty(
        api.select(
            customer,
            "credit_accounts",
            filters={"id": f"eq.{BASELINE_ACCOUNT_ID}"},
        ),
        "linked customer own-account read",
    )
    assert_empty(
        api.select(
            customer,
            "customers",
            filters={"id": f"eq.{owner_customer_id}"},
        ),
        "linked customer unrelated-customer read",
    )
    assert_empty(
        api.select(
            customer,
            "ledger_transactions",
            filters={"id": f"eq.{primary_transaction_id}"},
        ),
        "linked customer financial read",
    )

    assert_nonempty(
        api.select(
            driver,
            "customer_drivers",
            filters={"id": f"eq.{BASELINE_DRIVER_ID}"},
        ),
        "driver self read",
    )
    assert_nonempty(
        api.select(
            driver,
            "driver_permissions",
            select="driver_id",
            filters={"driver_id": f"eq.{BASELINE_DRIVER_ID}"},
        ),
        "driver permission read",
    )
    assert_nonempty(
        api.rpc(driver, "get_my_driver_parent_account", {}),
        "driver parent-account RPC",
    )
    assert_empty(
        api.select(
            driver,
            "customers",
            filters={"id": f"eq.{owner_customer_id}"},
        ),
        "driver unrelated-customer read",
    )
    assert_empty(
        api.select(
            driver,
            "ledger_transactions",
            filters={"id": f"eq.{primary_transaction_id}"},
        ),
        "driver financial read",
    )


def direct_mutation_denials(
    api: HostedApi,
    tokens: dict[str, str],
    fuel: dict[str, Any],
    audit_id: str,
    correction_event_id: str,
    interest_accrual_id: str,
) -> dict[str, Any]:
    owner = tokens["owner-a"]
    attendant = tokens["attendant"]
    before = count_snapshot(api, owner)
    common = {
        "organization_id": PRIMARY_ORGANIZATION_ID,
        "station_id": PRIMARY_STATION_ID,
        "credit_account_id": fuel["credit_account_id"],
        "customer_id": fuel["customer_id"],
        "transaction_type": "FUEL_CREDIT",
        "status": "POSTED",
        "amount_paise": 1,
        "currency_code": "INR",
        "created_by": "00000000-0000-0000-0000-000000000000",
    }
    evidence = {
        "ledger_insert": expect_api_denied(
            lambda: api.request(
                "POST",
                "/rest/v1/ledger_transactions",
                token=attendant,
                body=common,
                prefer="return=representation",
            ),
            "direct ledger insert",
        ),
        "ledger_update": expect_api_denied(
            lambda: api.request(
                "PATCH",
                "/rest/v1/ledger_transactions?"
                + urllib.parse.urlencode({"id": f"eq.{fuel['transaction_id']}"}),
                token=owner,
                body={"amount_paise": 1, "transaction_type": "FINANCIAL_REVERSAL"},
                prefer="return=representation",
            ),
            "direct ledger update/reclassification",
        ),
        "ledger_delete": expect_api_denied(
            lambda: api.request(
                "DELETE",
                "/rest/v1/ledger_transactions?"
                + urllib.parse.urlencode({"id": f"eq.{fuel['transaction_id']}"}),
                token=owner,
                prefer="return=representation",
            ),
            "direct ledger delete",
        ),
        "audit_update": expect_api_denied(
            lambda: api.request(
                "PATCH",
                "/rest/v1/audit_events?"
                + urllib.parse.urlencode({"id": f"eq.{audit_id}"}),
                token=owner,
                body={"reason": "forbidden synthetic mutation"},
                prefer="return=representation",
            ),
            "direct audit mutation",
        ),
        "correction_event_update": expect_api_denied(
            lambda: api.request(
                "PATCH",
                "/rest/v1/financial_correction_events?"
                + urllib.parse.urlencode({"id": f"eq.{correction_event_id}"}),
                token=owner,
                body={"event_type": "CANCELLED"},
                prefer="return=representation",
            ),
            "direct correction-event mutation",
        ),
        "interest_insert": expect_api_denied(
            lambda: api.request(
                "POST",
                "/rest/v1/interest_accruals",
                token=owner,
                body={"id": str(uuid.uuid4())},
                prefer="return=representation",
            ),
            "direct interest-evidence insert",
        ),
        "interest_update": expect_api_denied(
            lambda: api.request(
                "PATCH",
                "/rest/v1/interest_accruals?"
                + urllib.parse.urlencode({"id": f"eq.{interest_accrual_id}"}),
                token=owner,
                body={"posted_interest_paise": 999},
                prefer="return=representation",
            ),
            "direct interest-evidence update",
        ),
    }
    assert_snapshot(before, count_snapshot(api, owner), "raw mutation denials")
    original = one(
        api.select(
            owner,
            "ledger_transactions",
            select="id,transaction_type,status,amount_paise",
            filters={"id": f"eq.{fuel['transaction_id']}"},
        ),
        "immutable fuel transaction",
    )
    if (
        original["transaction_type"] != "FUEL_CREDIT"
        or original["status"] != "POSTED"
        or int(original["amount_paise"]) != int(fuel["amount_paise"])
    ):
        raise SmokeFailure("raw mutation test changed the original transaction")
    return evidence


def main() -> int:
    evidence: dict[str, Any] = {
        "project": {
            "ref": EXPECTED_PROJECT_REF,
            "name": EXPECTED_PROJECT_NAME,
            "organization_id": EXPECTED_ORGANIZATION_ID,
            "region": EXPECTED_REGION,
            "plan": "Free/Nano",
            "migration_count": EXPECTED_MIGRATIONS,
        },
        "checks": {},
    }
    try:
        verify_target()
        execute_isolation_fixture()
        credentials = load_credentials()
        api = HostedApi(project_publishable_key())
        tokens = {
            label: api.login(item["email"], item["password"])
            for label, item in credentials.items()
        }
        if set(tokens) != EXPECTED_LABELS:
            raise SmokeFailure("not all seven fake identities authenticated")
        evidence["authentication"] = {
            "method": "normal Supabase password sign-in",
            "fake_identities": 7,
            "credential_source": "ignored local state",
        }

        owner = tokens["owner-a"]
        owner_b = tokens["owner-b"]
        manager = tokens["manager"]
        attendant = tokens["attendant"]
        customer = tokens["customer"]
        driver = tokens["driver"]
        isolation = tokens["unauthorized"]
        run_marker = uuid.uuid4().hex[:12].upper()
        phone_base = int(run_marker[:10], 16) % 900_000_000_000
        phone_base += 100_000_000_000
        evidence["run_marker"] = run_marker

        creation_request_ids = {
            name: str(uuid.uuid4())
            for name in ("owner", "manager", "isolation")
        }
        owner_customer = one(
            api.rpc(
                owner,
                "create_customer_with_credit_account",
                customer_body(
                    PRIMARY_STATION_ID,
                    run_marker,
                    "OWNER",
                    30000,
                    creation_request_ids["owner"],
                    phone_base,
                ),
            ),
            "owner customer creation",
        )
        manager_customer = one(
            api.rpc(
                manager,
                "create_customer_with_credit_account",
                customer_body(
                    PRIMARY_STATION_ID,
                    run_marker,
                    "MANAGER",
                    15000,
                    creation_request_ids["manager"],
                    phone_base + 1,
                ),
            ),
            "manager customer creation",
        )
        isolation_customer = one(
            api.rpc(
                isolation,
                "create_customer_with_credit_account",
                customer_body(
                    ISOLATION_STATION_ID,
                    run_marker,
                    "ISOLATION",
                    10000,
                    creation_request_ids["isolation"],
                    phone_base + 2,
                ),
            ),
            "isolation customer creation",
        )
        expected_creation_scopes = (
            (owner_customer, PRIMARY_ORGANIZATION_ID, PRIMARY_STATION_ID, 30000),
            (manager_customer, PRIMARY_ORGANIZATION_ID, PRIMARY_STATION_ID, 15000),
            (
                isolation_customer,
                ISOLATION_ORGANIZATION_ID,
                ISOLATION_STATION_ID,
                10000,
            ),
        )
        for row, organization_id, station_id, limit in expected_creation_scopes:
            if (
                row["organization_id"] != organization_id
                or row["station_id"] != station_id
                or int(row["credit_limit_paise"]) != limit
                or row["currency_code"] != "INR"
                or row["customer_status"] != "ACTIVE"
            ):
                raise SmokeFailure("customer/account creation scope is incorrect")
        assert_obligations(
            balances(api, owner, owner_customer["credit_account_id"]),
            principal=0,
            interest=0,
            available=30000,
            label="owner starting",
        )
        assert_obligations(
            balances(api, manager, manager_customer["credit_account_id"]),
            principal=0,
            interest=0,
            available=15000,
            label="manager starting",
        )
        assert_obligations(
            balances(api, isolation, isolation_customer["credit_account_id"]),
            principal=0,
            interest=0,
            available=10000,
            label="isolation starting",
        )
        evidence["checks"]["customer_creation"] = {
            "owner": "PASS",
            "manager": "PASS",
            "isolation_positive_fixture": "PASS",
        }

        denied_creation_before = count_snapshot(api, owner)
        denied_body = customer_body(
            PRIMARY_STATION_ID,
            run_marker,
            "DENIED",
            1000,
            str(uuid.uuid4()),
            phone_base + 3,
        )
        attendant_creation_denial = expect_api_denied(
            lambda: api.rpc(
                attendant,
                "create_customer_with_credit_account",
                denied_body,
            ),
            "attendant customer creation",
            "CCC_FORBIDDEN",
        )
        denied_body["p_request_id"] = str(uuid.uuid4())
        denied_body["p_phone"] = f"+999{phone_base + 4:012d}"
        isolation_creation_denial = expect_api_denied(
            lambda: api.rpc(
                isolation,
                "create_customer_with_credit_account",
                denied_body,
            ),
            "cross-tenant customer creation",
            "CCC_FORBIDDEN",
        )
        assert_snapshot(
            denied_creation_before,
            count_snapshot(api, owner),
            "denied customer creation",
        )
        evidence["checks"]["customer_creation_denials"] = {
            "attendant": attendant_creation_denial,
            "cross_tenant": isolation_creation_denial,
            "partial_rows": 0,
        }

        owner_account_id = str(owner_customer["credit_account_id"])
        fuel_key = str(uuid.uuid4())
        fuel_body = {
            "p_credit_account_id": owner_account_id,
            "p_station_id": PRIMARY_STATION_ID,
            "p_fuel_product_id": PETROL_PRODUCT_ID,
            "p_amount_paise": 10000,
            "p_idempotency_key": fuel_key,
            "p_source_reference": f"P2E-FUEL-{run_marker}",
        }
        fuel = one(
            api.rpc(attendant, "post_fuel_credit_transaction", fuel_body),
            "fuel posting",
        )
        if int(fuel["amount_paise"]) != 10000 or fuel["idempotent_replay"]:
            raise SmokeFailure("initial fuel posting result was incorrect")
        assert_posting(
            ledger_entries(api, owner, fuel["transaction_id"]),
            {
                ("CUSTOMER_ACCOUNTS_RECEIVABLE", "DEBIT", 10000),
                ("FUEL_SALES_REVENUE", "CREDIT", 10000),
            },
            "fuel posting",
        )
        assert_obligations(
            balances(api, owner, owner_account_id),
            principal=10000,
            interest=0,
            available=20000,
            label="post-fuel",
        )
        fuel_rows = api.select(
            owner,
            "fuel_credit_sales",
            select="id,transaction_id,amount_paise",
            filters={"transaction_id": f"eq.{fuel['transaction_id']}"},
        )
        one(fuel_rows, "fuel sale")
        fuel_audit = one(
            api.select(
                owner,
                "audit_events",
                select="id,action,entity_id,request_id",
                filters={"request_id": f"eq.{fuel_key}"},
            ),
            "fuel audit",
        )
        if (
            fuel_audit["action"] != "fuel_credit.posted"
            or fuel_audit["entity_id"] != fuel["transaction_id"]
        ):
            raise SmokeFailure("fuel audit evidence did not reconcile")

        replay = one(
            api.rpc(attendant, "post_fuel_credit_transaction", fuel_body),
            "fuel replay",
        )
        if (
            replay["transaction_id"] != fuel["transaction_id"]
            or replay["sale_id"] != fuel["sale_id"]
            or replay["idempotent_replay"] is not True
        ):
            raise SmokeFailure("fuel idempotent replay was not stable")
        for table, filters in (
            ("fuel_credit_sales", {"transaction_id": f"eq.{fuel['transaction_id']}"}),
            ("ledger_transactions", {"id": f"eq.{fuel['transaction_id']}"}),
            ("ledger_entries", {"transaction_id": f"eq.{fuel['transaction_id']}"}),
            ("audit_events", {"request_id": f"eq.{fuel_key}"}),
            ("idempotency_keys", {"idempotency_key": f"eq.{fuel_key}"}),
        ):
            expected_count = 2 if table == "ledger_entries" else 1
            if len(api.select(owner, table, filters=filters)) != expected_count:
                raise SmokeFailure("fuel replay created duplicate evidence")
        changed_fuel_before = count_snapshot(api, owner)
        changed_fuel = dict(fuel_body)
        changed_fuel["p_amount_paise"] = 10001
        changed_fuel_denial = expect_api_denied(
            lambda: api.rpc(
                attendant,
                "post_fuel_credit_transaction",
                changed_fuel,
            ),
            "changed fuel idempotency payload",
            "FCP_IDEMPOTENCY_CONFLICT",
        )
        assert_snapshot(
            changed_fuel_before,
            count_snapshot(api, owner),
            "changed fuel idempotency conflict",
        )
        evidence["checks"]["fuel"] = {
            "posting": "PASS",
            "accounting": "balanced 10000/10000 paise",
            "principal_paise": 10000,
            "interest_paise": 0,
            "available_credit_paise": 20000,
            "replay": "PASS; no duplicates",
            "changed_payload": changed_fuel_denial,
        }

        denied_fuel_before = count_snapshot(api, owner)
        fuel_denials: dict[str, Any] = {}
        for label, token, marker in (
            ("customer", customer, "FCP_FORBIDDEN"),
            ("driver", driver, "FCP_FORBIDDEN"),
            ("unauthorized", isolation, "FCP_FORBIDDEN"),
            ("anonymous", None, None),
        ):
            denied = dict(fuel_body)
            denied["p_idempotency_key"] = str(uuid.uuid4())
            denied["p_source_reference"] = f"P2E-DENY-{label.upper()}-{run_marker}"
            fuel_denials[label] = expect_api_denied(
                lambda token=token, denied=denied: api.rpc(
                    token,
                    "post_fuel_credit_transaction",
                    denied,
                ),
                f"{label} fuel posting",
                marker,
            )
            assert_snapshot(
                denied_fuel_before,
                count_snapshot(api, owner),
                f"{label} fuel denial",
            )
        evidence["checks"]["fuel_role_denials"] = fuel_denials

        principal_key = str(uuid.uuid4())
        principal_body = repayment_body(
            owner_account_id,
            2000,
            "PRINCIPAL_ONLY",
            principal_key,
            f"P2E-PRINCIPAL-{run_marker}",
            principal=2000,
            interest=None,
        )
        principal_payment = one(
            api.rpc(attendant, "post_customer_repayment", principal_body),
            "principal repayment",
        )
        if (
            int(principal_payment["principal_allocation_paise"]) != 2000
            or int(principal_payment["interest_allocation_paise"]) != 0
            or principal_payment["idempotent_replay"]
        ):
            raise SmokeFailure("principal repayment result was incorrect")
        assert_posting(
            ledger_entries(api, owner, principal_payment["transaction_id"]),
            {
                ("CASH_ON_HAND", "DEBIT", 2000),
                ("CUSTOMER_ACCOUNTS_RECEIVABLE", "CREDIT", 2000),
            },
            "principal repayment",
        )
        assert_obligations(
            balances(api, owner, owner_account_id),
            principal=8000,
            interest=0,
            available=22000,
            label="post-principal repayment",
        )
        allocations = api.select(
            owner,
            "repayment_allocations",
            select="id,component,amount_paise",
            filters={"repayment_id": f"eq.{principal_payment['repayment_id']}"},
        )
        if len(allocations) != 1 or (
            allocations[0]["component"],
            int(allocations[0]["amount_paise"]),
        ) != ("PRINCIPAL", 2000):
            raise SmokeFailure("principal repayment allocation did not reconcile")
        principal_audit = one(
            api.select(
                owner,
                "audit_events",
                filters={"request_id": f"eq.{principal_key}"},
                select="id,action,entity_id",
            ),
            "principal repayment audit",
        )
        if principal_audit["entity_id"] != principal_payment["repayment_id"]:
            raise SmokeFailure("principal repayment audit did not reconcile")
        principal_replay = one(
            api.rpc(attendant, "post_customer_repayment", principal_body),
            "principal repayment replay",
        )
        if (
            principal_replay["transaction_id"] != principal_payment["transaction_id"]
            or principal_replay["repayment_id"] != principal_payment["repayment_id"]
            or principal_replay["idempotent_replay"] is not True
        ):
            raise SmokeFailure("repayment idempotent replay was not stable")
        changed_repayment_before = count_snapshot(api, owner)
        changed_repayment = dict(principal_body)
        changed_repayment["p_total_amount_paise"] = 2001
        changed_repayment["p_principal_allocation_paise"] = 2001
        changed_repayment_denial = expect_api_denied(
            lambda: api.rpc(
                attendant,
                "post_customer_repayment",
                changed_repayment,
            ),
            "changed repayment idempotency payload",
            "RPP_IDEMPOTENCY_CONFLICT",
        )
        assert_snapshot(
            changed_repayment_before,
            count_snapshot(api, owner),
            "changed repayment idempotency conflict",
        )
        invalid_before = count_snapshot(api, owner)
        overpayment_denial = expect_api_denied(
            lambda: api.rpc(
                attendant,
                "post_customer_repayment",
                repayment_body(
                    owner_account_id,
                    9000,
                    "PRINCIPAL_ONLY",
                    str(uuid.uuid4()),
                    f"P2E-OVERPAY-{run_marker}",
                    principal=9000,
                    interest=None,
                ),
            ),
            "principal overpayment",
            "RPP_PRINCIPAL_EXCEEDS_DUE",
        )
        zero_interest_denial = expect_api_denied(
            lambda: api.rpc(
                attendant,
                "post_customer_repayment",
                repayment_body(
                    owner_account_id,
                    1,
                    "INTEREST_ONLY",
                    str(uuid.uuid4()),
                    f"P2E-ZEROINT-{run_marker}",
                    principal=None,
                    interest=1,
                ),
            ),
            "interest repayment above zero due",
            "RPP_INTEREST_EXCEEDS_DUE",
        )
        assert_snapshot(
            invalid_before,
            count_snapshot(api, owner),
            "invalid repayment denials",
        )
        evidence["checks"]["principal_repayment"] = {
            "posting": "PASS",
            "accounting": "balanced 2000/2000 paise",
            "principal_paise": 8000,
            "interest_paise": 0,
            "available_credit_paise": 22000,
            "allocation": "PRINCIPAL 2000",
            "replay": "PASS; no duplicates",
            "changed_payload": changed_repayment_denial,
            "overpayment": overpayment_denial,
            "zero_interest_overallocation": zero_interest_denial,
        }

        private_denials: dict[str, Any] = {}
        for label, token in (
            ("owner-a", owner),
            ("owner-b", owner_b),
            ("manager", manager),
            ("attendant", attendant),
            ("customer", customer),
            ("driver", driver),
            ("unauthorized", isolation),
            ("anonymous", None),
        ):
            private_denials[label] = expect_api_denied(
                lambda token=token: api.rpc(
                    token,
                    "run_interest_accrual_cycle",
                    {
                        "target_requested_at": "2026-01-01T00:00:00Z",
                        "target_trigger_source": "TEST",
                        "target_max_catch_up_days": 1,
                    },
                    profile="app_private",
                ),
                f"{label} private interest-engine call",
            )
        interest_run = run_interest_cycle(owner_account_id)
        if (
            interest_run["station_id"] != PRIMARY_STATION_ID
            or interest_run["run_status"]
            not in ("COMPLETED", "COMPLETED_WITH_REMAINING")
            or int(interest_run["interest_posted_paise"]) <= 0
        ):
            raise SmokeFailure("controlled interest run did not post positive interest")
        accruals = api.select(
            owner,
            "interest_accruals",
            select=(
                "id,run_id,business_date,credit_account_id,annual_rate,"
                "day_count_basis,eligible_principal_paise,raw_interest_paise,"
                "opening_fractional_carry_paise,posted_interest_paise,"
                "closing_fractional_carry_paise,cumulative_raw_interest_paise,"
                "cumulative_posted_interest_paise,ledger_transaction_id,"
                "component_count"
            ),
            filters={
                "run_id": f"eq.{interest_run['interest_accrual_run_id']}",
                "credit_account_id": f"eq.{owner_account_id}",
            },
            order="business_date.asc",
        )
        if not accruals or sum(int(row["posted_interest_paise"]) for row in accruals) <= 0:
            raise SmokeFailure("positive account interest evidence is missing")
        components = api.select(
            owner,
            "interest_accrual_components",
            select=(
                "id,interest_accrual_id,source_transaction_id,"
                "source_remaining_principal_paise,raw_interest_paise,"
                "annual_rate,day_count_basis"
            ),
            filters={
                "interest_accrual_id": query_ids(
                    [str(row["id"]) for row in accruals]
                )
            },
        )
        if len(components) != sum(int(row["component_count"]) for row in accruals):
            raise SmokeFailure("interest components do not match accrual evidence")
        getcontext().prec = 48
        quantum = Decimal("0.000000000000000001")
        for component in components:
            base = int(component["source_remaining_principal_paise"])
            rate = Decimal(str(component["annual_rate"]))
            raw = Decimal(str(component["raw_interest_paise"]))
            expected_raw = (
                Decimal(base) * rate / Decimal(365)
            ).quantize(quantum, rounding=ROUND_HALF_UP)
            if (
                base != 8000
                or int(component["day_count_basis"]) != 365
                or abs(raw - expected_raw) > NUMERIC_API_TOLERANCE
            ):
                raise SmokeFailure("interest component violated simple-interest math")
        for accrual in accruals:
            opening = Decimal(str(accrual["opening_fractional_carry_paise"]))
            raw = Decimal(str(accrual["raw_interest_paise"]))
            posted = Decimal(int(accrual["posted_interest_paise"]))
            closing = Decimal(str(accrual["closing_fractional_carry_paise"]))
            cumulative_raw = Decimal(str(accrual["cumulative_raw_interest_paise"]))
            cumulative_posted = Decimal(
                int(accrual["cumulative_posted_interest_paise"])
            )
            if (
                abs(opening + raw - posted - closing)
                > NUMERIC_API_TOLERANCE
            ):
                raise SmokeFailure("interest fractional-carry equation failed")
            if (
                abs(cumulative_raw - cumulative_posted - closing)
                > NUMERIC_API_TOLERANCE
            ):
                raise SmokeFailure("interest cumulative equation failed")
            if int(accrual["eligible_principal_paise"]) != 8000:
                raise SmokeFailure("interest was not based on principal only")
            if int(accrual["posted_interest_paise"]) > 0:
                assert_posting(
                    ledger_entries(api, owner, accrual["ledger_transaction_id"]),
                    {
                        (
                            "CUSTOMER_INTEREST_RECEIVABLE",
                            "DEBIT",
                            int(accrual["posted_interest_paise"]),
                        ),
                        (
                            "INTEREST_INCOME",
                            "CREDIT",
                            int(accrual["posted_interest_paise"]),
                        ),
                    },
                    "interest posting",
                )
        interest_due = sum(int(row["posted_interest_paise"]) for row in accruals)
        post_interest = balances(api, owner, owner_account_id)
        assert_obligations(
            post_interest,
            principal=8000,
            interest=interest_due,
            available=22000,
            label="post-interest",
        )
        evidence["checks"]["interest"] = {
            "private_data_api_denials": private_denials,
            "controlled_internal_execution": "PASS",
            "run_status": interest_run["run_status"],
            "accrual_rows": len(accruals),
            "components": len(components),
            "posted_interest_paise": interest_due,
            "principal_base_paise": 8000,
            "available_credit_paise": 22000,
            "model": "simple interest; no compounding; 365-day basis",
        }

        interest_key = str(uuid.uuid4())
        interest_payment = one(
            api.rpc(
                attendant,
                "post_customer_repayment",
                repayment_body(
                    owner_account_id,
                    interest_due,
                    "INTEREST_ONLY",
                    interest_key,
                    f"P2E-INTEREST-{run_marker}",
                    principal=None,
                    interest=interest_due,
                ),
            ),
            "interest repayment",
        )
        if (
            int(interest_payment["interest_allocation_paise"]) != interest_due
            or int(interest_payment["principal_allocation_paise"]) != 0
        ):
            raise SmokeFailure("interest-only repayment allocation was incorrect")
        assert_posting(
            ledger_entries(api, owner, interest_payment["transaction_id"]),
            {
                ("CASH_ON_HAND", "DEBIT", interest_due),
                (
                    "CUSTOMER_INTEREST_RECEIVABLE",
                    "CREDIT",
                    interest_due,
                ),
            },
            "interest repayment",
        )
        assert_obligations(
            balances(api, owner, owner_account_id),
            principal=8000,
            interest=0,
            available=22000,
            label="post-interest repayment",
        )
        interest_allocations = api.select(
            owner,
            "repayment_allocations",
            select="id,component,amount_paise",
            filters={"repayment_id": f"eq.{interest_payment['repayment_id']}"},
        )
        if len(interest_allocations) != 1 or (
            interest_allocations[0]["component"],
            int(interest_allocations[0]["amount_paise"]),
        ) != ("INTEREST", interest_due):
            raise SmokeFailure("interest repayment allocation did not reconcile")
        one(
            api.select(
                owner,
                "audit_events",
                filters={"request_id": f"eq.{interest_key}"},
            ),
            "interest repayment audit",
        )
        evidence["checks"]["interest_repayment"] = {
            "posting": "PASS",
            "amount_paise": interest_due,
            "principal_paise": 8000,
            "interest_paise": 0,
            "available_credit_paise": 22000,
            "accounting": f"balanced {interest_due}/{interest_due} paise",
        }

        correction_fuels: list[dict[str, Any]] = []
        correction_keys: list[str] = []
        for label, amount in (("MANAGER", 3000), ("OWNER", 4000)):
            key = str(uuid.uuid4())
            correction_keys.append(key)
            correction_fuels.append(
                one(
                    api.rpc(
                        attendant,
                        "post_fuel_credit_transaction",
                        {
                            "p_credit_account_id": manager_customer[
                                "credit_account_id"
                            ],
                            "p_station_id": PRIMARY_STATION_ID,
                            "p_fuel_product_id": PETROL_PRODUCT_ID,
                            "p_amount_paise": amount,
                            "p_idempotency_key": key,
                            "p_source_reference": (
                                f"P2E-{label}-COR-{run_marker}"
                            ),
                        },
                    ),
                    f"{label} correction source fuel",
                )
            )
        manager_original_before = one(
            api.select(
                manager,
                "ledger_transactions",
                select="id,transaction_type,status,amount_paise",
                filters={
                    "id": f"eq.{correction_fuels[0]['transaction_id']}"
                },
            ),
            "manager correction original before",
        )
        manager_correction = submit_correction(
            api,
            manager,
            correction_fuels[0]["transaction_id"],
            run_marker,
            "manager",
        )
        manager_original_after = one(
            api.select(
                manager,
                "ledger_transactions",
                select="id,transaction_type,status,amount_paise",
                filters={
                    "id": f"eq.{correction_fuels[0]['transaction_id']}"
                },
            ),
            "manager correction original after",
        )
        if (
            manager_correction["status"] != "PENDING_REVIEW"
            or manager_original_after != manager_original_before
        ):
            raise SmokeFailure("manager submission changed the original transaction")

        owner_correction = submit_correction(
            api,
            owner,
            correction_fuels[1]["transaction_id"],
            run_marker,
            "owner",
        )
        self_approval_before = count_snapshot(api, owner)
        self_approval_denial = expect_api_denied(
            lambda: api.rpc(
                owner,
                "approve_and_execute_financial_correction",
                {
                    "p_request_id": owner_correction["request_id"],
                    "p_expected_version": owner_correction["version"],
                },
            ),
            "owner self-approval",
            "COR_SELF_APPROVAL_FORBIDDEN",
        )
        assert_snapshot(
            self_approval_before,
            count_snapshot(api, owner),
            "owner self-approval denial",
        )
        approval = one(
            api.rpc(
                owner_b,
                "approve_and_execute_financial_correction",
                {
                    "p_request_id": owner_correction["request_id"],
                    "p_expected_version": owner_correction["version"],
                },
            ),
            "second-owner correction approval",
        )
        if (
            approval["status"] != "APPROVED_AND_EXECUTED"
            or approval["replacement_transaction_id"] is not None
            or approval["idempotent_replay"]
        ):
            raise SmokeFailure("second-owner correction approval was incorrect")
        original = one(
            api.select(
                owner,
                "ledger_transactions",
                select=(
                    "id,transaction_type,status,amount_paise,"
                    "business_date,credit_account_id,customer_id"
                ),
                filters={
                    "id": f"eq.{correction_fuels[1]['transaction_id']}"
                },
            ),
            "approved correction original",
        )
        reversal = one(
            api.select(
                owner,
                "ledger_transactions",
                select=(
                    "id,transaction_type,status,amount_paise,"
                    "business_date,credit_account_id,customer_id"
                ),
                filters={
                    "id": f"eq.{approval['reversal_transaction_id']}"
                },
            ),
            "approved correction reversal",
        )
        if (
            original["transaction_type"] != "FUEL_CREDIT"
            or original["status"] != "POSTED"
            or int(original["amount_paise"]) != 4000
            or reversal["transaction_type"] != "FINANCIAL_REVERSAL"
            or reversal["status"] != "POSTED"
            or int(reversal["amount_paise"]) != 4000
            or reversal["credit_account_id"] != original["credit_account_id"]
            or reversal["customer_id"] != original["customer_id"]
        ):
            raise SmokeFailure("correction changed or mis-scoped transaction evidence")
        original_entries = ledger_entries(api, owner, original["id"])
        reversal_entries = ledger_entries(api, owner, reversal["id"])
        expected_reversal = {
            (
                item["account_code"],
                "CREDIT" if item["direction"] == "DEBIT" else "DEBIT",
                int(item["amount_paise"]),
            )
            for item in original_entries
        }
        assert_posting(
            reversal_entries,
            expected_reversal,
            "exact correction reversal",
        )
        reversal_link = one(
            api.select(
                owner,
                "financial_reversals",
                select=(
                    "id,request_id,original_transaction_id,"
                    "reversal_transaction_id,replacement_transaction_id,"
                    "original_amount_paise,reversal_amount_paise"
                ),
                filters={"request_id": f"eq.{owner_correction['request_id']}"},
            ),
            "financial reversal link",
        )
        if (
            reversal_link["original_transaction_id"] != original["id"]
            or reversal_link["reversal_transaction_id"] != reversal["id"]
            or reversal_link["replacement_transaction_id"] is not None
            or int(reversal_link["original_amount_paise"]) != 4000
            or int(reversal_link["reversal_amount_paise"]) != 4000
        ):
            raise SmokeFailure("original/reversal link did not reconcile")
        correction_events = api.select(
            owner,
            "financial_correction_events",
            select="id,request_id,event_type,previous_status,new_status,correlation_id",
            filters={
                "request_id": query_ids(
                    [
                        str(manager_correction["request_id"]),
                        str(owner_correction["request_id"]),
                    ]
                )
            },
        )
        event_types = sorted(item["event_type"] for item in correction_events)
        if event_types != sorted(
            [
                "SUBMITTED",
                "SUBMITTED",
                "APPROVED_AND_EXECUTED",
                "REVERSAL_EXECUTED",
            ]
        ):
            raise SmokeFailure("correction event history was incomplete")
        correction_audits = api.select(
            owner,
            "audit_events",
            select="id,request_id,action,entity_id",
            filters={
                "request_id": query_ids(
                    [
                        str(manager_correction["correlation_id"]),
                        str(owner_correction["correlation_id"]),
                    ]
                )
            },
        )
        if sorted(item["action"] for item in correction_audits) != sorted(
            [
                "financial_correction.submitted",
                "financial_correction.submitted",
                "financial_correction.approved",
                "financial_correction.reversal_executed",
            ]
        ):
            raise SmokeFailure("correction audit evidence was incomplete")
        evidence["checks"]["correction"] = {
            "manager_submission": "PASS; pending; original unchanged",
            "owner_self_approval": self_approval_denial,
            "second_owner_approval": "PASS",
            "action": "REVERSAL_ONLY",
            "reversal_amount_paise": 4000,
            "exact_positive_swapped_entries": "PASS",
            "permanent_link": "PASS",
            "original_immutable": "PASS",
            "events": event_types,
        }

        verify_read_matrix(
            api,
            tokens,
            owner_customer["customer_id"],
            owner_account_id,
            isolation_customer["customer_id"],
            isolation_customer["credit_account_id"],
            fuel["transaction_id"],
        )
        anonymous_denial = expect_api_denied(
            lambda: api.rpc(
                None,
                "get_credit_account_obligations",
                {"p_credit_account_id": owner_account_id},
            ),
            "anonymous account-obligations RPC",
            None,
        )
        try:
            anonymous_orgs = api.select(None, "organizations")
            assert_empty(anonymous_orgs, "anonymous organization read")
            anonymous_select = {"rows": 0, "boundary": "RLS"}
        except ApiError as exc:
            anonymous_orgs = []
            anonymous_select = {
                "rows": 0,
                "boundary": "table privilege",
                "status": exc.status,
                "code": exc.code,
            }
        evidence["checks"]["read_isolation"] = {
            "cross_tenant": "PASS with positive same-tenant counterparts",
            "manager_station_scope": "PASS",
            "attendant_customer_and_financial_denied": "PASS",
            "customer_self_only": "PASS",
            "driver_self_and_parent_only": "PASS",
            "anonymous_select": anonymous_select,
            "anonymous_rpc": anonymous_denial,
        }

        interest_accrual_id = str(accruals[0]["id"])
        correction_event_id = str(correction_events[0]["id"])
        raw_denials = direct_mutation_denials(
            api,
            tokens,
            fuel,
            str(fuel_audit["id"]),
            correction_event_id,
            interest_accrual_id,
        )
        evidence["checks"]["direct_mutation_denials"] = raw_denials
        evidence["checks"]["immutability"] = {
            "update": "DENIED",
            "delete": "DENIED",
            "reclassify": "DENIED",
            "truncate": "unavailable to API roles; catalog verifier pins zero privilege",
            "append_only_history": "PASS",
        }

        ledger_transaction_ids = [
            str(fuel["transaction_id"]),
            str(principal_payment["transaction_id"]),
            *[
                str(item["ledger_transaction_id"])
                for item in accruals
                if int(item["posted_interest_paise"]) > 0
            ],
            str(interest_payment["transaction_id"]),
            *[str(item["transaction_id"]) for item in correction_fuels],
            str(approval["reversal_transaction_id"]),
        ]
        if len(ledger_transaction_ids) != len(set(ledger_transaction_ids)):
            raise SmokeFailure("smoke ledger transaction identities are not unique")
        all_entries = api.select(
            owner,
            "ledger_entries",
            select="id,transaction_id,direction,amount_paise",
            filters={"transaction_id": query_ids(ledger_transaction_ids)},
        )
        for transaction_id in ledger_transaction_ids:
            rows = [
                row
                for row in all_entries
                if row["transaction_id"] == transaction_id
            ]
            debits = sum(
                int(row["amount_paise"])
                for row in rows
                if row["direction"] == "DEBIT"
            )
            credits = sum(
                int(row["amount_paise"])
                for row in rows
                if row["direction"] == "CREDIT"
            )
            if len(rows) != 2 or debits != credits or debits <= 0:
                raise SmokeFailure("a smoke ledger transaction is not balanced")

        customer_ids = [
            str(owner_customer["customer_id"]),
            str(manager_customer["customer_id"]),
        ]
        primary_customers = api.select(
            owner,
            "customers",
            filters={"id": query_ids(customer_ids)},
        )
        isolation_customers = api.select(
            isolation,
            "customers",
            filters={"id": f"eq.{isolation_customer['customer_id']}"},
        )
        account_ids = [
            str(owner_customer["credit_account_id"]),
            str(manager_customer["credit_account_id"]),
        ]
        primary_accounts = api.select(
            owner,
            "credit_accounts",
            filters={"id": query_ids(account_ids)},
        )
        isolation_accounts = api.select(
            isolation,
            "credit_accounts",
            filters={"id": f"eq.{isolation_customer['credit_account_id']}"},
        )
        fuel_transaction_ids = [
            str(fuel["transaction_id"]),
            *[str(item["transaction_id"]) for item in correction_fuels],
        ]
        repayment_ids = [
            str(principal_payment["repayment_id"]),
            str(interest_payment["repayment_id"]),
        ]
        repayment_rows = api.select(
            owner,
            "customer_repayments",
            filters={"id": query_ids(repayment_ids)},
        )
        allocation_rows = api.select(
            owner,
            "repayment_allocations",
            filters={"repayment_id": query_ids(repayment_ids)},
        )
        idempotency_keys = [
            fuel_key,
            principal_key,
            interest_key,
            *correction_keys,
        ]
        idempotency_rows = api.select(
            owner,
            "idempotency_keys",
            filters={"idempotency_key": query_ids(idempotency_keys)},
        )
        correction_request_ids = [
            str(manager_correction["request_id"]),
            str(owner_correction["request_id"]),
        ]
        correction_requests = api.select(
            owner,
            "financial_correction_requests",
            filters={"id": query_ids(correction_request_ids)},
        )
        audit_request_ids = [
            creation_request_ids["owner"],
            creation_request_ids["manager"],
            fuel_key,
            principal_key,
            interest_key,
            *correction_keys,
            str(manager_correction["correlation_id"]),
            str(owner_correction["correlation_id"]),
        ]
        primary_audits = api.select(
            owner,
            "audit_events",
            filters={"request_id": query_ids(audit_request_ids)},
        )
        isolation_audits = api.select(
            isolation,
            "audit_events",
            filters={
                "request_id": f"eq.{creation_request_ids['isolation']}"
            },
        )
        interest_audits = api.select(
            owner,
            "audit_events",
            filters={
                "request_id": f"eq.{interest_run['request_id']}",
                "entity_id": query_ids([str(row["id"]) for row in accruals]),
            },
        )
        counts = {
            "customers_created": len(primary_customers) + len(isolation_customers),
            "credit_accounts": len(primary_accounts) + len(isolation_accounts),
            "fuel_sales": len(
                api.select(
                    owner,
                    "fuel_credit_sales",
                    filters={"transaction_id": query_ids(fuel_transaction_ids)},
                )
            ),
            "repayments": len(repayment_rows),
            "repayment_allocations": len(allocation_rows),
            "interest_accruals": len(accruals),
            "interest_components": len(components),
            "ledger_transactions": len(
                api.select(
                    owner,
                    "ledger_transactions",
                    filters={"id": query_ids(ledger_transaction_ids)},
                )
            ),
            "ledger_entries": len(all_entries),
            "idempotency_records": len(idempotency_rows),
            "correction_requests": len(correction_requests),
            "correction_events": len(correction_events),
            "financial_reversals": len(
                api.select(
                    owner,
                    "financial_reversals",
                    filters={
                        "request_id": f"eq.{owner_correction['request_id']}"
                    },
                )
            ),
            "audit_events": (
                len(primary_audits)
                + len(isolation_audits)
                + len(interest_audits)
            ),
        }
        expected_counts = {
            "customers_created": 3,
            "credit_accounts": 3,
            "fuel_sales": 3,
            "repayments": 2,
            "repayment_allocations": 2,
            "interest_accruals": len(accruals),
            "interest_components": len(components),
            "ledger_transactions": len(ledger_transaction_ids),
            "ledger_entries": len(ledger_transaction_ids) * 2,
            "idempotency_records": 5,
            "correction_requests": 2,
            "correction_events": 4,
            "financial_reversals": 1,
            "audit_events": 14,
        }
        if counts != expected_counts:
            raise SmokeFailure(
                f"dedicated smoke counts did not reconcile: {counts}"
            )
        evidence["final_counts"] = counts
        evidence["ledger_reconciliation"] = {
            "transactions_checked": len(ledger_transaction_ids),
            "all_balanced": True,
            "total_entries": len(all_entries),
        }
        evidence["failed_operation_partial_rows"] = 0
        evidence["result"] = "PASS"
        EVIDENCE_FILE.parent.mkdir(parents=True, exist_ok=True)
        EVIDENCE_FILE.write_text(
            json.dumps(evidence, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(
            "PASS: hosted Phase 2E functional/authorization smoke completed; "
            f"run={run_marker}; ledger_transactions="
            f"{len(ledger_transaction_ids)}; all_balanced=true; "
            f"sanitized_evidence={EVIDENCE_FILE.relative_to(ROOT)}"
        )
        return 0
    except (
        ApiError,
        KeyError,
        OSError,
        SmokeFailure,
        subprocess.TimeoutExpired,
        TargetSafetyFailure,
        ValueError,
    ) as exc:
        print(f"FAIL: hosted Phase 2E functional smoke: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
