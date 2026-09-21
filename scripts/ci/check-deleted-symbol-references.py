#!/usr/bin/env python3
"""Reject new references to top-level names deleted on the PR base."""

from __future__ import annotations

import re
import subprocess
import sys

NAME = r"[A-Za-z_][A-Za-z0-9_']*"
DECLARATION = re.compile(rf"^\s*\+\s*(?:let|and|val)\s+({NAME})\b")
REFERENCE = re.compile(rf"\b({NAME})\b")


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True)


def deleted_names(base: str, branch_point: str) -> dict[str, str]:
    diff = git("diff", "--unified=0", f"{branch_point}..{base}", "--", "*.ml", "*.mli")
    deleted: dict[str, str] = {}
    current_file = "<unknown>"
    for line in diff.splitlines():
        if line.startswith("--- a/"):
            current_file = line[6:]
        if not line.startswith("-") or line.startswith("---"):
            continue
        match = DECLARATION.match("+" + line[1:])
        if match:
            deleted[match.group(1)] = current_file
    return deleted


def added_references(head: str, branch_point: str) -> dict[str, str]:
    diff = git("diff", "--unified=0", f"{branch_point}..{head}", "--", "*.ml", "*.mli")
    added: dict[str, str] = {}
    current_file = "<unknown>"
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
        if not line.startswith("+") or line.startswith("+++"):
            continue
        for match in REFERENCE.finditer(line[1:]):
            added.setdefault(match.group(1), current_file)
    return added


def run(base: str) -> int:
    branch_point = git("merge-base", base, "HEAD").strip()
    deleted = deleted_names(base, branch_point)
    added = added_references("HEAD", branch_point)
    collisions = sorted(set(deleted) & set(added))
    print(f"deleted top-level names: {len(deleted)}")
    print(f"added identifiers compared: {len(added)}")
    if collisions:
        print("deleted names referenced by added lines:")
        for name in collisions:
            print(f"- {name}: deleted in {deleted[name]}, referenced in {added[name]}")
        return 1
    print("no deleted-name references found")
    return 0


def self_test() -> int:
    deleted = {"old_name"}
    added = set(REFERENCE.findall("let new_name = old_name"))
    if deleted & added != {"old_name"}:
        raise AssertionError("fixture did not detect the deleted symbol")
    print("self-test: deleted symbol reference detected")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        raise SystemExit(self_test())
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-deleted-symbol-references.py BASE_SHA")
    raise SystemExit(run(sys.argv[1]))
