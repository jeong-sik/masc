#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "observe_goal_loop_logs.py"
ORIENT_SCRIPT_PATH = REPO_ROOT / "scripts" / "orient_goal_loop_logs.py"
VALIDATE_STRICT_CORPUS_SCRIPT_PATH = (
    REPO_ROOT / "scripts" / "validate_goal_loop_strict_row_corpus.py"
)
DECIDE_SCRIPT_PATH = REPO_ROOT / "scripts" / "decide_goal_loop_findings.py"
VERIFY_SCRIPT_PATH = REPO_ROOT / "scripts" / "verify_goal_loop_logs.py"
FIXTURE_DIR = REPO_ROOT / "test" / "fixtures" / "goal_loop"

spec = importlib.util.spec_from_file_location("observe_goal_loop_logs", SCRIPT_PATH)
assert spec is not None
observe_goal_loop_logs = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = observe_goal_loop_logs
spec.loader.exec_module(observe_goal_loop_logs)

orient_spec = importlib.util.spec_from_file_location(
    "orient_goal_loop_logs", ORIENT_SCRIPT_PATH
)
assert orient_spec is not None
orient_goal_loop_logs = importlib.util.module_from_spec(orient_spec)
assert orient_spec.loader is not None
sys.modules[orient_spec.name] = orient_goal_loop_logs
orient_spec.loader.exec_module(orient_goal_loop_logs)

decide_spec = importlib.util.spec_from_file_location(
    "decide_goal_loop_findings", DECIDE_SCRIPT_PATH
)
assert decide_spec is not None
decide_goal_loop_findings = importlib.util.module_from_spec(decide_spec)
assert decide_spec.loader is not None
sys.modules[decide_spec.name] = decide_goal_loop_findings
decide_spec.loader.exec_module(decide_goal_loop_findings)

verify_spec = importlib.util.spec_from_file_location(
    "verify_goal_loop_logs", VERIFY_SCRIPT_PATH
)
assert verify_spec is not None
verify_goal_loop_logs = importlib.util.module_from_spec(verify_spec)
assert verify_spec.loader is not None
sys.modules[verify_spec.name] = verify_goal_loop_logs
verify_spec.loader.exec_module(verify_goal_loop_logs)


def json_from_fixture(name: str) -> dict[str, object]:
    data = json.loads((FIXTURE_DIR / name).read_text(encoding="utf-8"))
    assert isinstance(data, dict)
    return data


def catalog_finding_ids(catalog: dict[str, object]) -> list[str]:
    findings = catalog["findings"]
    assert isinstance(findings, list)
    ids: list[str] = []
    for finding in findings:
        assert isinstance(finding, dict)
        finding_id = finding["finding_id"]
        assert isinstance(finding_id, str)
        ids.append(finding_id)
    return ids


def catalog_without_source_identity(catalog: dict[str, object]) -> dict[str, object]:
    stripped = json.loads(json.dumps(catalog))
    assert isinstance(stripped, dict)
    external_sources = stripped["external_sources"]
    assert isinstance(external_sources, list)
    for source in external_sources:
        assert isinstance(source, dict)
        source.pop("sha256", None)
        source.pop("line_count", None)
    return stripped


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


def source_text_with_optional_ids(source_path: str, ids: list[str]) -> str:
    body = "source line\n" * 2000
    source_name = Path(source_path).name
    if source_name == "INTEGRATED_IMPROVEMENT_DESIGN.md":
        body += "214건 감사 결과\nGOAL: 36개 Keeper 동시 운영\n"
    elif source_name == "GOAL_LOOP_INTEGRATION.md":
        body += "206건 감사 결과\n206 findings from audit\n"
        body += "NEW_FINDING: 8 from live logs\n"
        body += "\n".join(ids) + "\n"
    elif source_name == "fundamental_roadmap.md":
        body += "206건 감사 결과\n"
    elif source_name == "live_incident_analysis.md":
        body += "206건의 감사 결과\n"
    return body


def structured_family_map(source_artifacts: dict[str, object]) -> dict[str, dict]:
    families = source_artifacts["source_structured_item_id_families"]
    assert isinstance(families, list)
    result: dict[str, dict] = {}
    for family in families:
        assert isinstance(family, dict)
        family_name = family["family"]
        assert isinstance(family_name, str)
        result[family_name] = family
    return result


