#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_status.py"
DECIDE_SCRIPT_PATH = REPO_ROOT / "scripts" / "decide_goal_loop_findings.py"
FIXTURE_DIR = REPO_ROOT / "test" / "fixtures" / "goal_loop"

spec = importlib.util.spec_from_file_location("goal_loop_status", SCRIPT_PATH)
assert spec is not None
goal_loop_status = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = goal_loop_status
spec.loader.exec_module(goal_loop_status)


class GoalLoopStatusTest(unittest.TestCase):
    def test_build_status_report_marks_critical_and_next_action(self) -> None:
        report = goal_loop_status.build_status_report(
            observe={
                "files": ["server.log"],
                "total_lines": 12,
                "matched_lines": 3,
                "patterns": {
                    "alive_but_stuck": {
                        "count": 2,
                        "severity": "critical",
                    },
                    "metric_all_zero": {
                        "count": 1,
                        "severity": "warning",
                    },
                },
            },
            orient={
                "summary": {
                    "evidence_present": 2,
                    "critical_present": 1,
                    "findings_total": 10,
                },
                "findings": [
                    {
                        "finding_id": "NF-3",
                        "title": "alive_but_stuck_no_recovery",
                        "severity": "critical",
                        "status": "EVIDENCE_PRESENT",
                        "count": 2,
                    }
                ],
            },
            decide={
                "decisions_total": 1,
                "p0_count": 1,
                "act_missing_count": 1,
                "act_linked_count": 0,
                "decisions": [
                    {
                        "decision_id": "D-P1-1",
                        "action": "Execute recovery strategy",
                    }
                ],
            },
            verify={
                "status": "FAIL",
                "failing_findings": [{"finding_id": "NF-3"}],
            },
            generated_at="2026-05-05T10:00:00+00:00",
            loop_iteration="#1",
        )

        self.assertEqual(report.overall_status, "critical")
        self.assertEqual(report.phases["observe"].status, "critical")
        self.assertEqual(report.phases["act"].summary["act_missing_count"], 1)
        self.assertEqual(report.next_action["decision_id"], "D-P1-1")
        self.assertEqual(
            report.system_health_signals["keeper_failure_patterns"]["alive_but_stuck"],
            2,
        )

    def test_clean_inputs_produce_ok_status(self) -> None:
        report = goal_loop_status.build_status_report(
            observe={
                "files": ["server.log"],
                "total_lines": 5,
                "matched_lines": 0,
                "patterns": {},
            },
            orient={
                "summary": {
                    "evidence_present": 0,
                    "critical_present": 0,
                    "findings_total": 10,
                },
                "findings": [],
            },
            decide={
                "decisions_total": 0,
                "p0_count": 0,
                "decisions": [],
            },
            verify={"status": "PASS", "failing_findings": []},
            generated_at="2026-05-05T10:00:00+00:00",
        )

        self.assertEqual(report.overall_status, "ok")
        self.assertEqual(report.phases["act"].status, "ok")
        self.assertEqual(report.phases["verify"].summary["violation_kinds"], [])
        self.assertIsNone(report.next_action)

    def test_orient_audit_catalog_gap_keeps_goal_warning(self) -> None:
        report = goal_loop_status.build_status_report(
            observe={
                "files": ["server.log"],
                "total_lines": 5,
                "matched_lines": 0,
                "patterns": {},
            },
            orient={
                "summary": {
                    "evidence_present": 0,
                    "critical_present": 0,
                    "findings_total": 18,
                },
                "findings": [],
                "audit_catalog": {
                    "status": "INCOMPLETE",
                    "expected_findings_total": 206,
                    "itemized_findings_total": 19,
                    "missing_itemized_findings": 187,
                    "source_documents_status": "COMPLETE",
                    "source_documents_covered": 12,
                    "source_documents_expected": 12,
                    "aggregate_claims": [{"claim_id": "audit_total_206"}],
                    "consistency_findings": [{"finding_id": "CONSISTENCY-1"}],
                    "source_artifacts": {
                        "status": "INCOMPLETE",
                        "source_artifacts_total": 12,
                        "source_artifacts_resolved": 0,
                        "source_artifacts_missing": 12,
                        "line_ref_errors": 0,
                        "source_itemized_id_status": "INCOMPLETE",
                        "source_itemized_finding_ids_total": 0,
                        "catalog_itemized_finding_ids_total": 19,
                        "source_ids_missing_from_catalog": 0,
                        "catalog_ids_missing_from_source": 19,
                        "source_structured_item_ids_total": 0,
                        "source_structured_item_ids_uncataloged": 0,
                        "source_aggregate_claim_status": "INCOMPLETE",
                        "source_aggregate_claim_sources_verified": 0,
                        "source_aggregate_claim_sources_missing": 5,
                        "source_identity_status": "INCOMPLETE",
                        "source_identity_checks_verified": 0,
                        "source_identity_checks_failed": 12,
                    },
                },
            },
            decide={"decisions_total": 0, "p0_count": 0, "decisions": []},
            verify={"status": "PASS", "failing_findings": []},
            generated_at="2026-05-05T10:00:00+00:00",
        )

        self.assertEqual(report.overall_status, "warning")
        self.assertEqual(report.phases["orient"].status, "warning")
        audit_catalog = report.phases["orient"].summary["audit_catalog"]
        self.assertEqual(audit_catalog["source_documents_covered"], 12)
        self.assertEqual(audit_catalog["missing_itemized_findings"], 187)
        self.assertEqual(audit_catalog["consistency_findings_total"], 1)
        self.assertEqual(audit_catalog["consistency_findings_open"], 1)
        self.assertEqual(audit_catalog["source_artifacts_status"], "INCOMPLETE")
        self.assertEqual(audit_catalog["source_artifacts_missing"], 12)
        self.assertEqual(audit_catalog["source_itemized_id_status"], "INCOMPLETE")
        self.assertEqual(audit_catalog["source_itemized_finding_ids_total"], 0)
        self.assertEqual(audit_catalog["catalog_itemized_finding_ids_total"], 19)
        self.assertEqual(audit_catalog["catalog_ids_missing_from_source"], 19)
        self.assertEqual(audit_catalog["source_structured_item_ids_total"], 0)
        self.assertEqual(audit_catalog["source_structured_item_ids_uncataloged"], 0)
        self.assertEqual(audit_catalog["source_aggregate_claim_status"], "INCOMPLETE")
        self.assertEqual(audit_catalog["source_aggregate_claim_sources_verified"], 0)
        self.assertEqual(audit_catalog["source_aggregate_claim_sources_missing"], 5)
        self.assertEqual(audit_catalog["source_identity_status"], "INCOMPLETE")
        self.assertEqual(audit_catalog["source_identity_checks_verified"], 0)
        self.assertEqual(audit_catalog["source_identity_checks_failed"], 12)

    def test_closed_catalog_consistency_findings_do_not_warn(self) -> None:
        report = goal_loop_status.build_status_report(
            observe={
                "files": ["server.log"],
                "total_lines": 5,
                "matched_lines": 0,
                "patterns": {},
            },
            orient={
                "summary": {
                    "evidence_present": 0,
                    "critical_present": 0,
                    "findings_total": 18,
                },
                "findings": [],
                "audit_catalog": {
                    "status": "COMPLETE",
                    "expected_findings_total": 18,
                    "itemized_findings_total": 18,
                    "missing_itemized_findings": 0,
                    "source_documents_status": "COMPLETE",
                    "source_documents_covered": 12,
                    "source_documents_expected": 12,
                    "aggregate_claims": [],
                    "consistency_findings": [
                        {"finding_id": "CONSISTENCY-1", "status": "RESOLVED"}
                    ],
                    "source_artifacts": {
                        "status": "COMPLETE",
                        "source_artifacts_total": 12,
                        "source_artifacts_resolved": 12,
                        "source_artifacts_missing": 0,
                        "line_ref_errors": 0,
                        "source_itemized_id_status": "COMPLETE",
                        "source_itemized_finding_ids_total": 18,
                        "catalog_itemized_finding_ids_total": 18,
                        "source_ids_missing_from_catalog": 0,
                        "catalog_ids_missing_from_source": 0,
                        "source_structured_item_ids_total": 18,
                        "source_structured_item_ids_uncataloged": 0,
                        "source_aggregate_claim_status": "COMPLETE",
                        "source_aggregate_claim_sources_verified": 0,
                        "source_aggregate_claim_sources_missing": 0,
                        "source_identity_status": "COMPLETE",
                        "source_identity_checks_verified": 12,
                        "source_identity_checks_failed": 0,
                    },
                },
            },
            decide={"decisions_total": 0, "p0_count": 0, "decisions": []},
            verify={"status": "PASS", "failing_findings": []},
            generated_at="2026-05-05T10:00:00+00:00",
        )

        self.assertEqual(report.overall_status, "ok")
        audit_catalog = report.phases["orient"].summary["audit_catalog"]
        self.assertEqual(audit_catalog["consistency_findings_total"], 1)
        self.assertEqual(audit_catalog["consistency_findings_open"], 0)

    def test_malformed_catalog_consistency_finding_counts_open(self) -> None:
        self.assertTrue(goal_loop_status.consistency_finding_is_open("bad"))

    def test_missing_catalog_source_artifacts_keeps_goal_warning(self) -> None:
        report = goal_loop_status.build_status_report(
            observe={
                "files": ["server.log"],
                "total_lines": 5,
                "matched_lines": 0,
                "patterns": {},
            },
            orient={
                "summary": {
                    "evidence_present": 0,
                    "critical_present": 0,
                    "findings_total": 18,
                },
                "findings": [],
                "audit_catalog": {
                    "status": "COMPLETE",
                    "expected_findings_total": 18,
                    "itemized_findings_total": 18,
                    "missing_itemized_findings": 0,
                    "source_documents_status": "COMPLETE",
                    "source_documents_covered": 12,
                    "source_documents_expected": 12,
                    "aggregate_claims": [],
                    "consistency_findings": [],
                },
            },
            decide={"decisions_total": 0, "p0_count": 0, "decisions": []},
            verify={"status": "PASS", "failing_findings": []},
            generated_at="2026-05-05T10:00:00+00:00",
        )

        self.assertEqual(report.overall_status, "warning")
        self.assertEqual(report.phases["orient"].status, "warning")
        audit_catalog = report.phases["orient"].summary["audit_catalog"]
        self.assertEqual(audit_catalog["source_artifacts_status"], "NOT_CHECKED")

    def test_malformed_catalog_consistency_finding_stays_open(self) -> None:
        report = goal_loop_status.build_status_report(
            observe={
                "files": ["server.log"],
                "total_lines": 5,
                "matched_lines": 0,
                "patterns": {},
            },
            orient={
                "summary": {
                    "evidence_present": 0,
                    "critical_present": 0,
                    "findings_total": 18,
                },
                "findings": [],
                "audit_catalog": {
                    "status": "COMPLETE",
                    "source_documents_status": "COMPLETE",
                    "consistency_findings": ["malformed"],
                    "source_artifacts": {
                        "status": "COMPLETE",
                    },
                },
            },
            decide={"decisions_total": 0, "p0_count": 0, "decisions": []},
            verify={"status": "PASS", "failing_findings": []},
            generated_at="2026-05-05T10:00:00+00:00",
        )

        self.assertEqual(report.overall_status, "warning")
        audit_catalog = report.phases["orient"].summary["audit_catalog"]
        self.assertEqual(audit_catalog["consistency_findings_total"], 1)
        self.assertEqual(audit_catalog["consistency_findings_open"], 1)

    def test_next_action_prefers_missing_act_over_linked_decision(self) -> None:
        report = goal_loop_status.build_status_report(
            observe=None,
            orient=None,
            decide={
                "decisions_total": 2,
                "p0_count": 2,
                "act_missing_count": 1,
                "act_linked_count": 1,
                "decisions": [
                    {
                        "decision_id": "D-EMERGENCY-2",
                        "action": "Run bootstrap provider health checks",
                        "act_status": "ACT_LINKED",
                    },
                    {
                        "decision_id": "D-EMERGENCY-1",
                        "action": "Slot forced reclaim + credential auto-recovery",
                        "act_status": "ACT_MISSING",
                    },
                ],
            },
            verify=None,
            generated_at="2026-05-05T10:00:00+00:00",
        )

        self.assertEqual(report.next_action["decision_id"], "D-EMERGENCY-1")
        self.assertEqual(
            report.phases["decide"].summary["next_action"]["decision_id"],
            "D-EMERGENCY-1",
        )

    def test_missing_inputs_are_unknown(self) -> None:
        report = goal_loop_status.build_status_report(
            observe=None,
            orient=None,
            decide=None,
            verify=None,
            generated_at="2026-05-05T10:00:00+00:00",
        )

        self.assertEqual(report.overall_status, "unknown")
        self.assertEqual(
            report.phases["observe"].summary["reason"], "observe_json_missing"
        )
        self.assertEqual(report.phases["verify"].status, "unknown")

    def test_unknown_phase_prevents_overall_ok(self) -> None:
        report = goal_loop_status.build_status_report(
            observe={
                "files": ["server.log"],
                "total_lines": 1,
                "matched_lines": 0,
                "patterns": {},
            },
            orient=None,
            decide={"decisions_total": 0, "p0_count": 0, "decisions": []},
            verify={"status": "PASS", "failing_findings": []},
            generated_at="2026-05-05T10:00:00+00:00",
        )

        self.assertEqual(report.phases["observe"].status, "ok")
        self.assertEqual(report.phases["orient"].status, "unknown")
        self.assertEqual(report.overall_status, "unknown")

    def test_cli_reads_phase_json_and_fails_on_critical(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            observe_path = root / "observe.json"
            orient_path = root / "orient.json"
            decide_path = root / "decide.json"
            verify_path = root / "verify.json"
            observe_path.write_text(
                json.dumps(
                    {
                        "files": ["server.log"],
                        "total_lines": 1,
                        "matched_lines": 1,
                        "patterns": {
                            "provider_health_skipped": {
                                "count": 1,
                                "severity": "critical",
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            orient_path.write_text(
                json.dumps(
                    {
                        "summary": {
                            "evidence_present": 1,
                            "critical_present": 1,
                            "findings_total": 10,
                        },
                        "findings": [],
                    }
                ),
                encoding="utf-8",
            )
            decide_path.write_text(
                json.dumps(
                    {
                        "decisions_total": 1,
                        "p0_count": 1,
                        "decisions": [{"decision_id": "D-EMERGENCY-2"}],
                    }
                ),
                encoding="utf-8",
            )
            verify_path.write_text(
                json.dumps({"status": "PASS", "failing_findings": []}),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--observe-json",
                    str(observe_path),
                    "--orient-json",
                    str(orient_path),
                    "--decide-json",
                    str(decide_path),
                    "--verify-json",
                    str(verify_path),
                    "--fail-on",
                    "critical",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["overall_status"], "critical")
        self.assertEqual(
            payload["system_health_signals"]["provider_failure_patterns"][
                "provider_health_skipped"
            ],
            1,
        )

    def test_report_json_is_machine_readable(self) -> None:
        report = goal_loop_status.build_status_report(
            observe=None,
            orient=None,
            decide=None,
            verify=None,
            generated_at="2026-05-05T10:00:00+00:00",
        )

        payload = json.loads(goal_loop_status.report_to_json(report))
        self.assertEqual(payload, asdict(report))

    def test_fixture_bundle_reports_linked_act_from_decide_output(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            decide_path = Path(raw_dir) / "decide.json"
            decide_result = subprocess.run(
                [
                    sys.executable,
                    str(DECIDE_SCRIPT_PATH),
                    str(FIXTURE_DIR / "orient.startup.json"),
                    "--act-map",
                    str(FIXTURE_DIR / "act-map.startup.json"),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(decide_result.returncode, 0, decide_result.stderr)
            decide_path.write_text(decide_result.stdout, encoding="utf-8")

            status_result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--observe-json",
                    str(FIXTURE_DIR / "observe.startup.json"),
                    "--orient-json",
                    str(FIXTURE_DIR / "orient.startup.json"),
                    "--decide-json",
                    str(decide_path),
                    "--verify-json",
                    str(FIXTURE_DIR / "verify.fail.json"),
                    "--loop-iteration",
                    "#fixture",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(status_result.returncode, 0, status_result.stderr)
        payload = json.loads(status_result.stdout)
        self.assertEqual(payload["overall_status"], "critical")
        self.assertEqual(payload["loop_iteration"], "#fixture")
        self.assertEqual(payload["phases"]["decide"]["summary"]["act_linked_count"], 5)
        self.assertEqual(payload["phases"]["act"]["summary"]["act_missing_count"], 0)
        self.assertEqual(
            payload["phases"]["verify"]["summary"]["violation_kinds"],
            ["post_act_verify_pending"],
        )
        self.assertNotIn("audit_catalog", payload["phases"]["orient"]["summary"])
        self.assertEqual(payload["next_action"]["decision_id"], "D-EMERGENCY-2")
        self.assertEqual(
            payload["system_health_signals"]["keeper_failure_patterns"][
                "credential_archived_starvation"
            ],
            14,
        )


if __name__ == "__main__":
    unittest.main()
