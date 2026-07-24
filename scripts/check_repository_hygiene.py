#!/usr/bin/env python3
"""Fail when tracked repository content contains runtime artifacts or secrets."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DISALLOWED_SUFFIXES = {
    ".bak",
    ".backup",
    ".db",
    ".key",
    ".pem",
    ".sqlite",
    ".sqlite3",
}
DISALLOWED_PARTS = {
    ".temp",
    "node_modules",
    "target",
}
SECRET_PATTERNS = {
    "JWT-like token": re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\."),
    "Supabase secret key": re.compile(r"\bsb_secret_[A-Za-z0-9_-]{16,}\b"),
    "private key block": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}


def git(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *arguments],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )


def tracked_files() -> list[Path]:
    result = git("ls-files", "-z")
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git ls-files failed")
    return [ROOT / name for name in result.stdout.split("\0") if name]


def main() -> int:
    failures: list[str] = []
    files = tracked_files()

    for path in files:
        relative = path.relative_to(ROOT)
        lower_parts = {part.lower() for part in relative.parts}
        lower_name = relative.name.lower()

        if lower_name == ".env" or (
            lower_name.startswith(".env.") and lower_name != ".env.example"
        ):
            failures.append(f"tracked environment file: {relative}")
        if path.suffix.lower() in DISALLOWED_SUFFIXES:
            failures.append(f"tracked runtime/secret suffix: {relative}")
        if lower_parts & DISALLOWED_PARTS:
            failures.append(f"tracked generated directory content: {relative}")

        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(content):
                failures.append(f"{label} in {relative}")

        if path.suffix.lower() == ".sql":
            if re.search(
                r"\bdisable\s+row\s+level\s+security\b",
                content,
                re.IGNORECASE,
            ):
                failures.append(f"RLS disabling statement in {relative}")
            if re.search(
                r"\b(?:using|with\s+check)\s*\(\s*true\s*\)",
                content,
                re.IGNORECASE,
            ):
                failures.append(f"unconditional permissive RLS expression in {relative}")

    whitespace = git("diff", "--check")
    if whitespace.returncode != 0:
        failures.append(whitespace.stdout.strip() or whitespace.stderr.strip())

    if failures:
        print("Repository hygiene check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(
        f"PASS: checked {len(files)} tracked files; no runtime artifacts, "
        "key material, token-shaped secrets, disabled RLS, or broad true policies found."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
