#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = REPO_ROOT / "scripts"
SCRIPT_PATH = SCRIPT_DIR / "discover_goal_loop_strict_row_corpus.py"
CATALOG_FIXTURE = (
    REPO_ROOT / "test" / "fixtures" / "goal_loop" / "audit-corpus.external-claim.json"
)

sys.path.insert(0, str(SCRIPT_DIR))
spec = importlib.util.spec_from_file_location(
    "discover_goal_loop_strict_row_corpus",
    SCRIPT_PATH,
)
assert spec is not None
discover_goal_loop_strict_row_corpus = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = discover_goal_loop_strict_row_corpus
spec.loader.exec_module(discover_goal_loop_strict_row_corpus)


def synthetic_strict_row_corpus(row_count: int = 206) -> dict[str, object]:
    return {
        "schema_version": 1,
        "corpus_id": "synthetic-goal-loop-strict-row-corpus",
        "source_catalog_id": "goal-loop-206-audit-external-claim-2026-05-05",
        "status": "COMPLETE",
        "expected_findings_total": 206,
        "findings": [
            {
                "finding_id": f"ROW-{index + 1:03d}",
                "title": f"synthetic strict row {index + 1}",
                "severity": "warning",
                "actionability": "actionable",
                "decision_id": None,
                "patterns": [],
                "source": {
                    "path": "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
                    "line_refs": [1],
                },
                "replay_expectation": {
                    "phase": "orient",
                    "expected_status": "critical",
                },
            }
            for index in range(row_count)
        ],
    }


class DiscoverGoalLoopStrictRowCorpusTest(unittest.TestCase):
    def test_discover_distinguishes_marker_hits_from_valid_corpus(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            (root / "notes.md").write_text(
                "source_catalog_id without findings is only a marker hit\n",
                encoding="utf-8",
            )
            (root / "invalid-corpus.json").write_text(
                json.dumps(synthetic_strict_row_corpus(row_count=205)),
                encoding="utf-8",
            )
            valid_path = root / "strict-row-corpus.json"
            valid_path.write_text(
                json.dumps(synthetic_strict_row_corpus()),
                encoding="utf-8",
            )
            with zipfile.ZipFile(root / "candidate.zip", "w") as archive:
                archive.writestr(
                    "nested/marker.json",
                    json.dumps(
                        {
                            "source_catalog_id": "goal-loop-206-audit-external-claim-2026-05-05",
                            "expected_findings_total": 206,
                        }
                    ),
                )

            catalog = json.loads(CATALOG_FIXTURE.read_text(encoding="utf-8"))
            report = discover_goal_loop_strict_row_corpus.discover(
                [root],
                catalog=catalog,
            )

        self.assertGreaterEqual(report["marker_hits_total"], 3)
        self.assertEqual(report["candidate_corpora_total"], 2)
        self.assertEqual(report["validated_strict_corpora_total"], 1)
        validated = report["validated_strict_corpora"][0]
        self.assertTrue(validated["location"].endswith("strict-row-corpus.json"))
        invalid = [
            candidate
            for candidate in report["candidate_corpora"]
            if candidate["validated"] is False
        ]
        self.assertEqual(len(invalid), 1)
        self.assertIn("findings_count_mismatch", invalid[0]["errors"])

    def test_cli_require_found_fails_without_valid_corpus(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            (root / "marker.json").write_text(
                json.dumps(
                    {
                        "source_catalog_id": "goal-loop-206-audit-external-claim-2026-05-05",
                        "expected_findings_total": 206,
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(root),
                    "--audit-catalog",
                    str(CATALOG_FIXTURE),
                    "--require-found",
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
        self.assertEqual(payload["marker_hits_total"], 1)
        self.assertEqual(payload["validated_strict_corpora_total"], 0)


if __name__ == "__main__":
    unittest.main()
