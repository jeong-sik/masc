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
SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_completion_audit.py"
TRIAGE_FIXTURE = (
    REPO_ROOT
    / "test"
    / "fixtures"
    / "goal_loop"
    / "structured-id-triage.external-claim.json"
)

spec = importlib.util.spec_from_file_location("goal_loop_completion_audit", SCRIPT_PATH)
assert spec is not None
goal_loop_completion_audit = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = goal_loop_completion_audit
spec.loader.exec_module(goal_loop_completion_audit)


def complete_status() -> dict[str, object]:
    return {
        "phases": {
            "orient": {
                "summary": {
                    "audit_catalog": {
                        "status": "COMPLETE",
                        "expected_findings_total": 206,
                        "itemized_findings_total": 206,
                        "missing_itemized_findings": 0,
                        "source_documents_status": "COMPLETE",
                        "source_documents_covered": 12,
                        "source_documents_expected": 12,
                        "source_artifacts_status": "COMPLETE",
                        "source_artifacts_total": 12,
                        "source_artifacts_resolved": 12,
                        "source_artifacts_missing": 0,
                        "source_line_ref_errors": 0,
                        "source_identity_status": "COMPLETE",
                        "source_identity_checks_verified": 12,
                        "source_identity_checks_failed": 0,
                        "source_aggregate_claim_status": "COMPLETE",
                        "source_aggregate_claim_sources_verified": 5,
                        "source_aggregate_claim_sources_missing": 0,
                        "source_itemized_id_status": "COMPLETE",
                        "source_ids_missing_from_catalog": 0,
                        "catalog_ids_missing_from_source": 0,
                        "consistency_findings_total": 1,
                        "consistency_findings_open": 0,
                        "source_structured_item_ids_total": 206,
                        "source_structured_item_ids_uncataloged": 0,
                        "source_structured_item_ids_uncataloged_occurrences": 0,
                        "source_structured_item_id_families": [
                            {
                                "family": "NF",
                                "total": 8,
                                "uncataloged": 0,
                                "uncataloged_samples": [],
                            }
                        ],
                    }
                }
            },
            "verify": {
                "summary": {
                    "verify_status": "PASS",
                    "violations": 0,
                    "violation_kinds": [],
                }
            },
        }
    }


def blocked_status() -> dict[str, object]:
    status = json.loads(json.dumps(complete_status()))
    audit_catalog = status["phases"]["orient"]["summary"]["audit_catalog"]
    audit_catalog["status"] = "INCOMPLETE"
    audit_catalog["itemized_findings_total"] = 19
    audit_catalog["missing_itemized_findings"] = 187
    audit_catalog["consistency_findings_open"] = 1
    audit_catalog["source_structured_item_ids_total"] = 91
    audit_catalog["source_structured_item_ids_uncataloged"] = 72
    audit_catalog["source_structured_item_ids_uncataloged_occurrences"] = 260
    audit_catalog["source_structured_item_id_families"] = [
        {
            "family": "F",
            "total": 4,
            "uncataloged": 4,
            "uncataloged_samples": ["F01", "F02", "F03", "F04"],
        },
        {
            "family": "NEW",
            "total": 10,
            "uncataloged": 10,
            "uncataloged_samples": ["NEW-1"],
        },
        {
            "family": "P-DASH",
            "total": 13,
            "uncataloged": 13,
            "uncataloged_samples": ["P-DASH-01"],
        },
        {
            "family": "P-EIO",
            "total": 7,
            "uncataloged": 7,
            "uncataloged_samples": ["P-EIO-01"],
        },
        {
            "family": "P-FSM",
            "total": 10,
            "uncataloged": 10,
            "uncataloged_samples": ["P-FSM-01"],
        },
        {
            "family": "P-HARD",
            "total": 5,
            "uncataloged": 5,
            "uncataloged_samples": ["P-HARD-01"],
        },
        {
            "family": "P-MUT",
            "total": 2,
            "uncataloged": 2,
            "uncataloged_samples": ["P-MUT-01"],
        },
        {
            "family": "P-PROAC",
            "total": 1,
            "uncataloged": 1,
            "uncataloged_samples": ["P-PROAC-01"],
        },
        {
            "family": "P-PROV",
            "total": 4,
            "uncataloged": 4,
            "uncataloged_samples": ["P-PROV-01"],
        },
        {
            "family": "P-STR",
            "total": 3,
            "uncataloged": 3,
            "uncataloged_samples": ["P-STR-01"],
        },
        {
            "family": "P-TURN",
            "total": 3,
            "uncataloged": 3,
            "uncataloged_samples": ["P-TURN-02"],
        },
        {
            "family": "S",
            "total": 10,
            "uncataloged": 10,
            "uncataloged_samples": ["S01"],
        },
    ]
    verify_summary = status["phases"]["verify"]["summary"]
    verify_summary["verify_status"] = "FAIL"
    verify_summary["violations"] = 1
    verify_summary["violation_kinds"] = ["post_act_verify_pending"]
    return status


class GoalLoopCompletionAuditTest(unittest.TestCase):
    def test_completion_audit_passes_when_all_criteria_pass(self) -> None:
        audit = goal_loop_completion_audit.build_completion_audit(complete_status())

        self.assertEqual(audit.status, "COMPLETE")
        self.assertEqual(audit.blockers, [])
        self.assertTrue(all(item.status == "PASS" for item in audit.criteria))

    def test_completion_audit_blocks_current_incomplete_goal_state(self) -> None:
        audit = goal_loop_completion_audit.build_completion_audit(blocked_status())

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("strict_row_level_catalog_complete", audit.blockers)
        self.assertIn("aggregate_consistency_resolved", audit.blockers)
        self.assertIn("broader_structured_ids_triaged", audit.blockers)
        self.assertIn("post_act_verify_complete", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        self.assertEqual(
            by_id["broader_structured_ids_triaged"].status,
            "WARN",
        )
        self.assertEqual(
            by_id["strict_row_level_catalog_complete"].evidence[
                "missing_itemized_findings"
            ],
            187,
        )

    def test_completion_audit_accepts_structured_id_triage_manifest(self) -> None:
        triage = json.loads(TRIAGE_FIXTURE.read_text(encoding="utf-8"))
        audit = goal_loop_completion_audit.build_completion_audit(
            blocked_status(),
            structured_id_triage=triage,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertNotIn("broader_structured_ids_triaged", audit.blockers)
        self.assertIn("strict_row_level_catalog_complete", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        self.assertEqual(by_id["broader_structured_ids_triaged"].status, "PASS")
        self.assertEqual(
            by_id["broader_structured_ids_triaged"].evidence["structured_id_triage"][
                "triage_families_total"
            ],
            12,
        )

    def test_completion_audit_cli_can_fail_until_goal_is_closeable(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            status_path = Path(raw_dir) / "status.json"
            status_path.write_text(json.dumps(blocked_status()), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(status_path),
                    "--structured-id-triage",
                    str(TRIAGE_FIXTURE),
                    "--require-complete",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "BLOCKED")
        self.assertIn("post_act_verify_complete", payload["blockers"])
        self.assertNotIn("broader_structured_ids_triaged", payload["blockers"])


if __name__ == "__main__":
    unittest.main()
