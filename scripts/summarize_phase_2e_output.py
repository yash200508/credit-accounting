#!/usr/bin/env python3
"""Emit sanitized migration/advisor summaries from transient CLI output."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


MIGRATION = re.compile(r"\b(\d{14}(?:_[a-z0-9_]+)?(?:\.sql)?)\b", re.IGNORECASE)
ADVISOR_CODE = re.compile(r"\b(?:00|01|02)\d{2}\b")


def walk(value: Any) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    if isinstance(value, dict):
        if any(key in value for key in ("code", "level", "title", "name")):
            found.append(value)
        for nested in value.values():
            found.extend(walk(nested))
    elif isinstance(value, list):
        for nested in value:
            found.extend(walk(nested))
    return found


def migrations(text: str) -> int:
    values = sorted(set(MIGRATION.findall(text)))
    if values:
        print("Pending/applied migration identifiers:")
        for value in values:
            print(f"- {value}")
    else:
        print("No migration identifiers were reported.")
    return 0


def advisors(text: str) -> int:
    findings: list[tuple[str, str, str]] = []
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = None
    if payload is not None:
        for item in walk(payload):
            code = str(item.get("code", "unclassified"))
            level = str(item.get("level", item.get("severity", "unknown")))
            title = str(item.get("title", item.get("name", "advisor finding")))
            findings.append((code, level, title.replace("\n", " ")[:160]))
    else:
        for line in text.splitlines():
            match = ADVISOR_CODE.search(line)
            if match:
                findings.append((match.group(0), "reported", line.strip()[:160]))

    unique = sorted(set(findings))
    if unique:
        print(f"Advisor findings ({len(unique)}):")
        for code, level, title in unique:
            print(f"- code={code}; level={level}; title={title}")
    elif "No issues found" in text:
        print("Advisor findings: none reported.")
    else:
        print("Advisor output contained no recognized finding codes.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("migrations", "advisors"))
    parser.add_argument("path")
    args = parser.parse_args()
    try:
        text = Path(args.path).read_text(encoding="utf-8", errors="replace")
        return migrations(text) if args.kind == "migrations" else advisors(text)
    except OSError as exc:
        print(f"FAIL: unable to summarize CLI output: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
