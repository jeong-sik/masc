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
ROW_DISCOVERY_FIXTURE = (
    REPO_ROOT
    / "test"
    / "fixtures"
    / "goal_loop"
    / "row-corpus-discovery.external-claim.json"
)
STRICT_ROW_CORPUS_CONTRACT_FIXTURE = (
    REPO_ROOT / "test" / "fixtures" / "goal_loop" / "strict-row-corpus-contract.json"
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
                        "catalog_id": "goal-loop-206-audit-external-claim-2026-05-05",
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
                        "source_aggregate_claim_sources_verified": 6,
                        "source_aggregate_claim_sources_missing": 0,
                        "source_aggregate_reconciliation_status": "COMPLETE",
                        "source_aggregate_reconciliations_verified": 1,
                        "source_aggregate_reconciliations_failed": 0,
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
                    "post_act_verify": True,
                    "evidence_kind": "live_runtime_logs",
                    "evidence_source": "/tmp/goal-loop-post-act.log",
                    "evidence_window_start": "2026-05-05T17:29:12Z",
                    "evidence_window_end": "2026-05-06T00:00:00Z",
                    "checked_at": "2026-05-06T00:00:00Z",
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


def strict_catalog_only_blocked_status() -> dict[str, object]:
    status = json.loads(json.dumps(complete_status()))
    audit_catalog = status["phases"]["orient"]["summary"]["audit_catalog"]
    audit_catalog["status"] = "INCOMPLETE"
    audit_catalog["itemized_findings_total"] = 19
    audit_catalog["missing_itemized_findings"] = 187
    return status


def synthetic_strict_row_corpus(row_count: int = 206) -> dict[str, object]:
    return {
        "schema_version": 1,
        "corpus_id": "synthetic-goal-loop-strict-row-corpus",
        "source_catalog_id": "goal-loop-206-audit-external-claim-2026-05-05",
        "status": "COMPLETE",
        "expected_findings_total": 206,
        "path_policy": "logical_paths_only_no_user_local_paths",
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
            "FAIL",
        )
        self.assertEqual(
            by_id["broader_structured_ids_triaged"].evidence["severity"],
            "warning",
        )
        self.assertEqual(
            by_id["strict_row_level_catalog_complete"].evidence[
                "missing_itemized_findings"
            ],
            187,
        )

    def test_completion_audit_requires_verified_aggregate_reconciliation(self) -> None:
        status = complete_status()
        audit_catalog = status["phases"]["orient"]["summary"]["audit_catalog"]
        audit_catalog["source_aggregate_reconciliation_status"] = "INCOMPLETE"
        audit_catalog["source_aggregate_reconciliations_verified"] = 0
        audit_catalog["source_aggregate_reconciliations_failed"] = 1

        audit = goal_loop_completion_audit.build_completion_audit(status)

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("aggregate_consistency_resolved", audit.blockers)

    def test_completion_audit_rejects_generic_verify_pass_without_post_act_metadata(
        self,
    ) -> None:
        status = complete_status()
        verify_summary = status["phases"]["verify"]["summary"]
        for key in (
            "post_act_verify",
            "evidence_kind",
            "evidence_source",
            "evidence_window_start",
            "evidence_window_end",
            "checked_at",
        ):
            verify_summary.pop(key)

        audit = goal_loop_completion_audit.build_completion_audit(status)

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("post_act_verify_complete", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        self.assertFalse(by_id["post_act_verify_complete"].evidence["post_act_verify"])

    def test_completion_audit_rejects_verify_pass_without_evidence_window(
        self,
    ) -> None:
        status = complete_status()
        verify_summary = status["phases"]["verify"]["summary"]
        verify_summary.pop("evidence_window_start")

        audit = goal_loop_completion_audit.build_completion_audit(status)

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("post_act_verify_complete", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        self.assertIsNone(
            by_id["post_act_verify_complete"].evidence["evidence_window_start"]
        )

    def test_completion_audit_rejects_fixture_verify_as_post_act_evidence(
        self,
    ) -> None:
        status = complete_status()
        verify_summary = status["phases"]["verify"]["summary"]
        verify_summary["evidence_kind"] = "fixture"

        audit = goal_loop_completion_audit.build_completion_audit(status)

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("post_act_verify_complete", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        self.assertEqual(
            by_id["post_act_verify_complete"].evidence["evidence_kind"],
            "fixture",
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
        self.assertTrue(
            by_id["broader_structured_ids_triaged"].evidence["structured_id_triage"][
                "source_catalog_id_matches"
            ]
        )

    def test_completion_audit_rejects_wrong_catalog_structured_id_triage(
        self,
    ) -> None:
        triage = json.loads(TRIAGE_FIXTURE.read_text(encoding="utf-8"))
        triage["source_catalog_id"] = "wrong-catalog"
        audit = goal_loop_completion_audit.build_completion_audit(
            blocked_status(),
            structured_id_triage=triage,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("broader_structured_ids_triaged", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        triage_evidence = by_id["broader_structured_ids_triaged"].evidence[
            "structured_id_triage"
        ]
        self.assertFalse(triage_evidence["source_catalog_id_matches"])
        self.assertEqual(triage_evidence["triage_source_catalog_id"], "wrong-catalog")

    def test_completion_audit_attaches_row_corpus_discovery_without_closing(
        self,
    ) -> None:
        discovery = json.loads(ROW_DISCOVERY_FIXTURE.read_text(encoding="utf-8"))
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            row_corpus_discovery=discovery,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertEqual(audit.blockers, ["strict_row_level_catalog_complete"])
        by_id = {item.criterion_id: item for item in audit.criteria}
        discovery_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "row_corpus_discovery"
        ]
        self.assertTrue(discovery_evidence["recorded"])
        self.assertEqual(
            discovery_evidence["result"],
            "FULL_ROW_CORPUS_NOT_FOUND",
        )
        self.assertEqual(discovery_evidence["prompt_sources_checked"], 12)
        self.assertEqual(discovery_evidence["candidate_artifacts_checked"], 6)
        self.assertFalse(discovery_evidence["local_path_leaks"])
        self.assertTrue(discovery_evidence["source_catalog_id_matches"])

    def test_completion_audit_rejects_wrong_catalog_row_corpus_discovery(
        self,
    ) -> None:
        discovery = json.loads(ROW_DISCOVERY_FIXTURE.read_text(encoding="utf-8"))
        discovery["source_catalog_id"] = "wrong-catalog"
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            row_corpus_discovery=discovery,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertEqual(audit.blockers, ["strict_row_level_catalog_complete"])
        by_id = {item.criterion_id: item for item in audit.criteria}
        discovery_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "row_corpus_discovery"
        ]
        self.assertFalse(discovery_evidence["recorded"])
        self.assertFalse(discovery_evidence["source_catalog_id_matches"])
        self.assertEqual(
            discovery_evidence["discovery_source_catalog_id"],
            "wrong-catalog",
        )

    def test_completion_audit_validates_supplied_strict_row_corpus_without_closing_stale_orient(
        self,
    ) -> None:
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            strict_row_corpus=synthetic_strict_row_corpus(),
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertEqual(audit.blockers, ["strict_row_level_catalog_complete"])
        by_id = {item.criterion_id: item for item in audit.criteria}
        corpus_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "strict_row_corpus"
        ]
        self.assertTrue(corpus_evidence["provided"])
        self.assertTrue(corpus_evidence["validated"])
        self.assertEqual(corpus_evidence["row_count"], 206)
        self.assertFalse(corpus_evidence["orient_itemized_matches_corpus"])

    def test_completion_audit_rejects_invalid_supplied_strict_row_corpus(
        self,
    ) -> None:
        corpus = synthetic_strict_row_corpus()
        findings = corpus["findings"]
        assert isinstance(findings, list)
        first = findings[0]
        second = findings[1]
        third = findings[2]
        assert isinstance(first, dict)
        assert isinstance(second, dict)
        assert isinstance(third, dict)
        second["finding_id"] = first["finding_id"]
        corpus["source_catalog_id"] = "wrong-catalog"
        source = third["source"]
        assert isinstance(source, dict)
        source["path"] = "/home/example/Downloads/GOAL_LOOP_INTEGRATION.md"

        audit = goal_loop_completion_audit.build_completion_audit(
            complete_status(),
            strict_row_corpus=corpus,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertEqual(audit.blockers, ["strict_row_level_catalog_complete"])
        by_id = {item.criterion_id: item for item in audit.criteria}
        corpus_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "strict_row_corpus"
        ]
        self.assertFalse(corpus_evidence["validated"])
        self.assertIn("finding_ids_must_be_unique", corpus_evidence["errors"])
        self.assertIn("source_catalog_id_mismatch", corpus_evidence["errors"])
        self.assertIn("contains_user_local_path", corpus_evidence["errors"])
        self.assertIn(
            "source_paths_must_be_logical_prompt_corpus_paths",
            corpus_evidence["errors"],
        )

    def test_completion_audit_marks_missing_row_corpus_discovery(self) -> None:
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
        )

        self.assertEqual(audit.status, "BLOCKED")
        by_id = {item.criterion_id: item for item in audit.criteria}
        discovery_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "row_corpus_discovery"
        ]
        self.assertEqual(discovery_evidence["discovery_status"], "MISSING")
        self.assertFalse(discovery_evidence["recorded"])

    def test_strict_row_corpus_contract_fixture_is_json(self) -> None:
        contract = json.loads(STRICT_ROW_CORPUS_CONTRACT_FIXTURE.read_text())

        self.assertEqual(contract["schema_version"], 1)
        self.assertEqual(contract["expected_findings_total"], 206)
        self.assertEqual(
            contract["source_path_prefix"],
            "prompt_corpus/GOAL_LOOP/",
        )

    def test_completion_audit_cli_can_fail_until_goal_is_closeable(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            status_path = Path(raw_dir) / "status.json"
            corpus_path = Path(raw_dir) / "strict-row-corpus.json"
            status_path.write_text(json.dumps(blocked_status()), encoding="utf-8")
            corpus_path.write_text(
                json.dumps(synthetic_strict_row_corpus()),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    str(status_path),
                    "--structured-id-triage",
                    str(TRIAGE_FIXTURE),
                    "--row-corpus-discovery",
                    str(ROW_DISCOVERY_FIXTURE),
                    "--strict-row-corpus",
                    str(corpus_path),
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
        by_id = {item["criterion_id"]: item for item in payload["criteria"]}
        row_discovery = by_id["strict_row_level_catalog_complete"]["evidence"][
            "row_corpus_discovery"
        ]
        self.assertTrue(row_discovery["recorded"])
        strict_row_corpus = by_id["strict_row_level_catalog_complete"]["evidence"][
            "strict_row_corpus"
        ]
        self.assertTrue(strict_row_corpus["validated"])
        self.assertFalse(strict_row_corpus["orient_itemized_matches_corpus"])


if __name__ == "__main__":
    unittest.main()
