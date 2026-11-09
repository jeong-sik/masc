# pyright: strict
"""Tests for the files scripts/tinker/librarian/pass_lines.json pins.

A verdict runs eval_admission.py and e_synth_audit.py. The pin names every
module of the librarian directory they import, at any depth, and the prompt
template the requests are rendered with. It names nothing else.
"""

from __future__ import annotations

import ast
import json
import unittest
from pathlib import Path
from typing import cast

HERE = Path(__file__).resolve().parents[1] / "tinker" / "librarian"
VERDICT_SCRIPTS = ("eval_admission", "e_synth_audit")
TEMPLATE = "../../../config/prompts/librarian.md"


def imported(module: str, local: frozenset[str]) -> frozenset[str]:
    """The modules of the librarian directory that `module` imports."""
    names: set[str] = set()
    for node in ast.walk(ast.parse((HERE / f"{module}.py").read_text(encoding="utf-8"))):
        if isinstance(node, ast.Import):
            names |= {alias.name.split(".")[0] for alias in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module is not None and node.level == 0:
            names.add(node.module.split(".")[0])
    return frozenset(names) & local


def verdict_modules() -> frozenset[str]:
    local = frozenset(path.stem for path in HERE.glob("*.py"))
    seen: set[str] = set()
    todo: list[str] = list(VERDICT_SCRIPTS)
    while todo:
        module = todo.pop()
        if module not in seen:
            seen.add(module)
            todo.extend(imported(module, local) - seen)
    return frozenset(seen)


class PinnedFilesTest(unittest.TestCase):
    def test_the_pin_names_every_module_a_verdict_imports_and_the_template(self) -> None:
        lines = cast(dict[str, object], json.loads((HERE / "pass_lines.json").read_text(encoding="utf-8")))
        pinned = cast(dict[str, str], lines["files_sha256"])
        self.assertEqual(set(pinned), {f"{module}.py" for module in verdict_modules()} | {TEMPLATE})


if __name__ == "__main__":
    unittest.main()
