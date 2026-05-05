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
SCRIPT_PATH = REPO_ROOT / "scripts" / "observe_goal_loop_logs.py"
ORIENT_SCRIPT_PATH = REPO_ROOT / "scripts" / "orient_goal_loop_logs.py"
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


def source_text_with_optional_ids(source_path: str, ids: list[str]) -> str:
    body = "source line\n" * 2000
    if Path(source_path).name == "GOAL_LOOP_INTEGRATION.md":
        body += "\n".join(ids) + "\n"
    return body


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
        self.assertEqual(report.audit_catalog["itemized_findings_total"], 18)
        self.assertEqual(report.audit_catalog["missing_itemized_findings"], 188)
        self.assertEqual(report.audit_catalog["source_documents_expected"], 12)
        self.assertEqual(report.audit_catalog["source_documents_covered"], 12)
        self.assertEqual(report.audit_catalog["source_documents_status"], "COMPLETE")
        self.assertEqual(report.audit_catalog["external_sources_total"], 12)
        self.assertEqual(len(report.audit_catalog["aggregate_claims"]), 3)
        self.assertEqual(len(report.audit_catalog["consistency_findings"]), 1)
        self.assertEqual(
            report.audit_catalog["consistency_findings"][0]["finding_id"],
            "CONSISTENCY-1",
        )
        self.assertEqual(report.summary["findings_total"], 18)
        self.assertEqual(report.summary["not_evaluated"], 8)
        self.assertEqual(by_id["NF-2"].status, "EVIDENCE_PRESENT")
        self.assertEqual(by_id["CD-8"].status, "NOT_EVALUATED")
        self.assertEqual(by_id["CD-8"].decision_id, "D-P1-1")

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
        self.assertEqual(source_artifacts["catalog_itemized_finding_ids_total"], 18)
        self.assertEqual(source_artifacts["catalog_ids_missing_from_source"], 18)
        self.assertIn(
            "prompt_corpus/GOAL_LOOP/GOAL_LOOP_INTEGRATION.md",
            source_artifacts["missing_paths"],
        )

    def test_orient_catalog_can_validate_external_source_root(self) -> None:
        scan = json_from_fixture("observe.startup.json")
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
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
        self.assertEqual(source_artifacts["source_itemized_finding_ids_total"], 18)
        self.assertEqual(source_artifacts["catalog_itemized_finding_ids_total"], 18)
        self.assertEqual(source_artifacts["source_ids_missing_from_catalog"], 0)
        self.assertEqual(source_artifacts["catalog_ids_missing_from_source"], 0)

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

    def test_orient_cli_can_pass_with_external_source_root(self) -> None:
        catalog = orient_goal_loop_logs.load_audit_catalog_input(
            str(FIXTURE_DIR / "audit-corpus.external-claim.json")
        )
        assert catalog is not None
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

            result = subprocess.run(
                [
                    sys.executable,
                    str(ORIENT_SCRIPT_PATH),
                    str(FIXTURE_DIR / "observe.startup.json"),
                    "--audit-catalog",
                    str(FIXTURE_DIR / "audit-corpus.external-claim.json"),
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
        self.assertIn('"source_itemized_finding_ids_total": 18', result.stdout)

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