class ObserveGoalLoopLogsTest(unittest.TestCase):
    def test_scan_counts_prompt_signatures(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "server.log"
            path.write_text(
                "\n".join(
                    [
                        '{"status":"skipped","error":"runtime provider health is advisory; bootstrap skips live probe"}',
                        "[WARN] [Auth] archived credential sangsu.json (reason: bare-form keeper credential is dead after PR-3b1 starvation)",
                        "[WARN] [Keeper] nick0cave: alive-but-stuck detected (elapsed=924857s)",
                        "[WARN] keeper skipping turn after semaphore wait p99=240s",
                        "pricing_catalog_miss model=glm-4.7",
                        "[WARN] [Governance] Governance judge returned unparseable response (Lenient_json fallback hit; 3809 chars)",
                        "[WARN] [Keeper] keeper TOML jobsian_purist.toml has unknown keys: keeper.base",
                        "[INFO] verifier: warmup=255s",
                        "[WARN] tool_policy unknown tools: foo, bar, baz",
                        "[ERROR] keeper checkpoint migration data loss detected",
                        "[keepers_json:*] sub-op: meta=12ms agent=7ms ka=0ms audit=0ms profile=0ms phase=0ms activity=0ms",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            report = observe_goal_loop_logs.scan_logs([str(path)], max_samples=2)

        self.assertEqual(report.total_lines, 11)
        self.assertEqual(report.patterns["keeper_skipping_turn"].count, 1)
        self.assertEqual(report.patterns["pricing_catalog_miss"].count, 1)
        self.assertEqual(report.patterns["provider_health_skipped"].count, 1)
        self.assertEqual(report.patterns["credential_archived_starvation"].count, 1)
        self.assertEqual(report.patterns["alive_but_stuck"].count, 1)
        self.assertEqual(report.patterns["governance_unparseable"].count, 1)
        self.assertEqual(report.patterns["lenient_json_fallback"].count, 1)
        self.assertEqual(report.patterns["config_unknown_key"].count, 1)
        self.assertEqual(report.patterns["autoboot_warmup"].count, 1)
        self.assertEqual(report.patterns["tool_policy_unknown_tools"].count, 1)
        self.assertEqual(
            report.patterns["keeper_checkpoint_migration_data_loss"].count, 1
        )
        self.assertEqual(report.patterns["metric_all_zero"].count, 1)

    def test_fail_on_critical_exits_nonzero(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--fail-on",
                "critical",
                "-",
            ],
            input="[WARN] [Keeper] alive-but-stuck detected\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("alive_but_stuck", result.stdout)

    def test_orient_reports_present_findings_from_scan_json(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            empty_log = Path(raw_dir) / "empty.log"
            empty_log.write_text("", encoding="utf-8")
            scan = observe_goal_loop_logs.scan_logs([str(empty_log)], max_samples=1)
        scan.patterns["provider_health_skipped"].count = 1
        scan.patterns["provider_health_skipped"].samples.append(
            observe_goal_loop_logs.MatchSample(
                path="server.log",
                line=1,
                text="bootstrap skips live probe",
            )
        )
        scan.patterns["config_unknown_key"].count = 1

        report = orient_goal_loop_logs.orient_scan(
            {
                "files": scan.files,
                "total_lines": scan.total_lines,
                "matched_lines": scan.matched_lines,
                "patterns": {
                    name: {
                        "count": item.count,
                        "severity": item.severity,
                        "description": item.description,
                        "samples": [
                            {
                                "path": sample.path,
                                "line": sample.line,
                                "text": sample.text,
                            }
                            for sample in item.samples
                        ],
                    }
                    for name, item in scan.patterns.items()
                },
            }
        )

        by_id = {finding.finding_id: finding for finding in report.findings}
        self.assertEqual(by_id["NF-1"].status, "EVIDENCE_PRESENT")
        self.assertEqual(by_id["NF-6"].status, "EVIDENCE_PRESENT")
        self.assertEqual(by_id["NF-2"].status, "EVIDENCE_ABSENT")
        self.assertEqual(report.summary["evidence_present"], 2)
        self.assertEqual(report.summary["critical_present"], 1)

    def test_orient_catalog_exposes_incomplete_206_claim(self) -> None:
        scan = json_from_fixture("observe.startup.json")
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )

        report = orient_goal_loop_logs.orient_scan(scan, audit_catalog=catalog)
        by_id = {finding.finding_id: finding for finding in report.findings}

        self.assertIsNotNone(report.audit_catalog)
        assert report.audit_catalog is not None
        self.assertEqual(report.audit_catalog["status"], "INCOMPLETE")
        self.assertEqual(report.audit_catalog["expected_findings_total"], 206)
        self.assertEqual(report.audit_catalog["itemized_findings_total"], 19)
        self.assertEqual(report.audit_catalog["missing_itemized_findings"], 187)
        self.assertEqual(report.audit_catalog["source_documents_expected"], 12)
        self.assertEqual(report.audit_catalog["source_documents_covered"], 12)
        self.assertEqual(report.audit_catalog["source_documents_status"], "COMPLETE")
        self.assertEqual(report.audit_catalog["external_sources_total"], 12)
        self.assertEqual(len(report.audit_catalog["aggregate_claims"]), 4)
        self.assertEqual(len(report.audit_catalog["aggregate_reconciliations"]), 1)
        self.assertEqual(len(report.audit_catalog["consistency_findings"]), 1)
        self.assertEqual(report.audit_catalog["consistency_findings_total"], 1)
        self.assertEqual(report.audit_catalog["consistency_findings_open"], 0)
        self.assertEqual(
            report.audit_catalog["consistency_findings"][0]["finding_id"],
            "CONSISTENCY-1",
        )
        self.assertEqual(report.summary["findings_total"], 19)
        self.assertEqual(report.summary["not_evaluated"], 9)
        self.assertEqual(by_id["NF-2"].status, "EVIDENCE_PRESENT")
        self.assertEqual(by_id["CD-8"].status, "NOT_EVALUATED")
        self.assertEqual(by_id["CD-8"].decision_id, "D-P1-1")

    def test_orient_catalog_can_use_compact_builtin_finding_rows(self) -> None:
        scan = json_from_fixture("observe.startup.json")

        report = orient_goal_loop_logs.orient_scan(
            scan,
            audit_catalog={"findings": [{"finding_id": "NF-1"}]},
        )

        by_id = {finding.finding_id: finding for finding in report.findings}
        self.assertEqual(by_id["NF-1"].title, "provider_health_skipped_all_models")
        self.assertEqual(by_id["NF-1"].severity, "critical")
        self.assertEqual(by_id["NF-1"].patterns, ["provider_health_skipped"])
        self.assertEqual(by_id["NF-1"].status, "EVIDENCE_PRESENT")

    def test_orient_catalog_can_validate_missing_source_artifacts(self) -> None:
        scan = json_from_fixture("observe.startup.json")
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )

        with tempfile.TemporaryDirectory() as raw_dir:
            report = orient_goal_loop_logs.orient_scan(
                scan,
                audit_catalog=catalog,
                audit_source_root=Path(raw_dir),
            )

        self.assertIsNotNone(report.audit_catalog)
        assert report.audit_catalog is not None
        source_artifacts = report.audit_catalog["source_artifacts"]
        self.assertEqual(source_artifacts["status"], "INCOMPLETE")
        self.assertEqual(source_artifacts["source_artifacts_total"], 12)
        self.assertEqual(source_artifacts["source_artifacts_resolved"], 0)
        self.assertEqual(source_artifacts["source_artifacts_missing"], 12)
        self.assertEqual(source_artifacts["source_itemized_id_status"], "INCOMPLETE")
        self.assertEqual(source_artifacts["source_itemized_finding_ids_total"], 0)
        self.assertEqual(source_artifacts["catalog_itemized_finding_ids_total"], 19)
        self.assertEqual(source_artifacts["catalog_ids_missing_from_source"], 19)
        self.assertEqual(source_artifacts["source_structured_item_ids_total"], 0)
        self.assertEqual(source_artifacts["source_structured_item_ids_uncataloged"], 0)
        self.assertEqual(
            source_artifacts["source_aggregate_claim_status"], "INCOMPLETE"
        )
        self.assertEqual(source_artifacts["source_aggregate_claim_sources_total"], 6)
        self.assertEqual(source_artifacts["source_aggregate_claim_sources_missing"], 6)
        self.assertEqual(
            source_artifacts["source_aggregate_reconciliation_status"], "COMPLETE"
        )
        self.assertEqual(
            source_artifacts["source_aggregate_reconciliations_verified"], 1
        )
        self.assertEqual(source_artifacts["source_identity_status"], "INCOMPLETE")
        self.assertEqual(source_artifacts["source_identity_checks_total"], 12)
        self.assertEqual(source_artifacts["source_identity_checks_failed"], 12)
        self.assertIn(
            "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
            source_artifacts["missing_paths"],
        )

    def test_orient_catalog_rejects_source_escape_and_bad_line_refs(self) -> None:
        catalog: dict[str, object] = {
            "expected_findings_total": 1,
            "source_documents_expected": 1,
            "external_sources": [
                {"path": "../secret.md", "line_refs": [1]},
                {"path": "valid.md", "line_refs": [0, -1, 3]},
            ],
            "findings": [
                {
                    "finding_id": "NF-1",
                    "title": "provider_health_skipped_all_models",
                    "severity": "critical",
                    "patterns": ["provider_health_skipped"],
                    "source": {"path": "valid.md", "line_refs": [0, 3]},
                }
            ],
        }
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            (root / "valid.md").write_text("NF-1\nsource line\n", encoding="utf-8")
            summary = orient_goal_loop_logs.source_artifact_summary(catalog, root)

        assert summary is not None
        self.assertEqual(summary["status"], "INCOMPLETE")
        self.assertEqual(summary["source_artifacts_invalid_paths"], 1)
        self.assertEqual(summary["invalid_paths"], ["../secret.md"])
        self.assertEqual(summary["line_ref_errors"], 1)
        self.assertEqual(
            summary["line_ref_error_samples"][0]["line_refs"],
            [-1, 0, 3],
        )

    def test_orient_catalog_counts_only_valid_external_sources(self) -> None:
        summary = orient_goal_loop_logs.audit_catalog_summary(
            {
                "expected_findings_total": 0,
                "source_documents_expected": 1,
                "external_sources": [
                    {"path": "valid.md", "line_refs": [1]},
                    {"path": "", "line_refs": [1]},
                    {"path": "bad.md", "line_refs": "1"},
                    "not-an-object",
                ],
                "findings": [],
            }
        )

        assert summary is not None
        self.assertEqual(summary["external_sources_total"], 1)
        self.assertEqual(summary["external_sources_invalid"], 3)
        self.assertEqual(summary["source_documents_status"], "COMPLETE")

    def test_orient_catalog_marks_over_itemized_catalogs(self) -> None:
        summary = orient_goal_loop_logs.audit_catalog_summary(
            {
                "expected_findings_total": 1,
                "findings": [
                    {"finding_id": "NF-1"},
                    {"finding_id": "NF-2"},
                ],
            }
        )

        assert summary is not None
        self.assertEqual(summary["status"], "OVER_ITEMIZED")
        self.assertEqual(summary["missing_itemized_findings"], 0)
        self.assertEqual(summary["extra_itemized_findings"], 1)

    def test_orient_catalog_merges_partial_builtin_overrides(self) -> None:
        specs = orient_goal_loop_logs.merged_specs(
            {"findings": [{"finding_id": "NF-1", "severity": "warning"}]}
        )
        nf1 = next(spec for spec in specs if spec.finding_id == "NF-1")

        self.assertEqual(nf1.title, "provider_health_skipped_all_models")
        self.assertEqual(nf1.severity, "warning")
        self.assertEqual(nf1.patterns, ("provider_health_skipped",))

    def test_orient_catalog_can_validate_external_source_root(self) -> None:
        scan = json_from_fixture("observe.startup.json")
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        catalog = catalog_without_source_identity(catalog)
        external_sources = catalog["external_sources"]
        assert isinstance(external_sources, list)
        ids = catalog_finding_ids(catalog)

        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            for source in external_sources:
                assert isinstance(source, dict)
                source_path = source["path"]
                assert isinstance(source_path, str)
                (root / Path(source_path).name).write_text(
                    source_text_with_optional_ids(source_path, ids),
                    encoding="utf-8",
                )

            report = orient_goal_loop_logs.orient_scan(
                scan,
                audit_catalog=catalog,
                audit_source_root=root,
                audit_source_strip_prefix="prompt_corpus/GOAL_LOOP",
            )

        self.assertIsNotNone(report.audit_catalog)
        assert report.audit_catalog is not None
        source_artifacts = report.audit_catalog["source_artifacts"]
        self.assertEqual(source_artifacts["status"], "COMPLETE")
        self.assertEqual(source_artifacts["source_artifacts_total"], 12)
        self.assertEqual(source_artifacts["source_artifacts_resolved"], 12)
        self.assertEqual(source_artifacts["source_artifacts_missing"], 0)
        self.assertEqual(source_artifacts["line_ref_errors"], 0)
        self.assertEqual(source_artifacts["source_itemized_id_status"], "COMPLETE")
        self.assertEqual(source_artifacts["source_itemized_finding_ids_total"], 19)
        self.assertEqual(source_artifacts["catalog_itemized_finding_ids_total"], 19)
        self.assertEqual(source_artifacts["source_ids_missing_from_catalog"], 0)
        self.assertEqual(source_artifacts["catalog_ids_missing_from_source"], 0)
        self.assertEqual(source_artifacts["source_structured_item_ids_total"], 19)
        self.assertEqual(source_artifacts["source_structured_item_ids_uncataloged"], 0)
        families = structured_family_map(source_artifacts)
        self.assertEqual(families["CC"]["total"], 1)
        self.assertEqual(families["R-FATAL"]["total"], 2)
        self.assertEqual(families["NF"]["total"], 8)
        self.assertEqual(source_artifacts["source_aggregate_claim_status"], "COMPLETE")
        self.assertEqual(source_artifacts["source_aggregate_claim_sources_total"], 6)
        self.assertEqual(source_artifacts["source_aggregate_claim_sources_verified"], 6)
        self.assertEqual(source_artifacts["source_aggregate_claim_sources_missing"], 0)
        self.assertEqual(
            source_artifacts["source_aggregate_reconciliation_status"], "COMPLETE"
        )
        self.assertEqual(
            source_artifacts["source_aggregate_reconciliations_verified"], 1
        )
        self.assertEqual(source_artifacts["source_aggregate_reconciliations_failed"], 0)
        self.assertEqual(source_artifacts["source_identity_status"], "NOT_APPLICABLE")

    def test_orient_can_ingest_valid_strict_row_corpus_as_catalog_basis(self) -> None:
        scan = json_from_fixture("observe.startup.json")
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        catalog = catalog_without_source_identity(catalog)
        external_sources = catalog["external_sources"]
        assert isinstance(external_sources, list)
        corpus = synthetic_strict_row_corpus()

        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            for source in external_sources:
                assert isinstance(source, dict)
                source_path = source["path"]
                assert isinstance(source_path, str)
                (root / Path(source_path).name).write_text(
                    source_text_with_optional_ids(source_path, []),
                    encoding="utf-8",
                )

            report = orient_goal_loop_logs.orient_scan(
                scan,
                audit_catalog=catalog,
                strict_row_corpus=corpus,
                audit_source_root=root,
                audit_source_strip_prefix="prompt_corpus/GOAL_LOOP",
            )

        self.assertIsNotNone(report.audit_catalog)
        assert report.audit_catalog is not None
        self.assertEqual(report.audit_catalog["status"], "COMPLETE")
        self.assertEqual(report.audit_catalog["itemized_findings_total"], 206)
        self.assertEqual(report.audit_catalog["missing_itemized_findings"], 0)
        strict_summary = report.audit_catalog["strict_row_corpus"]
        self.assertTrue(strict_summary["validated"])
        self.assertEqual(strict_summary["row_count"], 206)
        source_artifacts = report.audit_catalog["source_artifacts"]
        self.assertEqual(source_artifacts["status"], "COMPLETE")
        self.assertEqual(
            source_artifacts["source_itemized_id_basis"],
            "strict_row_corpus",
        )
        self.assertEqual(source_artifacts["source_itemized_finding_ids_total"], 206)
        self.assertEqual(
            source_artifacts["source_document_itemized_finding_ids_total"],
            0,
        )
        self.assertEqual(source_artifacts["catalog_itemized_finding_ids_total"], 206)
        self.assertEqual(source_artifacts["catalog_ids_missing_from_source"], 0)
        self.assertEqual(report.summary["findings_total"], 206)

    def test_orient_rejects_invalid_strict_row_corpus_without_completing_catalog(
        self,
    ) -> None:
        scan = json_from_fixture("observe.startup.json")
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        corpus = synthetic_strict_row_corpus()
        findings = corpus["findings"]
        assert isinstance(findings, list)
        first = findings[0]
        second = findings[1]
        third = findings[2]
        fourth = findings[3]
        fifth = findings[4]
        assert isinstance(first, dict)
        assert isinstance(second, dict)
        assert isinstance(third, dict)
        assert isinstance(fourth, dict)
        assert isinstance(fifth, dict)
        second["finding_id"] = first["finding_id"]
        source = third["source"]
        assert isinstance(source, dict)
        source["path"] = "/home/example/Downloads/GOAL_LOOP_INTEGRATION.md"
        fourth_source = fourth["source"]
        assert isinstance(fourth_source, dict)
        fourth_source["line_refs"] = [0, "bad"]
        fifth["replay_expectation"] = {"phase": "", "expected_status": ""}

        report = orient_goal_loop_logs.orient_scan(
            scan,
            audit_catalog=catalog,
            strict_row_corpus=corpus,
        )

        self.assertIsNotNone(report.audit_catalog)
        assert report.audit_catalog is not None
        self.assertEqual(report.audit_catalog["status"], "INCOMPLETE")
        self.assertEqual(report.audit_catalog["itemized_findings_total"], 19)
        strict_summary = report.audit_catalog["strict_row_corpus"]
        self.assertFalse(strict_summary["validated"])
        self.assertIn("finding_ids_must_be_unique", strict_summary["errors"])
        self.assertIn("contains_user_local_path", strict_summary["errors"])
        self.assertEqual(
            strict_summary["invalid_source_path_values"][0]["path"],
            "/home/example/Downloads/GOAL_LOOP_INTEGRATION.md",
        )
        self.assertEqual(
            strict_summary["invalid_line_ref_values"][0]["line_refs"],
            [0, "bad"],
        )
        self.assertEqual(
            strict_summary["invalid_replay_expectation_values"][0][
                "replay_expectation"
            ],
            {"phase": "", "expected_status": ""},
        )

    def test_strict_row_corpus_requires_integer_expected_total(self) -> None:
        missing = synthetic_strict_row_corpus()
        missing.pop("expected_findings_total")
        missing_report = orient_goal_loop_logs.validate_strict_row_corpus(missing)

        self.assertFalse(missing_report["validated"])
        self.assertIn("expected_findings_total_must_be_int", missing_report["errors"])

        string_total = synthetic_strict_row_corpus()
        string_total["expected_findings_total"] = "206"
        string_report = orient_goal_loop_logs.validate_strict_row_corpus(string_total)

        self.assertFalse(string_report["validated"])
        self.assertIn("expected_findings_total_must_be_int", string_report["errors"])

    def test_strict_row_corpus_rejects_partial_catalog_by_default(self) -> None:
        report = orient_goal_loop_logs.validate_strict_row_corpus(
            synthetic_strict_row_corpus(),
            catalog={},
        )

        self.assertFalse(report["validated"])
        self.assertIn("catalog_external_sources_must_be_list", report["errors"])
        self.assertFalse(report["catalog_source_binding_valid"])

    def test_strict_row_corpus_can_skip_catalog_binding_explicitly(self) -> None:
        report = orient_goal_loop_logs.validate_strict_row_corpus(
            synthetic_strict_row_corpus(),
            catalog={},
            require_catalog_sources=False,
        )

        self.assertTrue(report["validated"])
        self.assertNotIn("expected_findings_total_mismatch", report["errors"])
        self.assertFalse(report["catalog_source_binding_required"])

    def test_strict_row_corpus_rejects_sources_when_catalog_manifest_is_empty(
        self,
    ) -> None:
        report = orient_goal_loop_logs.validate_strict_row_corpus(
            synthetic_strict_row_corpus(),
            catalog={"external_sources": []},
        )

        self.assertFalse(report["validated"])
        self.assertIn(
            "source_paths_must_match_catalog_external_sources",
            report["errors"],
        )
        self.assertEqual(report["catalog_external_sources_total"], 0)
        self.assertFalse(report["catalog_source_binding_valid"])

    def test_strict_row_corpus_binds_sources_to_catalog_manifest(self) -> None:
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        corpus = synthetic_strict_row_corpus()
        findings = corpus["findings"]
        assert isinstance(findings, list)
        unknown_source = findings[0]
        out_of_bounds_source = findings[1]
        assert isinstance(unknown_source, dict)
        assert isinstance(out_of_bounds_source, dict)
        unknown_source["source"] = {
            "path": "prompt_corpus/GOAL_LOOP/not-in-manifest.md",
            "line_refs": [1],
        }
        out_of_bounds_source["source"] = {
            "path": "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
            "line_refs": [607],
        }

        report = orient_goal_loop_logs.validate_strict_row_corpus(
            corpus,
            catalog=catalog,
        )

        self.assertFalse(report["validated"])
        self.assertIn(
            "source_paths_must_match_catalog_external_sources",
            report["errors"],
        )
        self.assertIn(
            "source_line_refs_must_be_within_catalog_line_count",
            report["errors"],
        )
        self.assertEqual(report["catalog_external_sources_total"], 12)
        self.assertFalse(report["catalog_source_binding_valid"])
        self.assertEqual(
            report["invalid_catalog_source_path_values"][0]["path"],
            "prompt_corpus/GOAL_LOOP/not-in-manifest.md",
        )
        self.assertEqual(
            report["invalid_catalog_line_ref_values"][0]["line_count"],
            606,
        )

    def test_strict_row_corpus_rejects_empty_catalog_source_manifest(self) -> None:
        corpus = synthetic_strict_row_corpus()
        catalog = {
            "catalog_id": "goal-loop-206-audit-external-claim-2026-05-05",
            "expected_findings_total": 206,
            "external_sources": [],
        }

        report = orient_goal_loop_logs.validate_strict_row_corpus(
            corpus,
            catalog=catalog,
        )

        self.assertFalse(report["validated"])
        self.assertIn(
            "source_paths_must_match_catalog_external_sources",
            report["errors"],
        )
        self.assertEqual(report["catalog_external_sources_total"], 0)
        self.assertFalse(report["catalog_source_binding_valid"])

    def test_orient_catalog_validates_source_identity_hash_and_line_count(self) -> None:
        content = "206건 감사 결과\nR-FATAL-1\n"
        catalog = {
            "external_sources": [
                {
                    "path": "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
                    "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
                    "line_count": 2,
                    "line_refs": [1, 2],
                }
            ],
            "aggregate_claims": [
                {
                    "claim_id": "audit_total_206",
                    "claimed_total": 206,
                    "source_paths": [
                        "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md"
                    ],
                }
            ],
            "findings": [{"finding_id": "R-FATAL-1"}],
        }

        with tempfile.TemporaryDirectory() as raw_dir:
            source_path = Path(raw_dir) / "GOAL_LOOP_INTEGRATION.md"
            source_path.write_text(content, encoding="utf-8")
            source_artifacts = orient_goal_loop_logs.source_artifact_summary(
                catalog,
                Path(raw_dir),
                source_strip_prefix="prompt_corpus/GOAL_LOOP",
            )

        assert source_artifacts is not None
        self.assertEqual(source_artifacts["status"], "COMPLETE")
        self.assertEqual(source_artifacts["source_identity_status"], "COMPLETE")
        self.assertEqual(source_artifacts["source_identity_checks_verified"], 1)
        self.assertEqual(source_artifacts["source_identity_checks_failed"], 0)
        self.assertEqual(source_artifacts["source_structured_item_ids_total"], 1)
        self.assertEqual(source_artifacts["source_structured_item_ids_uncataloged"], 0)

    def test_source_line_count_uses_splitlines_semantics(self) -> None:
        self.assertEqual(orient_goal_loop_logs.source_text_line_count("a\nb"), 2)
        self.assertEqual(orient_goal_loop_logs.source_text_line_count("a\nb\n"), 2)

    def test_source_artifact_decode_error_is_reported_without_crashing(self) -> None:
        content_bytes = b"R-FATAL-1\n\xff\n"
        catalog = {
            "external_sources": [
                {
                    "path": "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
                    "sha256": hashlib.sha256(content_bytes).hexdigest(),
                    "line_count": 2,
                    "line_refs": [1, 2],
                }
            ],
            "findings": [{"finding_id": "R-FATAL-1"}],
        }

        with tempfile.TemporaryDirectory() as raw_dir:
            source_path = Path(raw_dir) / "GOAL_LOOP_INTEGRATION.md"
            source_path.write_bytes(content_bytes)
            source_artifacts = orient_goal_loop_logs.source_artifact_summary(
                catalog,
                Path(raw_dir),
                source_strip_prefix="prompt_corpus/GOAL_LOOP",
            )

        assert source_artifacts is not None
        self.assertEqual(source_artifacts["status"], "INCOMPLETE")
        self.assertEqual(source_artifacts["source_decode_errors"], 1)
        sample = source_artifacts["source_decode_error_samples"][0]
        self.assertEqual(
            sample["path"],
            "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
        )
        self.assertEqual(sample["error"], "unicode_decode_error")
        self.assertEqual(source_artifacts["source_identity_status"], "COMPLETE")
        self.assertEqual(source_artifacts["source_itemized_id_status"], "COMPLETE")

    def test_source_artifact_read_error_is_reported_without_crashing(self) -> None:
        catalog = {
            "external_sources": [
                {
                    "path": "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
                    "line_refs": [1],
                }
            ],
            "findings": [{"finding_id": "R-FATAL-1"}],
        }

        with tempfile.TemporaryDirectory() as raw_dir:
            source_path = Path(raw_dir) / "GOAL_LOOP_INTEGRATION.md"
            source_path.write_text("R-FATAL-1\n", encoding="utf-8")
            with mock.patch.object(
                Path,
                "read_bytes",
                side_effect=PermissionError(13, "denied"),
            ):
                source_artifacts = orient_goal_loop_logs.source_artifact_summary(
                    catalog,
                    Path(raw_dir),
                    source_strip_prefix="prompt_corpus/GOAL_LOOP",
                )

        assert source_artifacts is not None
        self.assertEqual(source_artifacts["status"], "INCOMPLETE")
        self.assertEqual(source_artifacts["source_read_errors"], 1)
        sample = source_artifacts["source_read_error_samples"][0]
        self.assertEqual(
            sample["path"],
            "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
        )
        self.assertEqual(sample["error"], "read_error")
        self.assertEqual(sample["exception"], "PermissionError")
        self.assertEqual(sample["errno"], 13)

    def test_orient_catalog_validates_aggregate_reconciliation_arithmetic(self) -> None:
        catalog: dict[str, object] = {
            "aggregate_claims": [
                {"claim_id": "audit_total_206", "claimed_total": 206},
                {"claim_id": "new_findings_live_8", "claimed_total": 8},
                {"claim_id": "audit_total_214", "claimed_total": 214},
            ],
            "aggregate_reconciliations": [
                {
                    "reconciliation_id": "audit_total_214_equals_206_plus_8_new",
                    "target_claim_id": "audit_total_214",
                    "operation": "sum",
                    "terms": [
                        {"claim_id": "audit_total_206"},
                        {"claim_id": "new_findings_live_8"},
                    ],
                }
            ],
        }

        summary = orient_goal_loop_logs.aggregate_reconciliation_summary(catalog)
        self.assertEqual(summary["source_aggregate_reconciliation_status"], "COMPLETE")
        self.assertEqual(summary["source_aggregate_reconciliations_verified"], 1)

        aggregate_claims = catalog["aggregate_claims"]
        assert isinstance(aggregate_claims, list)
        new_findings_claim = aggregate_claims[1]
        assert isinstance(new_findings_claim, dict)
        new_findings_claim["claimed_total"] = 7
        summary = orient_goal_loop_logs.aggregate_reconciliation_summary(catalog)

        self.assertEqual(
            summary["source_aggregate_reconciliation_status"], "INCOMPLETE"
        )
        self.assertEqual(summary["source_aggregate_reconciliations_failed"], 1)
        self.assertEqual(
            summary["source_aggregate_reconciliation_error_samples"][0]["error"],
            "arithmetic_mismatch",
        )
        self.assertEqual(
            summary["source_aggregate_reconciliation_error_samples"][0][
                "computed_total"
            ],
            213,
        )

    def test_orient_catalog_groups_uncataloged_structured_source_ids(self) -> None:
        content = "\n".join(
            [
                "NF-1",
                "NEW-1",
                "P-DASH-01",
                "F01",
                "S02",
                "",
            ]
        )
        catalog = {
            "external_sources": [
                {"path": "prompt_corpus/GOAL_LOOP/source.md", "line_refs": [1]}
            ],
            "findings": [{"finding_id": "NF-1"}],
        }

        with tempfile.TemporaryDirectory() as raw_dir:
            source_path = Path(raw_dir) / "source.md"
            source_path.write_text(content, encoding="utf-8")
            source_artifacts = orient_goal_loop_logs.source_artifact_summary(
                catalog,
                Path(raw_dir),
                source_strip_prefix="prompt_corpus/GOAL_LOOP",
            )

        assert source_artifacts is not None
        self.assertEqual(source_artifacts["status"], "COMPLETE")
        self.assertEqual(source_artifacts["source_itemized_id_status"], "COMPLETE")
        self.assertEqual(source_artifacts["source_structured_item_ids_total"], 5)
        self.assertEqual(source_artifacts["source_structured_item_ids_uncataloged"], 4)
        self.assertEqual(
            source_artifacts["source_structured_item_ids_uncataloged_occurrences"],
            4,
        )
        self.assertIn(
            {
                "item_id": "NEW-1",
                "family": "NEW",
                "path": "prompt_corpus/GOAL_LOOP/source.md",
                "line": 2,
            },
            source_artifacts[
                "source_structured_item_ids_uncataloged_occurrence_samples"
            ],
        )
        families = structured_family_map(source_artifacts)
        self.assertEqual(families["NF"]["total"], 1)
        self.assertEqual(families["NF"]["uncataloged"], 0)
        self.assertEqual(families["NEW"]["uncataloged_samples"], ["NEW-1"])
        self.assertEqual(families["P-DASH"]["uncataloged_samples"], ["P-DASH-01"])
        self.assertEqual(families["F"]["uncataloged_samples"], ["F01"])
        self.assertEqual(families["S"]["uncataloged_samples"], ["S02"])

    def test_orient_catalog_detects_source_identity_mismatch(self) -> None:
        catalog = {
            "external_sources": [
                {
                    "path": "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
                    "sha256": "0" * 64,
                    "line_count": 999,
                    "line_refs": [1],
                }
            ],
            "findings": [],
        }

        with tempfile.TemporaryDirectory() as raw_dir:
            source_path = Path(raw_dir) / "GOAL_LOOP_INTEGRATION.md"
            source_path.write_text("source line\n", encoding="utf-8")
            source_artifacts = orient_goal_loop_logs.source_artifact_summary(
                catalog,
                Path(raw_dir),
                source_strip_prefix="prompt_corpus/GOAL_LOOP",
            )

        assert source_artifacts is not None
        self.assertEqual(source_artifacts["status"], "INCOMPLETE")
        self.assertEqual(source_artifacts["source_identity_status"], "INCOMPLETE")
        self.assertEqual(source_artifacts["source_identity_checks_failed"], 1)
        sample = source_artifacts["source_identity_error_samples"][0]
        self.assertIn("sha256", sample)
        self.assertIn("line_count", sample)

    def test_orient_catalog_can_detect_missing_aggregate_claim_evidence(self) -> None:
        scan = json_from_fixture("observe.startup.json")
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        catalog = catalog_without_source_identity(catalog)
        external_sources = catalog["external_sources"]
        assert isinstance(external_sources, list)
        ids = catalog_finding_ids(catalog)

        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            for source in external_sources:
                assert isinstance(source, dict)
                source_path = source["path"]
                assert isinstance(source_path, str)
                body = "source line\n" * 2000
                if Path(source_path).name == "GOAL_LOOP_INTEGRATION.md":
                    body += "\n".join(ids) + "\n"
                (root / Path(source_path).name).write_text(body, encoding="utf-8")

            report = orient_goal_loop_logs.orient_scan(
                scan,
                audit_catalog=catalog,
                audit_source_root=root,
                audit_source_strip_prefix="prompt_corpus/GOAL_LOOP",
            )

        self.assertIsNotNone(report.audit_catalog)
        assert report.audit_catalog is not None
        source_artifacts = report.audit_catalog["source_artifacts"]
        self.assertEqual(source_artifacts["status"], "INCOMPLETE")
        self.assertEqual(source_artifacts["source_itemized_id_status"], "COMPLETE")
        self.assertEqual(source_artifacts["source_structured_item_ids_total"], 19)
        self.assertEqual(source_artifacts["source_structured_item_ids_uncataloged"], 0)
        self.assertEqual(
            source_artifacts["source_aggregate_claim_status"], "INCOMPLETE"
        )
        self.assertEqual(source_artifacts["source_aggregate_claim_sources_total"], 6)
        self.assertEqual(source_artifacts["source_aggregate_claim_sources_verified"], 0)
        self.assertEqual(source_artifacts["source_aggregate_claim_sources_missing"], 6)
        self.assertEqual(
            source_artifacts["source_aggregate_claim_missing_samples"][0]["claim_id"],
            "audit_total_206",
        )

    def test_orient_catalog_rejects_source_paths_outside_root(self) -> None:
        catalog = {
            "external_sources": [
                {"path": "../outside.md", "line_refs": [1]},
                {"path": "/tmp/outside.md", "line_refs": [1]},
            ],
            "findings": [],
        }

        with tempfile.TemporaryDirectory() as raw_dir:
            source_artifacts = orient_goal_loop_logs.source_artifact_summary(
                catalog,
                Path(raw_dir),
            )

        assert source_artifacts is not None
        self.assertEqual(source_artifacts["status"], "INCOMPLETE")
        self.assertEqual(source_artifacts["source_artifacts_invalid_paths"], 2)
        self.assertEqual(
            source_artifacts["invalid_paths"], ["../outside.md", "/tmp/outside.md"]
        )

    def test_orient_cli_can_fail_on_incomplete_catalog(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(ORIENT_SCRIPT_PATH),
                str(FIXTURE_DIR / "observe.startup.json"),
                "--audit-catalog",
                str(FIXTURE_DIR / "audit-corpus.external-claim.json"),
                "--require-complete-catalog",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn('"status": "INCOMPLETE"', result.stdout)

    def test_orient_cli_can_fail_on_missing_source_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            result = subprocess.run(
                [
                    sys.executable,
                    str(ORIENT_SCRIPT_PATH),
                    str(FIXTURE_DIR / "observe.startup.json"),
                    "--audit-catalog",
                    str(FIXTURE_DIR / "audit-corpus.external-claim.json"),
                    "--audit-source-root",
                    raw_dir,
                    "--require-source-artifacts",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn('"source_artifacts_missing": 12', result.stdout)

    def test_orient_cli_can_fail_on_open_consistency_finding(self) -> None:
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        consistency_findings = catalog["consistency_findings"]
        assert isinstance(consistency_findings, list)
        first_finding = consistency_findings[0]
        assert isinstance(first_finding, dict)
        first_finding["status"] = "OPEN"

        with tempfile.TemporaryDirectory() as raw_dir:
            catalog_path = Path(raw_dir) / "catalog.json"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(ORIENT_SCRIPT_PATH),
                    str(FIXTURE_DIR / "observe.startup.json"),
                    "--audit-catalog",
                    str(catalog_path),
                    "--require-consistency-resolved",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn('"consistency_findings_open": 1', result.stdout)

    def test_orient_treats_malformed_consistency_finding_as_open(self) -> None:
        self.assertTrue(orient_goal_loop_logs.consistency_finding_is_open("bad"))

    def test_orient_cli_can_pass_when_consistency_finding_resolved(self) -> None:
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        consistency_findings = catalog["consistency_findings"]
        assert isinstance(consistency_findings, list)
        assert consistency_findings
        first_finding = consistency_findings[0]
        assert isinstance(first_finding, dict)
        first_finding["status"] = "RESOLVED"

        with tempfile.TemporaryDirectory() as raw_dir:
            catalog_path = Path(raw_dir) / "catalog.json"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(ORIENT_SCRIPT_PATH),
                    str(FIXTURE_DIR / "observe.startup.json"),
                    "--audit-catalog",
                    str(catalog_path),
                    "--require-consistency-resolved",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"consistency_findings_open": 0', result.stdout)

    def test_orient_cli_can_pass_with_external_source_root(self) -> None:
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        catalog = catalog_without_source_identity(catalog)
        external_sources = catalog["external_sources"]
        assert isinstance(external_sources, list)
        ids = catalog_finding_ids(catalog)

        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            catalog_path = root / "catalog.json"
            for source in external_sources:
                assert isinstance(source, dict)
                source_path = source["path"]
                assert isinstance(source_path, str)
                (root / Path(source_path).name).write_text(
                    source_text_with_optional_ids(source_path, ids),
                    encoding="utf-8",
                )
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(ORIENT_SCRIPT_PATH),
                    str(FIXTURE_DIR / "observe.startup.json"),
                    "--audit-catalog",
                    str(catalog_path),
                    "--audit-source-root",
                    str(root),
                    "--audit-source-strip-prefix",
                    "prompt_corpus/GOAL_LOOP",
                    "--require-source-artifacts",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"source_artifacts_resolved": 12', result.stdout)
        self.assertIn('"source_itemized_finding_ids_total": 19', result.stdout)
        self.assertIn('"source_structured_item_ids_total": 19', result.stdout)
        self.assertIn(
            '"source_structured_item_ids_uncataloged_occurrences": 0',
            result.stdout,
        )
        self.assertIn('"source_structured_item_id_families"', result.stdout)
        self.assertIn('"source_aggregate_claim_status": "COMPLETE"', result.stdout)
        self.assertIn('"source_aggregate_claim_sources_verified": 6', result.stdout)
        self.assertIn(
            '"source_aggregate_reconciliation_status": "COMPLETE"',
            result.stdout,
        )

    def test_orient_cli_can_pass_complete_catalog_with_strict_row_corpus(self) -> None:
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None

        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            catalog_path = root / "catalog.json"
            corpus_path = root / "strict-row-corpus.json"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            corpus_path.write_text(
                json.dumps(synthetic_strict_row_corpus()),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(ORIENT_SCRIPT_PATH),
                    str(FIXTURE_DIR / "observe.startup.json"),
                    "--audit-catalog",
                    str(catalog_path),
                    "--strict-row-corpus",
                    str(corpus_path),
                    "--require-complete-catalog",
                    "--format",
                    "text",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "audit_catalog: COMPLETE itemized=206 expected=206", result.stdout
        )
        self.assertIn(
            "strict_row_corpus: validated=True rows=206 errors=0", result.stdout
        )

    def test_validate_strict_row_corpus_cli_accepts_valid_corpus(self) -> None:
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None

        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            catalog_path = root / "catalog.json"
            corpus_path = root / "strict-row-corpus.json"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            corpus_path.write_text(
                json.dumps(synthetic_strict_row_corpus()),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(VALIDATE_STRICT_CORPUS_SCRIPT_PATH),
                    str(corpus_path),
                    "--audit-catalog",
                    str(catalog_path),
                    "--require-valid",
                    "--format",
                    "text",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "strict_row_corpus: VALID rows=206 expected=206 errors=0",
            result.stdout,
        )
        self.assertIn("path_policy_valid: True", result.stdout)

    def test_validate_strict_row_corpus_cli_prints_catalog_value_errors(
        self,
    ) -> None:
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        corpus = synthetic_strict_row_corpus()
        findings = corpus["findings"]
        assert isinstance(findings, list)
        unknown_source = findings[0]
        out_of_bounds_source = findings[1]
        assert isinstance(unknown_source, dict)
        assert isinstance(out_of_bounds_source, dict)
        unknown_source["source"] = {
            "path": "prompt_corpus/GOAL_LOOP/not-in-manifest.md",
            "line_refs": [1],
        }
        out_of_bounds_source["source"] = {
            "path": "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
            "line_refs": [607],
        }

        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            catalog_path = root / "catalog.json"
            corpus_path = root / "strict-row-corpus.json"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            corpus_path.write_text(json.dumps(corpus), encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(VALIDATE_STRICT_CORPUS_SCRIPT_PATH),
                    str(corpus_path),
                    "--audit-catalog",
                    str(catalog_path),
                    "--format",
                    "text",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("invalid_catalog_source_path_rows: ROW-001", result.stdout)
        self.assertIn(
            "path='prompt_corpus/GOAL_LOOP/not-in-manifest.md'", result.stdout
        )
        self.assertIn("invalid_catalog_line_ref_rows: ROW-002", result.stdout)
        self.assertIn("line_refs=[607] line_count=606", result.stdout)

    def test_validate_strict_row_corpus_cli_rejects_invalid_corpus(self) -> None:
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
        corpus = synthetic_strict_row_corpus(row_count=205)
        findings = corpus["findings"]
        assert isinstance(findings, list)
        first = findings[0]
        assert isinstance(first, dict)
        first["source"] = {
            "path": "C:\\Users\\example\\source.md",
            "line_refs": [1],
        }

        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            catalog_path = root / "catalog.json"
            corpus_path = root / "strict-row-corpus.json"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            corpus_path.write_text(json.dumps(corpus), encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(VALIDATE_STRICT_CORPUS_SCRIPT_PATH),
                    str(corpus_path),
                    "--audit-catalog",
                    str(catalog_path),
                    "--require-valid",
                    "--format",
                    "json",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertFalse(report["validated"])
        self.assertEqual(report["row_count"], 205)
        self.assertIn("findings_count_mismatch", report["errors"])
        self.assertIn("contains_user_local_path", report["errors"])
        self.assertIn(
            "source_paths_must_be_logical_prompt_corpus_paths", report["errors"]
        )

    def test_validate_strict_row_corpus_cli_rejects_source_row_inventory(
        self,
    ) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(VALIDATE_STRICT_CORPUS_SCRIPT_PATH),
                str(FIXTURE_DIR / "source-row-candidate-inventory.external-claim.json"),
                "--audit-catalog",
                str(FIXTURE_DIR / "audit-corpus.external-claim.json"),
                "--require-valid",
                "--format",
                "json",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertFalse(report["validated"])
        self.assertEqual(report["corpus_status"], "INCOMPLETE")
        self.assertEqual(report["row_count"], 0)
        self.assertTrue(report["looks_like_source_row_candidate_inventory"])
        self.assertIn(
            "source_row_candidate_inventory_is_not_strict_corpus",
            report["errors"],
        )
        self.assertIn("corpus_id_missing", report["errors"])
        self.assertIn("findings_must_be_list", report["errors"])
        self.assertIn("findings_count_mismatch", report["errors"])
        self.assertIn("status_must_be_COMPLETE", report["errors"])

    def test_decide_prioritizes_p0_actions_from_orient_json(self) -> None:
        report = decide_goal_loop_findings.decide_orient(
            {
                "findings": [
                    {"finding_id": "NF-1", "status": "EVIDENCE_PRESENT"},
                    {"finding_id": "NF-2", "status": "EVIDENCE_PRESENT"},
                    {"finding_id": "NF-6", "status": "EVIDENCE_PRESENT"},
                    {"finding_id": "NF-3", "status": "EVIDENCE_ABSENT"},
                ]
            }
        )

        decision_ids = [decision.decision_id for decision in report.decisions]
        self.assertEqual(report.p0_count, 2)
        self.assertEqual(report.decisions_total, 3)
        self.assertEqual(decision_ids[:2], ["D-EMERGENCY-2", "D-EMERGENCY-1"])
        self.assertIn("D-P2-1", decision_ids)

    def test_verify_fails_on_critical_evidence(self) -> None:
        report = verify_goal_loop_logs.verify_orient(
            {
                "findings": [
                    {
                        "finding_id": "NF-1",
                        "title": "provider_health_skipped_all_models",
                        "severity": "critical",
                        "status": "EVIDENCE_PRESENT",
                        "count": 1,
                    },
                    {
                        "finding_id": "NF-6",
                        "title": "config_unknown_keys_ignored",
                        "severity": "warning",
                        "status": "EVIDENCE_PRESENT",
                        "count": 1,
                    },
                ]
            },
            policy="critical",
        )

        self.assertEqual(report.status, "FAIL")
        self.assertEqual(len(report.failing_findings), 1)
        self.assertEqual(report.failing_findings[0].finding_id, "NF-1")

    def test_verify_passes_when_only_warning_and_policy_is_critical(self) -> None:
        report = verify_goal_loop_logs.verify_orient(
            {
                "findings": [
                    {
                        "finding_id": "NF-6",
                        "title": "config_unknown_keys_ignored",
                        "severity": "warning",
                        "status": "EVIDENCE_PRESENT",
                        "count": 1,
                    }
                ]
            },
            policy="critical",
        )

        self.assertEqual(report.status, "PASS")

    def test_verify_cli_emits_post_act_evidence_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "orient.json"
            path.write_text(json.dumps({"findings": []}), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(VERIFY_SCRIPT_PATH),
                    str(path),
                    "--post-act-verify",
                    "--evidence-kind",
                    "live_runtime_logs",
                    "--evidence-source",
                    "/tmp/goal-loop-post-act.log",
                    "--evidence-window-start",
                    "2026-05-05T17:29:12Z",
                    "--evidence-window-end",
                    "2026-05-06T00:00:00Z",
                    "--checked-at",
                    "2026-05-06T00:00:00Z",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["post_act_verify"])
        self.assertEqual(payload["evidence_kind"], "live_runtime_logs")
        self.assertEqual(payload["evidence_source"], "/tmp/goal-loop-post-act.log")
        self.assertEqual(payload["evidence_window_start"], "2026-05-05T17:29:12Z")
        self.assertEqual(payload["evidence_window_end"], "2026-05-06T00:00:00Z")
        self.assertEqual(payload["checked_at"], "2026-05-06T00:00:00Z")

    def test_log_contract_fails_on_forbidden_pattern(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "server.log"
            path.write_text(
                "\n".join(
                    [
                        "[INFO] provider_health_probe_completed provider=ollama",
                        "[WARN] [Keeper] alive-but-stuck detected",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            report = verify_goal_loop_logs.verify_log_contract(
                [str(path)],
                must_contain=["provider_health_probe_completed"],
                must_not_contain=["alive-but-stuck detected"],
                max_samples=2,
            )

        self.assertEqual(report.status, "FAIL")
        self.assertEqual(len(report.violations), 1)
        self.assertEqual(report.violations[0].kind, "forbidden_present")
        self.assertEqual(report.violations[0].count, 1)
        self.assertIn("alive-but-stuck", report.violations[0].samples[0].text)

    def test_log_contract_fails_when_required_pattern_missing(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "server.log"
            path.write_text(
                "[INFO] fallback_ladder_activated keeper=executor\n",
                encoding="utf-8",
            )

            report = verify_goal_loop_logs.verify_log_contract(
                [str(path)],
                must_contain=[
                    "fallback_ladder_activated",
                    "provider_health_probe_completed",
                ],
                must_not_contain=["pricing_catalog_miss"],
                max_samples=2,
            )

        self.assertEqual(report.status, "FAIL")
        self.assertEqual(len(report.violations), 1)
        self.assertEqual(report.violations[0].kind, "required_missing")
        self.assertEqual(
            report.violations[0].pattern, "provider_health_probe_completed"
        )

    def test_log_contract_cli_returns_json_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            path = Path(raw_dir) / "server.log"
            path.write_text(
                "[WARN] archived credential x (reason: starvation)\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(VERIFY_SCRIPT_PATH),
                    "--mode",
                    "log-contract",
                    "--log",
                    str(path),
                    "--must-not-contain",
                    "archived credential.*starvation",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn('"kind": "forbidden_present"', result.stdout)


if __name__ == "__main__":
    unittest.main()
