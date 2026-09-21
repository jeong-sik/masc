#!/usr/bin/env python3
"""Reject new references to top-level names deleted on the PR base.

Indented declarations inside modules are intentionally outside this lexical
guard; compilation remains authoritative for those names.
"""

from __future__ import annotations

import re
import subprocess
import sys

NAME = r"[A-Za-z_][A-Za-z0-9_']*"
DECLARATION = re.compile(rf"^\+(?:let(?:\s+rec)?|and|val)\s+({NAME})\b")
REFERENCE = re.compile(rf"\b({NAME})\b")
ALLOW = re.compile(r"symbol-guard: allow (" + NAME + r")")


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


def added_references(head: str, branch_point: str) -> tuple[dict[str, str], set[str]]:
    diff = git("diff", "--unified=0", f"{branch_point}..{head}", "--", "*.ml", "*.mli")
    added: dict[str, str] = {}
    allowed: set[str] = set()
    current_file = "<unknown>"
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
        if not line.startswith("+") or line.startswith("+++"):
            continue
        allowed.update(match.group(1) for match in ALLOW.finditer(line))
        for match in REFERENCE.finditer(line[1:]):
            added.setdefault(match.group(1), current_file)
    return added, allowed


def deletion_commit(name: str, file_name: str, base: str, branch_point: str) -> str:
    commits = git(
        "log",
        "--format=%H",
        "-S",
        f"let {name}",
        f"{branch_point}..{base}",
        "--",
        file_name,
    ).splitlines()
    return commits[-1] if commits else base


def run(base: str, head: str = "HEAD") -> int:
    branch_point = git("merge-base", base, head).strip()
    deleted = deleted_names(base, branch_point)
    added, allowed = added_references(head, branch_point)
    collisions = sorted((set(deleted) & set(added)) - allowed)
    print(f"base: {base}")
    print(f"head: {head}")
    print(f"branch point: {branch_point}")
    print(f"deleted top-level names: {len(deleted)}")
    print(f"added identifiers compared: {len(added)}")
    if collisions:
        print("deleted names referenced by added lines:")
        for name in collisions:
            commit = deletion_commit(name, deleted[name], base, branch_point)
            print(
                f"- {name}: deleted by {commit} in {deleted[name]}, "
                f"referenced in {added[name]}"
            )
        print(
            "To suppress an intentional match, add "
            "symbol-guard: allow NAME to the added line and explain why."
        )
        return 1
    print("no deleted-name references found")
    return 0


def self_test() -> int:
    declarations = {
        match.group(1)
        for line in (
            "+let rec recursive_name = recursive_name",
            "+and peer_name = recursive_name",
            "+val signature_name : unit",
            "+  let local_name = recursive_name",
        )
        if (match := DECLARATION.match(line)) is not None
    }
    expected = {"recursive_name", "peer_name", "signature_name"}
    if declarations != expected:
        raise AssertionError(
            f"top-level declaration fixture mismatch: {sorted(declarations)}"
        )
    deleted = {"old_name"}
    added = set(REFERENCE.findall("let new_name = old_name"))
    if deleted & added != {"old_name"}:
        raise AssertionError("fixture did not detect the deleted symbol")
    print("self-test: deleted symbol reference detected")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        raise SystemExit(self_test())
    if len(sys.argv) not in (2, 3):
        raise SystemExit(
            "usage: check-deleted-symbol-references.py BASE_SHA [HEAD_SHA]"
        )
    raise SystemExit(run(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else "HEAD"))
