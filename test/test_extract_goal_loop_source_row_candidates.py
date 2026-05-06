#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "extract_goal_loop_source_row_candidates.py"

spec = importlib.util.spec_from_file_location(
    "extract_goal_loop_source_row_candidates",
    SCRIPT_PATH,
)
assert spec is not None
extract_goal_loop_source_row_candidates = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = extract_goal_loop_source_row_candidates
spec.loader.exec_module(extract_goal_loop_source_row_candidates)


class ExtractGoalLoopSourceRowCandidatesTest(unittest.TestCase):
    def test_inventory_extracts_only_explicit_rows(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            goal_loop = root / "GOAL_LOOP_INTEGRATION.md"
            goal_loop.write_text(
                "\n".join(
                    [
                        '| "R-FATAL-1" (* acquire timeout *) ->',
                        "│  NF-1: provider_health_skipped_all_models       🔴🔴   │",
                        "R-FATAL-1 appears again as a duplicate mention.",
                        "P-STR-01~03 is a range and must not invent omitted rows.",
                    ]
                ),
                encoding="utf-8",
            )
            derived = root / "audit_derived_state.md"
            derived.write_text(
                "### #1 [CRITICAL] `holder_table` — replica\n",
                encoding="utf-8",
            )
            deep = root / "deep_audit_dashboard_heuristic.md"
            deep.write_text(
                "### 3.1 `admission_queue.ml` — no-op\n",
                encoding="utf-8",
            )
            llm = root / "llm_compatibility.agent.final.md"
            llm.write_text(
                "| S01 | Silent Failure | `backend.ml` | dropped | log |\n"
                "| F01 | Fake Fallback | `backend.ml` | coerced | validate |\n",
                encoding="utf-8",
            )
            no_rows = root / "fundamental_roadmap.md"
            no_rows.write_text(
                "P-STR-01~03 is a range and must not invent omitted rows.\n",
                encoding="utf-8",
            )

            report = extract_goal_loop_source_row_candidates.inventory_sources(
                [goal_loop, derived, deep, llm, no_rows],
                expected_total=6,
            )

        self.assertEqual(report["status"], "COMPLETE")
        self.assertEqual(report["unique_candidate_rows"], 6)
        ids = {row["candidate_id"] for row in report["candidate_rows"]}
        self.assertEqual(
            ids,
            {
                "AUDIT-DERIVED-001",
                "DEEP-AUDIT-3-1",
                "F01",
                "NF-1",
                "R-FATAL-1",
                "S01",
            },
        )
        self.assertNotIn("P-STR-02", ids)
        self.assertTrue(
            all(
                row["source"]["path"].startswith("prompt_corpus/GOAL_LOOP/")
                for row in report["candidate_rows"]
            )
        )
        self.assertEqual(
            report["sources_without_candidates"],
            ["prompt_corpus/GOAL_LOOP/fundamental_roadmap.md"],
        )
        self.assertEqual(
            report["source_candidate_coverage"],
            {
                "sources_checked": 5,
                "sources_with_candidates": 4,
                "sources_without_candidates": 1,
            },
        )
        text_report = extract_goal_loop_source_row_candidates.report_to_text(report)
        self.assertIn(
            "NO_ROWS: prompt_corpus/GOAL_LOOP/fundamental_roadmap.md rows=0",
            text_report,
        )

    def test_inventory_reports_utf8_decode_errors(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "bad-source.md"
            path.write_bytes(b"\xff\xfe")

            report = extract_goal_loop_source_row_candidates.inventory_sources(
                [path],
                expected_total=0,
            )

        self.assertEqual(report["status"], "INCOMPLETE")
        self.assertEqual(report["source_errors_total"], 1)
        self.assertIn(
            "UnicodeDecodeError",
            report["source_errors"][0]["error"],
        )

    def test_cli_require_complete_fails_when_rows_are_missing(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "GOAL_LOOP_INTEGRATION.md"
            path.write_text(
                '| "R-FATAL-1" (* acquire timeout *) ->\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(path),
                    "--expected-total",
                    "2",
                    "--require-complete",
                    "--summary-only",
                    "--format",
                    "json",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "INCOMPLETE")
        self.assertEqual(payload["unique_candidate_rows"], 1)
        self.assertNotIn("candidate_rows", payload)


if __name__ == "__main__":
    unittest.main()
