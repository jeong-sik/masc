#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import importlib.machinery
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "ide" / "changed-symbols"


def load_changed_symbols_module():
    loader = importlib.machinery.SourceFileLoader("changed_symbols", str(SCRIPT_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


changed_symbols = load_changed_symbols_module()


class ChangedSymbolsTest(unittest.TestCase):
    def test_parse_unified_diff_records_added_ranges(self) -> None:
        diff = """diff --git a/lib/foo.ml b/lib/foo.ml
--- a/lib/foo.ml
+++ b/lib/foo.ml
@@ -9,0 +10,2 @@
+let alpha = 1
+let beta = 2
@@ -40 +42 @@
-old
+new
"""

        files = changed_symbols.parse_unified_diff(diff)

        self.assertEqual(sorted(files), ["lib/foo.ml"])
        row = files["lib/foo.ml"]
        self.assertEqual(row.status, "modified")
        self.assertEqual(
            [changed_symbols.range_to_json(item) for item in row.ranges],
            [
                {"start_line": 10, "end_line": 11},
                {"start_line": 42, "end_line": 42},
            ],
        )

    def test_collect_impacted_symbols_uses_range_overlap(self) -> None:
        graph = {
            "files": [
                {
                    "path": "lib/foo.ml",
                    "test_owners": [{"test_path": "test/test_foo.ml"}],
                    "symbols": [
                        {
                            "id": "Foo.alpha",
                            "name": "alpha",
                            "kind": "function",
                            "display_range": {"start_line": 8, "end_line": 12},
                            "tests": ["test/test_alpha.ml"],
                        },
                        {
                            "id": "Foo.gamma",
                            "name": "gamma",
                            "kind": "function",
                            "display_range": {"start_line": 20, "end_line": 30},
                            "tests": ["test/test_gamma.ml"],
                        },
                    ],
                }
            ]
        }
        changed = {
            "lib/foo.ml": changed_symbols.ChangedFile(
                path="lib/foo.ml",
                status="modified",
                ranges=[changed_symbols.ChangedRange(10, 11)],
                source="git_diff",
            )
        }

        impacted, omissions, tests = changed_symbols.collect_impacted_symbols(
            graph, changed
        )

        self.assertEqual([row["id"] for row in impacted], ["Foo.alpha"])
        self.assertEqual(impacted[0]["match_reason"], "range_overlap")
        self.assertEqual(tests, ["test/test_alpha.ml", "test/test_foo.ml"])
        self.assertEqual(omissions, [])

    def test_collect_impacted_symbols_records_untracked_omission(self) -> None:
        graph = {"files": []}
        changed = {
            "scripts/new-tool": changed_symbols.ChangedFile(
                path="scripts/new-tool",
                status="added",
                ranges=[changed_symbols.ChangedRange(1, 3)],
                source="untracked",
            )
        }

        impacted, omissions, tests = changed_symbols.collect_impacted_symbols(
            graph, changed
        )

        self.assertEqual(impacted, [])
        self.assertEqual(tests, [])
        self.assertEqual(omissions[0]["code"], "changed_file_not_in_symbol_graph")
        self.assertEqual(omissions[0]["path"], "scripts/new-tool")

    def test_collect_impacted_lanes_matches_files_and_guard_tests(self) -> None:
        graph = {
            "lanes": [
                {
                    "name": "Keeper turn pipeline",
                    "issue": 16079,
                    "goal": "goal-refactor-keeper-turn-20260518",
                    "tasks": ["task-368"],
                    "primary_files": ["lib/foo.ml"],
                    "guard_tests": ["test/test_alpha.ml"],
                },
                {
                    "name": "Unrelated",
                    "primary_files": ["lib/other.ml"],
                    "guard_tests": ["test/test_other.ml"],
                },
            ]
        }
        changed = {
            "lib/foo.ml": changed_symbols.ChangedFile(
                path="lib/foo.ml",
                status="modified",
                ranges=[],
                source="git_diff",
            )
        }

        lanes = changed_symbols.collect_impacted_lanes(
            graph,
            changed,
            ["test/test_alpha.ml"],
        )

        self.assertEqual([lane["name"] for lane in lanes], ["Keeper turn pipeline"])
        self.assertEqual(lanes[0]["matched_files"], ["lib/foo.ml"])
        self.assertEqual(lanes[0]["matched_guard_tests"], ["test/test_alpha.ml"])


if __name__ == "__main__":
    unittest.main()
