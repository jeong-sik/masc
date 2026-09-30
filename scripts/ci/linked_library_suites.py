#!/usr/bin/env python3
"""Resolve a selected test library module to the test executables that link it.

Input: repository-relative selected paths, one per line.
Output: <module path><tab><test source path>, one link per line.
"""
from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path, PurePosixPath

from stanza_env import StanzaError, included_stanza_sources, stanza_names

REPO_ROOT = Path(__file__).resolve().parents[2]


def field_atoms(form: list, name: str) -> list[str]:
    for field in form[1:]:
        if isinstance(field, list) and field and field[0] == name:
            return [atom for atom in field[1:] if isinstance(atom, str)]
    return []


def linked_suites(root: Path, paths: list[str]) -> list[tuple[str, str]]:
    by_dir: dict[PurePosixPath, list[tuple[str, str]]] = defaultdict(list)
    for source in paths:
        path = PurePosixPath(source)
        parts = path.parts
        in_test = parts[:1] == ("test",) or (
            len(parts) >= 3 and parts[0] == "packages" and parts[2] == "test"
        )
        if not in_test or ".." in parts or path.suffix != ".ml":
            continue
        by_dir[path.parent].append((source, path.stem))

    found: set[tuple[str, str]] = set()
    for directory, selected in by_dir.items():
        dune = root.joinpath(*directory.parts, "dune")
        if not dune.is_file():
            continue
        forms = [
            form
            for _text, stanzas in included_stanza_sources(str(dune))
            for form in stanzas
            if isinstance(form, list) and form
        ]
        tests = [form for form in forms if form[0] in ("test", "tests")]
        declared = {name for form in tests for name in stanza_names(form)}
        libraries = [form for form in forms if form[0] == "library"]
        for source, module in selected:
            if module in declared:
                continue
            linked = {
                library
                for form in libraries
                if module in field_atoms(form, "modules")
                for library in field_atoms(form, "name")
            }
            if not linked:
                continue
            for form in tests:
                if not linked.intersection(field_atoms(form, "libraries")):
                    continue
                for name in stanza_names(form):
                    target = directory / f"{name}.ml"
                    if root.joinpath(*target.parts).is_file():
                        found.add((source, str(target)))
    return sorted(found)


def main() -> int:
    try:
        for source, target in linked_suites(REPO_ROOT, sys.stdin.read().splitlines()):
            print(f"{source}\t{target}")
    except (OSError, StanzaError) as exc:
        print(f"linked test suite lookup failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
