"""Compare a keyboard split with its original source, without opening a PTY.

python3 scripts/verify-tui-keyboard-split.py --before-ref <commit> --output <json>
"""

from __future__ import annotations

import argparse
import ast
from collections import Counter
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def definitions(source: bytes) -> dict[str, str]:
    lines = source.splitlines(keepends=True)
    result: dict[str, str] = {}
    for node in ast.parse(source).body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            assert node.end_lineno is not None
            start = (
                min([node.lineno, *[item.lineno for item in node.decorator_list]]) - 1
            )
            body = b"".join(lines[start : node.end_lineno])
            result[node.name] = hashlib.sha256(body).hexdigest()
    return result


def module_statements(source: bytes) -> Counter[str]:
    """Inventory all executable top-level state, including entrypoint guards.

    Imports express the new ownership wiring and are checked by consumer tests.
    Function/class definitions are inventoried separately above; their bodies
    already include decorators, defaults and class-level executable statements.
    """
    return Counter(
        ast.dump(node, include_attributes=False)
        for node in ast.parse(source).body
        if not isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef,
                                 ast.AsyncFunctionDef, ast.ClassDef))
    )


def listing(script: Path, root: Path) -> str:
    environment = dict(os.environ)
    environment.pop("MASC_CONFIG_DIR", None)
    environment.pop("MASC_BASE_PATH", None)
    # --list never launches this executable; two families only hash its bytes.
    return subprocess.check_output(
        [sys.executable, str(script), sys.executable, "--list"],
        cwd=root,
        env=environment,
        text=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-ref", required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    before = subprocess.check_output(
        ["git", "show", arguments.before_ref + ":test/test_tui_keyboard_input.py"],
        cwd=root,
    )
    expected = definitions(before)
    expected_statements = module_statements(before)
    actual_statements: Counter[str] = Counter()
    after_source_sha256: dict[str, str] = {}
    actual: dict[str, str] = {}
    owners: dict[str, str] = {}
    entry = root / "test/test_tui_keyboard_input.py"
    for path in [entry, *sorted((root / "test").glob("tui_keyboard_*.py"))]:
        source = path.read_bytes()
        after_source_sha256[str(path.relative_to(root))] = hashlib.sha256(source).hexdigest()
        actual_statements.update(module_statements(source))
        for name, digest in definitions(source).items():
            if name in actual:
                raise AssertionError(f"duplicate definition: {name}")
            actual[name] = digest
            owners[name] = str(path.relative_to(root))
    missing = sorted(expected.keys() - actual.keys())
    extra = sorted(actual.keys() - expected.keys())
    changed = sorted(
        name
        for name in expected.keys() & actual.keys()
        if expected[name] != actual[name]
    )
    statements_removed = sorted((expected_statements - actual_statements).elements())
    statements_added = sorted((actual_statements - expected_statements).elements())
    with tempfile.TemporaryDirectory(prefix="masc-keyboard-before-") as directory:
        script = Path(directory) / "test_tui_keyboard_input.py"
        script.write_bytes(before)
        old_listing = listing(script, root)
    new_listing = listing(entry, root)
    report = {
        "before_ref": arguments.before_ref,
        "after_source_sha256": after_source_sha256,
        "module_statements_removed": statements_removed,
        "module_statements_added": statements_added,
        "module_statements_identical": not statements_removed and not statements_added,
        "source_sha256": hashlib.sha256(before).hexdigest(),
        "definitions_before": sorted(expected),
        "definitions_after": sorted(actual),
        "missing": missing,
        "extra": extra,
        "body_bytes_changed": changed,
        "listing_before": old_listing.splitlines(),
        "listing_after": new_listing.splitlines(),
        "listing_identical": old_listing == new_listing,
        "owners": owners,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    if (missing or extra or changed or statements_removed or statements_added
            or old_listing != new_listing):
        raise AssertionError("split differs; see " + str(arguments.output))
    print(
        json.dumps(
            {
                "definitions": len(expected),
                "missing": missing,
                "extra": extra,
                "body_bytes_changed": changed,
                "listing_identical": True,
                "module_statements_identical": True,
                "families": sum(
                    not line.startswith("  ") for line in old_listing.splitlines()
                ),
                "description_occurrences": sum(
                    line.startswith("  ") for line in old_listing.splitlines()
                ),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
