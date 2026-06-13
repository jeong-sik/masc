import importlib.machinery
import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1] / "scripts" / "ide" / "export-symbol-graph"
)


def load_exporter_module():
    loader = importlib.machinery.SourceFileLoader(
        "export_symbol_graph", str(SCRIPT_PATH)
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    loader.exec_module(module)
    return module


exporter = load_exporter_module()


class ChangedSymbolsReportTest(unittest.TestCase):
    def test_report_marks_known_and_unknown_changed_paths(self):
        data = {
            "schema_version": "masc.symbol_graph.v1",
            "repo": "masc",
            "base_commit": "abc123",
            "lanes": [
                {
                    "name": "Keeper turn pipeline",
                    "issue": 16079,
                    "goal": "goal-refactor-keeper-turn-20260518",
                    "tasks": ["task-368"],
                    "primary_files": ["lib/a.ml"],
                    "guard_tests": ["test/test_a.ml"],
                }
            ],
            "files": [
                {
                    "path": "lib/a.ml",
                    "language": "ocaml",
                    "symbols": [
                        {
                            "id": "lib/a.ml::run",
                            "name": "run",
                            "kind": "function",
                            "display_range": {"start_line": 10, "end_line": 20},
                            "wbs": ["task-368"],
                            "tests": ["test/test_a.ml"],
                        }
                    ],
                    "test_owners": [
                        {
                            "test_path": "test/test_a.ml",
                            "reason": "direct owner",
                        }
                    ],
                }
            ],
        }

        report = exporter.changed_symbols_report(
            data,
            ["lib/a.ml", "README.md", "lib/a.ml"],
            base_ref="origin/main",
            head_ref="HEAD",
        )

        self.assertEqual(
            report["schema_version"],
            "masc.symbol_graph.changed_symbols.v1",
        )
        self.assertEqual(report["artifact_schema_version"], "masc.symbol_graph.v1")
        self.assertEqual(report["artifact_base_commit"], "abc123")
        self.assertEqual(report["changed_path_count"], 2)
        self.assertEqual(report["matched_file_count"], 1)

        known = report["changed_files"][0]
        self.assertEqual(known["path"], "lib/a.ml")
        self.assertTrue(known["in_symbol_graph"])
        self.assertEqual(known["language"], "ocaml")
        self.assertEqual(known["lanes"][0]["name"], "Keeper turn pipeline")
        self.assertEqual(known["symbols"][0]["id"], "lib/a.ml::run")
        self.assertEqual(known["test_owners"][0]["test_path"], "test/test_a.ml")

        unknown = report["changed_files"][1]
        self.assertEqual(unknown["path"], "README.md")
        self.assertFalse(unknown["in_symbol_graph"])
        self.assertEqual(unknown["symbols"], [])
        self.assertEqual(
            report["omissions"][0]["code"], "changed_file_not_in_symbol_graph"
        )
        self.assertEqual(report["omissions"][0]["paths"], ["README.md"])


if __name__ == "__main__":
    unittest.main()
