#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
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
PROMPT_CHECKLIST_FIXTURE = (
    REPO_ROOT
    / "test"
    / "fixtures"
    / "goal_loop"
    / "prompt-closeout-checklist.external-claim.json"
)
AUTOBOOT_WARMUP_FAIRNESS_FIXTURE = (
    REPO_ROOT
    / "test"
    / "fixtures"
    / "goal_loop"
    / "autoboot-warmup-fairness.external-claim.json"
)
SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE = (
    REPO_ROOT
    / "test"
    / "fixtures"
    / "goal_loop"
    / "source-row-candidate-inventory.external-claim.json"
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


def blocked_verify_pipeline() -> dict[str, object]:
    return {
        "schema_version": 1,
        "status": "BLOCKED",
        "gates_total": 3,
        "gates_passed": 1,
        "gates_failed": 0,
        "gates_blocked": 2,
        "gates_skipped": 0,
        "gates": [
            {
                "gate_id": "unit_tests",
                "category": "unit_tests",
                "status": "PASS",
            },
            {
                "gate_id": "tla_prompt_spec_tierrouting",
                "category": "tla_check",
                "status": "BLOCKED",
                "reason": "prompt_tla_spec_missing",
            },
            {
                "gate_id": "post_act_log_contract",
                "category": "log_verification",
                "status": "BLOCKED",
                "reason": "missing_post_act_logs",
            },
        ],
    }


def passing_verify_pipeline() -> dict[str, object]:
    gates = [
        {
            "gate_id": gate_id,
            "category": "verify_pipeline",
            "status": "PASS",
        }
        for gate_id in sorted(goal_loop_completion_audit.REQUIRED_VERIFY_GATE_IDS)
    ]
    return {
        "schema_version": 1,
        "status": "PASS",
        "gates_total": len(gates),
        "gates_passed": len(gates),
        "gates_failed": 0,
        "gates_blocked": 0,
        "gates_skipped": 0,
        "gates": gates,
    }


class GoalLoopCompletionAuditTest(unittest.TestCase):
    def test_string_list_strips_and_rejects_empty_entries(self) -> None:
        self.assertEqual(
            goal_loop_completion_audit.string_list(
                [" prompt_corpus/GOAL_LOOP/a.md ", "", "   ", 42]
            ),
            ["prompt_corpus/GOAL_LOOP/a.md"],
        )

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

    def test_completion_audit_binds_strict_row_corpus_to_catalog_sources(
        self,
    ) -> None:
        status = complete_status()
        audit_catalog = status["phases"]["orient"]["summary"]["audit_catalog"]
        audit_catalog["external_sources"] = [
            {
                "path": "prompt_corpus/GOAL_LOOP/artifact_synthesis.md",
                "line_count": 500,
            }
        ]

        audit = goal_loop_completion_audit.build_completion_audit(
            status,
            strict_row_corpus=synthetic_strict_row_corpus(),
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("strict_row_level_catalog_complete", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        corpus_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "strict_row_corpus"
        ]
        self.assertFalse(corpus_evidence["validated"])
        self.assertTrue(corpus_evidence["catalog_source_binding_required"])
        self.assertFalse(corpus_evidence["catalog_source_binding_valid"])
        self.assertIn(
            "source_paths_must_match_catalog_external_sources",
            corpus_evidence["errors"],
        )

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

    def test_completion_audit_blocks_partial_verify_pipeline(self) -> None:
        audit = goal_loop_completion_audit.build_completion_audit(
            complete_status(),
            verify_pipeline=blocked_verify_pipeline(),
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("verify_pipeline_complete", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        evidence = by_id["verify_pipeline_complete"].evidence
        self.assertEqual(evidence["pipeline_status"], "BLOCKED")
        self.assertEqual(
            evidence["non_pass_gate_ids"],
            ["tla_prompt_spec_tierrouting", "post_act_log_contract"],
        )

    def test_completion_audit_accepts_passing_verify_pipeline(self) -> None:
        audit = goal_loop_completion_audit.build_completion_audit(
            complete_status(),
            verify_pipeline=passing_verify_pipeline(),
        )

        self.assertEqual(audit.status, "COMPLETE")
        self.assertNotIn("verify_pipeline_complete", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        self.assertEqual(by_id["verify_pipeline_complete"].status, "PASS")

    def test_completion_audit_rejects_partial_passing_verify_pipeline(self) -> None:
        partial = {
            "schema_version": 1,
            "status": "PASS",
            "gates_total": 1,
            "gates_passed": 1,
            "gates_failed": 0,
            "gates_blocked": 0,
            "gates_skipped": 0,
            "gates": [
                {
                    "gate_id": "unit_tests",
                    "category": "unit_tests",
                    "status": "PASS",
                }
            ],
        }
        audit = goal_loop_completion_audit.build_completion_audit(
            complete_status(),
            verify_pipeline=partial,
        )

        self.assertEqual(audit.status, "BLOCKED")
        by_id = {item.criterion_id: item for item in audit.criteria}
        evidence = by_id["verify_pipeline_complete"].evidence
        self.assertIn("post_act_log_contract", evidence["missing_gate_ids"])

    def test_completion_audit_rejects_verify_pipeline_count_mismatch(self) -> None:
        pipeline = passing_verify_pipeline()
        pipeline["gates_total"] = 1

        audit = goal_loop_completion_audit.build_completion_audit(
            complete_status(),
            verify_pipeline=pipeline,
        )

        self.assertEqual(audit.status, "BLOCKED")
        by_id = {item.criterion_id: item for item in audit.criteria}
        evidence = by_id["verify_pipeline_complete"].evidence
        self.assertFalse(evidence["counts_match"])

    def test_completion_audit_consumes_embedded_verify_pipeline(self) -> None:
        status = complete_status()
        verify_summary = status["phases"]["verify"]["summary"]
        verify_summary["verify_pipeline"] = blocked_verify_pipeline()

        audit = goal_loop_completion_audit.build_completion_audit(status)

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("verify_pipeline_complete", audit.blockers)

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
        self.assertEqual(
            discovery_evidence["candidate_artifacts_checked"],
            len(discovery["candidate_artifacts_checked"]),
        )
        self.assertTrue(discovery_evidence["expected_matches"])
        self.assertTrue(discovery_evidence["itemized_matches"])
        self.assertTrue(discovery_evidence["missing_matches"])
        self.assertTrue(discovery_evidence["strict_ids_match"])
        self.assertTrue(discovery_evidence["path_policy_valid"])
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

    def test_completion_audit_binds_strict_row_corpus_to_orient_sources(
        self,
    ) -> None:
        status = strict_catalog_only_blocked_status()
        audit_catalog = status["phases"]["orient"]["summary"]["audit_catalog"]
        fixture_catalog = json.loads(
            (
                REPO_ROOT
                / "test"
                / "fixtures"
                / "goal_loop"
                / "audit-corpus.external-claim.json"
            ).read_text(encoding="utf-8")
        )
        audit_catalog["external_sources"] = fixture_catalog["external_sources"]
        corpus = synthetic_strict_row_corpus()
        findings = corpus["findings"]
        assert isinstance(findings, list)
        first = findings[0]
        second = findings[1]
        assert isinstance(first, dict)
        assert isinstance(second, dict)
        first["source"] = {
            "path": "prompt_corpus/GOAL_LOOP/not-in-manifest.md",
            "line_refs": [1],
        }
        second["source"] = {
            "path": "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
            "line_refs": [607],
        }

        audit = goal_loop_completion_audit.build_completion_audit(
            status,
            strict_row_corpus=corpus,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        corpus_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "strict_row_corpus"
        ]
        self.assertFalse(corpus_evidence["validated"])
        self.assertIn(
            "source_paths_must_match_catalog_external_sources",
            corpus_evidence["errors"],
        )
        self.assertIn(
            "source_line_refs_must_be_within_catalog_line_count",
            corpus_evidence["errors"],
        )
        self.assertFalse(corpus_evidence["catalog_source_binding_valid"])

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

    def test_completion_audit_attaches_source_row_candidate_inventory(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertEqual(audit.blockers, ["strict_row_level_catalog_complete"])
        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertTrue(inventory_evidence["recorded"])
        self.assertEqual(inventory_evidence["unique_candidate_rows"], 132)
        self.assertEqual(inventory_evidence["missing_candidate_rows"], 74)
        self.assertTrue(inventory_evidence["expected_matches"])
        self.assertTrue(inventory_evidence["missing_candidate_rows_matches"])
        self.assertTrue(inventory_evidence["incomplete_against_expected"])
        self.assertTrue(inventory_evidence["candidates_by_file_total_matches"])
        self.assertTrue(inventory_evidence["candidates_by_rule_total_matches"])
        self.assertEqual(inventory_evidence["prompt_sources_checked"], 12)
        self.assertEqual(inventory_evidence["sources_with_candidates"], 5)
        self.assertEqual(inventory_evidence["sources_without_candidates"], 7)
        self.assertTrue(inventory_evidence["sources_accounted"])
        self.assertEqual(inventory_evidence["sources_without_candidate_details"], 7)
        self.assertTrue(inventory_evidence["no_candidate_details_accounted"])
        self.assertEqual(
            inventory_evidence["unstructured_markers_without_candidates"],
            897,
        )
        self.assertEqual(
            inventory_evidence["no_candidate_sources_with_tracking_issue_refs"],
            7,
        )
        self.assertEqual(
            inventory_evidence["no_candidate_tracking_issue_refs_total"],
            2,
        )
        self.assertEqual(
            inventory_evidence["missing_no_candidate_tracking_issue_refs"],
            [],
        )
        self.assertEqual(
            inventory_evidence["invalid_no_candidate_tracking_issue_refs"],
            [],
        )
        self.assertTrue(inventory_evidence["source_count_matches"])
        self.assertTrue(inventory_evidence["candidate_source_count_matches"])
        self.assertTrue(inventory_evidence["zero_source_count_matches"])
        self.assertTrue(inventory_evidence["unstructured_source_count_matches"])
        self.assertTrue(inventory_evidence["unstructured_marker_count_matches"])
        self.assertTrue(
            inventory_evidence["no_candidate_tracking_source_count_matches"]
        )
        self.assertTrue(inventory_evidence["source_currentness_evaluated"])
        self.assertEqual(
            inventory_evidence["source_currentness_checked_at"],
            "2026-05-06",
        )
        self.assertFalse(inventory_evidence["source_currentness_current"])
        self.assertTrue(inventory_evidence["source_currentness_consistent"])
        self.assertEqual(inventory_evidence["future_date_claims_total"], 7)
        self.assertEqual(inventory_evidence["future_date_claims_count"], 7)
        self.assertTrue(inventory_evidence["future_date_claims_total_matches"])
        self.assertEqual(inventory_evidence["sources_with_future_date_claims_total"], 4)
        self.assertTrue(inventory_evidence["future_date_sources_count_matches"])
        self.assertTrue(inventory_evidence["future_date_sources_match"])
        self.assertEqual(inventory_evidence["invalid_future_date_claims"], [])
        self.assertTrue(inventory_evidence["no_candidate_source_overlap"])
        self.assertFalse(inventory_evidence["local_path_leaks"])

    def test_completion_audit_accepts_complete_source_row_candidate_inventory(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        inventory["status"] = "COMPLETE"
        inventory["result"] = "EXPLICIT_SOURCE_ROWS_MATCH_EXPECTED"
        inventory["unique_candidate_rows"] = 206
        inventory["missing_candidate_rows"] = 0
        by_file = inventory["candidates_by_file"]
        by_rule = inventory["candidates_by_rule"]
        assert isinstance(by_file, list)
        assert isinstance(by_rule, list)
        first_file = by_file[0]
        first_rule = by_rule[0]
        assert isinstance(first_file, dict)
        assert isinstance(first_rule, dict)
        first_file["unique_candidate_rows"] += 74
        first_rule["unique_candidate_rows"] += 74

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertTrue(inventory_evidence["recorded"])
        self.assertTrue(inventory_evidence["complete_against_expected"])
        self.assertTrue(inventory_evidence["inventory_result_consistent"])

    def test_completion_audit_rejects_unhashable_source_inventory_paths(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        sources = inventory["prompt_sources_checked"]
        assert isinstance(sources, list)
        sources.append(["not", "hashable"])

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertFalse(inventory_evidence["recorded"])
        self.assertEqual(inventory_evidence["invalid_prompt_sources_checked"], 1)
        self.assertTrue(inventory_evidence["sources_accounted"])

    def test_completion_audit_rejects_invalid_source_inventory_paths(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        sources = inventory["prompt_sources_checked"]
        assert isinstance(sources, list)
        duplicate_source = sources[0]
        sources[1] = duplicate_source
        sources[2] = "   "
        sources[3] = "docs/not-a-goal-loop-source.md"

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertFalse(inventory_evidence["recorded"])
        self.assertEqual(inventory_evidence["invalid_prompt_sources_checked"], 1)
        self.assertEqual(
            inventory_evidence["duplicate_prompt_sources_checked"],
            [duplicate_source],
        )
        self.assertEqual(
            inventory_evidence["invalid_prompt_source_prefixes"],
            ["docs/not-a-goal-loop-source.md"],
        )
        self.assertFalse(inventory_evidence["prompt_sources_unique"])
        self.assertFalse(inventory_evidence["prompt_sources_have_expected_prefix"])
        self.assertFalse(inventory_evidence["prompt_sources_valid"])

    def test_completion_audit_rejects_non_list_source_inventory_paths(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        inventory["prompt_sources_checked"] = "prompt_corpus/GOAL_LOOP/not-a-list.md"

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertFalse(inventory_evidence["recorded"])
        self.assertFalse(inventory_evidence["prompt_sources_is_list"])
        self.assertEqual(inventory_evidence["invalid_prompt_sources_checked"], 1)
        self.assertFalse(inventory_evidence["prompt_sources_valid"])

    def test_completion_audit_rejects_inconsistent_source_row_candidate_inventory(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        by_file = inventory["candidates_by_file"]
        assert isinstance(by_file, list)
        first = by_file[0]
        assert isinstance(first, dict)
        first["unique_candidate_rows"] = 1
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        self.assertEqual(audit.status, "BLOCKED")
        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertFalse(inventory_evidence["recorded"])
        self.assertFalse(inventory_evidence["candidates_by_file_total_matches"])
        self.assertTrue(inventory_evidence["candidates_by_rule_total_matches"])

    def test_completion_audit_rejects_unaccounted_source_row_inventory(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        sources_without_candidates = inventory["sources_without_candidates"]
        assert isinstance(sources_without_candidates, list)
        sources_without_candidates.pop()
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        self.assertEqual(audit.status, "BLOCKED")
        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertFalse(inventory_evidence["recorded"])
        self.assertFalse(inventory_evidence["sources_accounted"])
        self.assertFalse(inventory_evidence["no_candidate_details_accounted"])
        self.assertFalse(inventory_evidence["zero_source_count_matches"])
        self.assertTrue(inventory_evidence["source_count_matches"])

    def test_completion_audit_rejects_untracked_no_candidate_source_markers(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        details = inventory["sources_without_candidate_details"]
        assert isinstance(details, list)
        first = details[0]
        assert isinstance(first, dict)
        first.pop("tracking_issue_refs")
        coverage = inventory["source_candidate_coverage"]
        assert isinstance(coverage, dict)
        coverage["no_candidate_sources_with_tracking_issue_refs"] -= 1

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertFalse(inventory_evidence["recorded"])
        self.assertEqual(
            inventory_evidence["missing_no_candidate_tracking_issue_refs"],
            [first["path"]],
        )
        self.assertFalse(inventory_evidence["no_candidate_details_accounted"])
        self.assertTrue(
            inventory_evidence["no_candidate_tracking_source_count_matches"]
        )

    def test_completion_audit_rejects_inconsistent_source_currentness(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        currentness = inventory["source_currentness"]
        assert isinstance(currentness, dict)
        currentness["future_date_claims_total"] = 0

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertFalse(inventory_evidence["recorded"])
        self.assertFalse(inventory_evidence["source_currentness_consistent"])
        self.assertFalse(inventory_evidence["future_date_claims_total_matches"])

    def test_completion_audit_rejects_wrong_catalog_source_row_candidate_inventory(
        self,
    ) -> None:
        inventory = json.loads(
            SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE.read_text(encoding="utf-8")
        )
        inventory["source_catalog_id"] = "wrong-catalog"
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            source_row_candidate_inventory=inventory,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertEqual(audit.blockers, ["strict_row_level_catalog_complete"])
        by_id = {item.criterion_id: item for item in audit.criteria}
        inventory_evidence = by_id["strict_row_level_catalog_complete"].evidence[
            "source_row_candidate_inventory"
        ]
        self.assertFalse(inventory_evidence["recorded"])
        self.assertFalse(inventory_evidence["source_catalog_id_matches"])
        self.assertEqual(
            inventory_evidence["inventory_source_catalog_id"],
            "wrong-catalog",
        )

    def test_completion_audit_attaches_prompt_closeout_checklist(self) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        warmup_fairness = json.loads(
            AUTOBOOT_WARMUP_FAIRNESS_FIXTURE.read_text(encoding="utf-8")
        )
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
            autoboot_warmup_fairness=warmup_fairness,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertEqual(
            audit.blockers,
            [
                "strict_row_level_catalog_complete",
                "prompt_requirements_closeout_complete",
            ],
        )
        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertTrue(checklist_evidence["recorded"])
        self.assertEqual(checklist_evidence["prompt_sources_checked"], 12)
        self.assertTrue(checklist_evidence["has_strict_corpus_blocker"])
        self.assertFalse(checklist_evidence["local_path_leaks"])
        self.assertEqual(checklist_evidence["requirements_total"], 21)
        self.assertEqual(checklist_evidence["status_counts"]["PASS"], 11)
        self.assertEqual(checklist_evidence["status_counts"]["PARTIAL"], 8)
        self.assertEqual(checklist_evidence["status_counts"]["BLOCKED"], 2)
        self.assertEqual(checklist_evidence["non_pass_requirements"], 10)
        self.assertEqual(
            checklist_evidence["requirements_with_tracking_issue_refs"],
            10,
        )
        self.assertEqual(checklist_evidence["tracking_issue_refs_total"], 7)
        self.assertEqual(checklist_evidence["missing_tracking_issue_refs"], [])
        self.assertEqual(checklist_evidence["invalid_tracking_issue_refs"], [])
        self.assertEqual(
            checklist_evidence["requirements_with_implementation_pr_refs"],
            10,
        )
        self.assertEqual(checklist_evidence["implementation_pr_refs_total"], 9)
        self.assertEqual(checklist_evidence["invalid_implementation_pr_refs"], [])
        self.assertEqual(checklist_evidence["artifact_refs_total"], 101)
        self.assertEqual(checklist_evidence["artifact_refs_resolved"], 101)
        self.assertEqual(checklist_evidence["artifact_ref_anchors_total"], 22)
        self.assertEqual(checklist_evidence["artifact_ref_anchors_resolved"], 22)
        self.assertTrue(checklist_evidence["artifact_refs_all_resolved"])
        self.assertEqual(checklist_evidence["missing_artifact_refs"], [])
        self.assertEqual(checklist_evidence["missing_artifact_ref_anchors"], [])
        self.assertEqual(checklist_evidence["invalid_artifact_refs"], [])
        warmup_evidence = by_id["autoboot_warmup_fairness_complete"].evidence
        self.assertEqual(by_id["autoboot_warmup_fairness_complete"].status, "PASS")
        self.assertEqual(warmup_evidence["late_keeper_name"], "verifier")
        self.assertEqual(warmup_evidence["late_keeper_warmup_sec"], 61)
        self.assertEqual(
            warmup_evidence["late_keeper_claimed_linear_warmup_sec"],
            255,
        )
        self.assertFalse(warmup_evidence["linear_sequence_detected"])
        self.assertEqual(warmup_evidence["max_observed_warmup_sec"], 74)
        closeout_evidence = by_id["prompt_requirements_closeout_complete"].evidence
        self.assertEqual(by_id["prompt_requirements_closeout_complete"].status, "FAIL")
        self.assertEqual(closeout_evidence["incomplete_requirements"], 12)
        self.assertEqual(closeout_evidence["non_pass_requirements"], 12)
        self.assertEqual(
            closeout_evidence["requirements_with_tracking_issue_refs"],
            12,
        )
        self.assertEqual(
            closeout_evidence["requirements_with_implementation_pr_refs"],
            10,
        )
        self.assertEqual(closeout_evidence["implementation_pr_refs_total"], 9)
        self.assertEqual(closeout_evidence["invalid_implementation_pr_refs"], [])
        self.assertTrue(closeout_evidence["has_strict_corpus_blocker"])

    def test_completion_audit_rejects_unbounded_autoboot_warmup_fairness(
        self,
    ) -> None:
        warmup_fairness = json.loads(
            AUTOBOOT_WARMUP_FAIRNESS_FIXTURE.read_text(encoding="utf-8")
        )
        keeper_rows = warmup_fairness["keeper_rows"]
        assert isinstance(keeper_rows, list)
        # Locate the verifier row by keeper_name rather than positional
        # index so the test stays correct under any harmless fixture
        # reordering.
        verifier_row = next(
            (row for row in keeper_rows
             if isinstance(row, dict) and row.get("keeper_name") == "verifier"),
            None,
        )
        assert verifier_row is not None, "fixture must contain a verifier row"
        verifier_row["warmup_sec"] = 255
        verifier_row["within_bound"] = False
        late_check = warmup_fairness["late_keeper_check"]
        assert isinstance(late_check, dict)
        late_check["warmup_sec"] = 255
        late_check["bounded_by_max_delay"] = False

        audit = goal_loop_completion_audit.build_completion_audit(
            complete_status(),
            autoboot_warmup_fairness=warmup_fairness,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("autoboot_warmup_fairness_complete", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        warmup_evidence = by_id["autoboot_warmup_fairness_complete"].evidence
        self.assertIn("keeper_rows", warmup_evidence["invalid_reasons"])
        self.assertIn("max_observed_warmup_sec", warmup_evidence["invalid_reasons"])
        self.assertIn("bounded_by_max_delay", warmup_evidence["invalid_reasons"])

    def test_completion_audit_rejects_invalid_closeout_prompt_sources(
        self,
    ) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        sources = checklist["prompt_sources_checked"]
        assert isinstance(sources, list)
        duplicate_source = sources[0]
        sources[1] = duplicate_source
        sources[2] = ""
        sources[3] = "docs/not-a-goal-loop-source.md"

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertEqual(checklist_evidence["invalid_prompt_sources_checked"], 1)
        self.assertEqual(
            checklist_evidence["duplicate_prompt_sources_checked"],
            [duplicate_source],
        )
        self.assertEqual(
            checklist_evidence["invalid_prompt_source_prefixes"],
            ["docs/not-a-goal-loop-source.md"],
        )
        self.assertFalse(checklist_evidence["prompt_sources_unique"])
        self.assertFalse(checklist_evidence["prompt_sources_have_expected_prefix"])
        self.assertFalse(checklist_evidence["prompt_sources_valid"])

    def test_completion_audit_rejects_non_list_closeout_prompt_sources(
        self,
    ) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        checklist["prompt_sources_checked"] = "prompt_corpus/GOAL_LOOP/not-a-list.md"

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertFalse(checklist_evidence["source_docs_complete"])
        self.assertFalse(checklist_evidence["prompt_sources_is_list"])
        self.assertEqual(checklist_evidence["invalid_prompt_sources_checked"], 1)
        self.assertFalse(checklist_evidence["prompt_sources_valid"])

    def test_completion_audit_accepts_prompt_checklist_without_strict_blocker(
        self,
    ) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        requirements = checklist["requirements"]
        assert isinstance(requirements, list)
        for requirement in requirements:
            assert isinstance(requirement, dict)
            requirement["status"] = "PASS"

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_criterion = by_id["prompt_to_artifact_checklist_recorded"]
        self.assertEqual(checklist_criterion.status, "PASS")
        self.assertFalse(checklist_criterion.evidence["has_strict_corpus_blocker"])
        self.assertTrue(checklist_criterion.evidence["recorded"])
        closeout_criterion = by_id["prompt_requirements_closeout_complete"]
        self.assertEqual(closeout_criterion.status, "PASS")
        self.assertEqual(closeout_criterion.evidence["incomplete_requirements"], 0)

    def test_completion_audit_rejects_duplicate_prompt_requirement_ids(
        self,
    ) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        requirements = checklist["requirements"]
        assert isinstance(requirements, list)
        first = requirements[0]
        second = requirements[1]
        assert isinstance(first, dict)
        assert isinstance(second, dict)
        second["requirement_id"] = first["requirement_id"]

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertEqual(
            checklist_evidence["duplicate_requirement_ids"],
            [first["requirement_id"]],
        )
        self.assertEqual(by_id["prompt_requirements_closeout_complete"].status, "FAIL")

    def test_completion_audit_rejects_untracked_incomplete_prompt_requirement(
        self,
    ) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        requirements = checklist["requirements"]
        assert isinstance(requirements, list)
        first = next(
            requirement
            for requirement in requirements
            if isinstance(requirement, dict) and requirement.get("status") == "PARTIAL"
        )
        assert isinstance(first, dict)
        first.pop("tracking_issue_refs")

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertEqual(
            checklist_evidence["missing_tracking_issue_refs"],
            [first["requirement_id"]],
        )
        self.assertIn(
            f"{first['requirement_id']}: missing_tracking_issue_refs",
            checklist_evidence["invalid_requirements"],
        )
        self.assertEqual(by_id["prompt_requirements_closeout_complete"].status, "FAIL")

    def test_completion_audit_rejects_invalid_prompt_implementation_pr_refs(
        self,
    ) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        requirements = checklist["requirements"]
        assert isinstance(requirements, list)
        first = requirements[0]
        assert isinstance(first, dict)
        first["implementation_pr_refs"] = [
            "https://github.com/jeong-sik/masc-mcp/issues/13630",
            "https://github.com/other/repo/pull/1",
        ]

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertEqual(
            checklist_evidence["invalid_implementation_pr_refs"],
            [first["requirement_id"]],
        )
        self.assertIn(
            f"{first['requirement_id']}: invalid_implementation_pr_refs",
            checklist_evidence["invalid_requirements"],
        )
        closeout_criterion = by_id["prompt_requirements_closeout_complete"]
        self.assertEqual(closeout_criterion.status, "FAIL")
        self.assertEqual(
            closeout_criterion.evidence["invalid_implementation_pr_refs"],
            [first["requirement_id"]],
        )

    def test_completion_audit_rejects_missing_prompt_artifact_refs(self) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        requirements = checklist["requirements"]
        assert isinstance(requirements, list)
        first = requirements[0]
        assert isinstance(first, dict)
        first["artifact_refs"] = [
            "test/fixtures/goal_loop/observe.startup.json",
            "test/fixtures/goal_loop/missing.prompt-artifact.json#NF-1",
        ]

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertFalse(checklist_evidence["artifact_refs_all_resolved"])
        self.assertEqual(checklist_evidence["artifact_refs_total"], 98)
        self.assertEqual(checklist_evidence["artifact_refs_resolved"], 97)
        self.assertEqual(
            checklist_evidence["missing_artifact_refs"],
            [
                (
                    f"{first['requirement_id']}: "
                    "test/fixtures/goal_loop/missing.prompt-artifact.json"
                )
            ],
        )
        self.assertIn(
            f"{first['requirement_id']}: missing_artifact_ref",
            checklist_evidence["invalid_requirements"],
        )

    def test_completion_audit_rejects_missing_prompt_artifact_ref_anchors(self) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        requirements = checklist["requirements"]
        assert isinstance(requirements, list)
        first = requirements[0]
        assert isinstance(first, dict)
        first["artifact_refs"] = [
            "test/fixtures/goal_loop/audit-corpus.external-claim.json#missing-anchor"
        ]

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertFalse(checklist_evidence["artifact_refs_all_resolved"])
        self.assertEqual(checklist_evidence["artifact_refs_total"], 97)
        self.assertEqual(checklist_evidence["artifact_refs_resolved"], 96)
        self.assertEqual(checklist_evidence["artifact_ref_anchors_total"], 20)
        self.assertEqual(checklist_evidence["artifact_ref_anchors_resolved"], 19)
        self.assertEqual(
            checklist_evidence["missing_artifact_ref_anchors"],
            [
                (
                    f"{first['requirement_id']}: "
                    "test/fixtures/goal_loop/audit-corpus.external-claim.json"
                    "#missing-anchor"
                )
            ],
        )
        self.assertIn(
            f"{first['requirement_id']}: missing_artifact_ref_anchor",
            checklist_evidence["invalid_requirements"],
        )

    def test_completion_audit_reports_prompt_artifact_ref_read_errors(self) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        requirements = checklist["requirements"]
        assert isinstance(requirements, list)
        first = requirements[0]
        assert isinstance(first, dict)
        first["artifact_refs"] = [
            "test/fixtures/goal_loop/audit-corpus.external-claim.json#NF-1"
        ]
        original_read_text = goal_loop_completion_audit.Path.read_text
        failed_once = False

        def read_text_with_error(path: Path, *args: object, **kwargs: object) -> str:
            nonlocal failed_once
            if path.name == "audit-corpus.external-claim.json" and not failed_once:
                failed_once = True
                raise OSError("synthetic read failure")
            return original_read_text(path, *args, **kwargs)

        with mock.patch.object(
            goal_loop_completion_audit.Path,
            "read_text",
            read_text_with_error,
        ):
            audit = goal_loop_completion_audit.build_completion_audit(
                strict_catalog_only_blocked_status(),
                prompt_closeout_checklist=checklist,
            )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertFalse(checklist_evidence["artifact_refs_all_resolved"])
        self.assertEqual(checklist_evidence["artifact_ref_anchors_total"], 20)
        self.assertEqual(checklist_evidence["artifact_ref_anchors_resolved"], 19)
        self.assertEqual(
            checklist_evidence["artifact_ref_read_errors"],
            [
                (
                    f"{first['requirement_id']}: "
                    "test/fixtures/goal_loop/audit-corpus.external-claim.json: "
                    "OSError"
                )
            ],
        )
        self.assertIn(
            f"{first['requirement_id']}: artifact_ref_read_error",
            checklist_evidence["invalid_requirements"],
        )

    def test_completion_audit_rejects_invalid_prompt_artifact_refs(self) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        requirements = checklist["requirements"]
        assert isinstance(requirements, list)
        first = requirements[0]
        assert isinstance(first, dict)
        first["artifact_refs"] = [
            "../outside.json",
            "/Users/dancer/Downloads/private-goal-loop.json",
        ]

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertFalse(checklist_evidence["artifact_refs_all_resolved"])
        self.assertEqual(
            checklist_evidence["invalid_artifact_refs"],
            [first["requirement_id"]],
        )
        self.assertEqual(checklist_evidence["missing_artifact_refs"], [])
        self.assertIn(
            f"{first['requirement_id']}: invalid_artifact_ref",
            checklist_evidence["invalid_requirements"],
        )

    def test_completion_audit_rejects_wrong_catalog_prompt_closeout_checklist(
        self,
    ) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        checklist["source_catalog_id"] = "wrong-catalog"
        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        self.assertEqual(audit.status, "BLOCKED")
        self.assertIn("prompt_to_artifact_checklist_recorded", audit.blockers)
        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertFalse(checklist_evidence["source_catalog_id_matches"])

    def test_completion_audit_rejects_invalid_prompt_closeout_sources(
        self,
    ) -> None:
        checklist = json.loads(PROMPT_CHECKLIST_FIXTURE.read_text(encoding="utf-8"))
        sources = checklist["prompt_sources_checked"]
        assert isinstance(sources, list)
        duplicate_source = sources[0]
        sources[1] = duplicate_source
        sources[2] = ""
        sources[3] = "docs/not-a-goal-loop-source.md"

        audit = goal_loop_completion_audit.build_completion_audit(
            strict_catalog_only_blocked_status(),
            prompt_closeout_checklist=checklist,
        )

        by_id = {item.criterion_id: item for item in audit.criteria}
        checklist_evidence = by_id["prompt_to_artifact_checklist_recorded"].evidence
        self.assertFalse(checklist_evidence["recorded"])
        self.assertFalse(checklist_evidence["source_docs_complete"])
        self.assertEqual(checklist_evidence["invalid_prompt_sources_checked"], 1)
        self.assertEqual(
            checklist_evidence["duplicate_prompt_sources_checked"],
            [duplicate_source],
        )
        self.assertEqual(
            checklist_evidence["invalid_prompt_source_prefixes"],
            ["docs/not-a-goal-loop-source.md"],
        )
        self.assertFalse(checklist_evidence["prompt_sources_unique"])
        self.assertFalse(checklist_evidence["prompt_sources_have_expected_prefix"])
        self.assertFalse(checklist_evidence["prompt_sources_valid"])

    def test_strict_row_corpus_contract_fixture_is_json(self) -> None:
        contract = json.loads(STRICT_ROW_CORPUS_CONTRACT_FIXTURE.read_text())

        self.assertEqual(contract["schema_version"], 1)
        self.assertEqual(contract["expected_findings_total"], 206)
        self.assertEqual(
            contract["source_path_prefix"],
            "prompt_corpus/GOAL_LOOP/",
        )
        self.assertIn("catalog external_sources", contract["catalog_source_binding"])

    def test_completion_audit_cli_can_fail_until_goal_is_closeable(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            status_path = Path(raw_dir) / "status.json"
            corpus_path = Path(raw_dir) / "strict-row-corpus.json"
            pipeline_path = Path(raw_dir) / "verify-pipeline.json"
            status_path.write_text(json.dumps(blocked_status()), encoding="utf-8")
            corpus_path.write_text(
                json.dumps(synthetic_strict_row_corpus()),
                encoding="utf-8",
            )
            pipeline_path.write_text(
                json.dumps(blocked_verify_pipeline()),
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
                    "--prompt-closeout-checklist",
                    str(PROMPT_CHECKLIST_FIXTURE),
                    "--source-row-candidate-inventory",
                    str(SOURCE_ROW_CANDIDATE_INVENTORY_FIXTURE),
                    "--verify-pipeline",
                    str(pipeline_path),
                    "--autoboot-warmup-fairness",
                    str(AUTOBOOT_WARMUP_FAIRNESS_FIXTURE),
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
        source_inventory = by_id["strict_row_level_catalog_complete"]["evidence"][
            "source_row_candidate_inventory"
        ]
        self.assertTrue(source_inventory["recorded"])
        self.assertEqual(source_inventory["unique_candidate_rows"], 132)
        self.assertTrue(source_inventory["source_currentness_evaluated"])
        self.assertFalse(source_inventory["source_currentness_current"])
        self.assertTrue(source_inventory["source_currentness_consistent"])
        self.assertEqual(source_inventory["future_date_claims_total"], 7)
        self.assertEqual(source_inventory["blocking_future_date_claims_total"], 3)
        self.assertTrue(source_inventory["future_date_claims_total_matches"])
        self.assertTrue(source_inventory["blocking_future_date_claims_total_matches"])
        strict_row_corpus = by_id["strict_row_level_catalog_complete"]["evidence"][
            "strict_row_corpus"
        ]
        self.assertTrue(strict_row_corpus["validated"])
        self.assertFalse(strict_row_corpus["orient_itemized_matches_corpus"])
        prompt_checklist = by_id["prompt_to_artifact_checklist_recorded"]
        self.assertEqual(prompt_checklist["status"], "PASS")
        prompt_closeout = by_id["prompt_requirements_closeout_complete"]
        self.assertEqual(prompt_closeout["status"], "FAIL")
        self.assertEqual(prompt_closeout["evidence"]["incomplete_requirements"], 12)
        warmup_fairness = by_id["autoboot_warmup_fairness_complete"]
        self.assertEqual(warmup_fairness["status"], "PASS")
        self.assertEqual(warmup_fairness["evidence"]["late_keeper_warmup_sec"], 61)


if __name__ == "__main__":
    unittest.main()
