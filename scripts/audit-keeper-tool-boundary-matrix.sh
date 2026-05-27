#!/usr/bin/env bash
# Keeper agent tool boundary matrix audit.
#
# The matrix is intentionally file-granular. If a scoped keeper module appears
# without an owner, the tool boundary can drift silently across execution,
# sandbox, shell, repo-hosting observation, hook, and OAS bridge surfaces.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MATRIX_FILE="${REPO_ROOT}/docs/design/keeper-tool-boundary-matrix.md"

for tool in python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[keeper-tool-boundary-matrix] required tool missing: $tool" >&2
    exit 1
  }
done

python3 - "$REPO_ROOT" "$MATRIX_FILE" <<'PYEOF'
from __future__ import annotations

import collections
import pathlib
import re
import sys


repo_root = pathlib.Path(sys.argv[1])
matrix_file = pathlib.Path(sys.argv[2])

scope_re = re.compile(
    r"^lib/keeper/(?:agent_tool_[^/]*_runtime|agent_tool_execute_[^/]*|keeper_(?:gh|hooks|sandbox|exec|shell|tool|tools)[^/]*)\.mli?$"
)
manifest_re = re.compile(
    r"^\s*-\s+`(?P<path>lib/keeper/[^`]+)`\s+-\s+(?P<owner>[a-z][a-z0-9-]*)\s*$"
)
owners = {
    "execution-dispatch",
    "hook-observation",
    "oas-tool-bridge",
    "sandbox-runtime",
    "shell-surface",
    "tool-surface-policy",
}

if not matrix_file.is_file():
    print(
        f"[keeper-tool-boundary-matrix] missing matrix: {matrix_file.relative_to(repo_root)}",
        file=sys.stderr,
    )
    sys.exit(1)

source_paths: set[str] = set()
keeper_dir = repo_root / "lib" / "keeper"
for path in keeper_dir.iterdir():
    if not path.is_file():
        continue
    rel = path.relative_to(repo_root).as_posix()
    if scope_re.match(rel):
        source_paths.add(rel)

records: dict[str, list[tuple[int, str]]] = collections.defaultdict(list)
with matrix_file.open(encoding="utf-8") as handle:
    for line_no, line in enumerate(handle, start=1):
        match = manifest_re.match(line)
        if match is None:
            continue
        records[match.group("path")].append((line_no, match.group("owner")))

listed_paths = set(records)
missing = sorted(source_paths - listed_paths)
stale = sorted(path for path in listed_paths if path not in source_paths)
duplicate = sorted(path for path, entries in records.items() if len(entries) != 1)
invalid_owner = sorted(
    (path, line_no, owner)
    for path, entries in records.items()
    for line_no, owner in entries
    if owner not in owners
)
invalid_scope = sorted(path for path in listed_paths if not scope_re.match(path))

errors = []
if missing:
    errors.append("missing source paths")
if stale:
    errors.append("stale matrix paths")
if duplicate:
    errors.append("duplicate matrix entries")
if invalid_owner:
    errors.append("invalid owner categories")
if invalid_scope:
    errors.append("out-of-scope manifest paths")

if errors:
    print(
        "[keeper-tool-boundary-matrix] FAIL - " + ", ".join(errors),
        file=sys.stderr,
    )
    if missing:
        print("\nMissing source paths:", file=sys.stderr)
        for path in missing:
            print(f"  - {path}", file=sys.stderr)
    if stale:
        print("\nStale matrix paths:", file=sys.stderr)
        for path in stale:
            print(f"  - {path}", file=sys.stderr)
    if duplicate:
        print("\nDuplicate matrix entries:", file=sys.stderr)
        for path in duplicate:
            lines = ", ".join(str(line_no) for line_no, _owner in records[path])
            print(f"  - {path} (lines {lines})", file=sys.stderr)
    if invalid_owner:
        print("\nInvalid owner categories:", file=sys.stderr)
        for path, line_no, owner in invalid_owner:
            print(f"  - line {line_no}: {path} -> {owner}", file=sys.stderr)
    if invalid_scope:
        print("\nOut-of-scope manifest paths:", file=sys.stderr)
        for path in invalid_scope:
            print(f"  - {path}", file=sys.stderr)
    sys.exit(2)

print(
    "[keeper-tool-boundary-matrix] OK - "
    f"{len(source_paths)} scoped keeper files covered by "
    f"{matrix_file.relative_to(repo_root)}"
)
PYEOF
