import hashlib
import importlib.util
import inspect
import json
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT
    / "scripts"
    / "harness"
    / "workload"
    / "keeper_multi_collaboration_acceptance.py"
)
CATALOG_PATH = (
    REPO_ROOT
    / "scripts"
    / "fixtures"
    / "keeper-multi-collaboration"
    / "missions.json"
)


def load_acceptance_module():
    spec = importlib.util.spec_from_file_location(
        "keeper_multi_collaboration_acceptance",
        SCRIPT_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


acceptance = load_acceptance_module()


class KeeperMultiCollaborationAcceptanceTest(unittest.TestCase):
    def test_runtime_by_role_requires_exact_five_role_object(self):
        mapping = {
            "coordinator": "runtime-a",
            "builder-a": "runtime-b",
            "builder-b": "runtime-c",
            "reviewer": "runtime-d",
            "researcher": "runtime-e",
        }

        parsed = acceptance.parse_runtime_by_role(json.dumps(mapping))

        self.assertEqual(parsed, mapping)
        with self.assertRaisesRegex(acceptance.AcceptanceError, "exact five roles"):
            acceptance.parse_runtime_by_role(
                json.dumps({"coordinator": "runtime-a"})
            )

    def test_heterogeneous_runtime_mode_refuses_duplicates_and_fallback_mix(self):
        mapping = {
            "coordinator": "runtime-a",
            "builder-a": "runtime-b",
            "builder-b": "runtime-c",
            "reviewer": "runtime-d",
            "researcher": "runtime-e",
        }
        acceptance.validate_runtime_strategy(
            runtime_id=None,
            runtime_by_role=mapping,
            require_heterogeneous=True,
        )
        duplicate = dict(mapping)
        duplicate["researcher"] = "runtime-a"
        with self.assertRaisesRegex(acceptance.AcceptanceError, "five distinct"):
            acceptance.validate_runtime_strategy(
                runtime_id=None,
                runtime_by_role=duplicate,
                require_heterogeneous=True,
            )
        with self.assertRaisesRegex(acceptance.AcceptanceError, "mutually exclusive"):
            acceptance.validate_runtime_strategy(
                runtime_id="fallback",
                runtime_by_role=mapping,
                require_heterogeneous=False,
            )

    def test_runtime_strategy_receipt_is_exact_and_fail_closed(self):
        mapping = {
            "coordinator": "runtime-a",
            "builder-a": "runtime-b",
            "builder-b": "runtime-c",
            "reviewer": "runtime-d",
            "researcher": "runtime-e",
        }
        receipt = acceptance.runtime_strategy_receipt(
            runtime_id=None,
            runtime_by_role=mapping,
            require_heterogeneous=True,
        )
        self.assertEqual(receipt["runtime_strategy"], "heterogeneous_required")
        self.assertEqual(receipt["runtime_by_role"], mapping)
        self.assertEqual(receipt["distinct_runtime_count"], 5)

        with self.assertRaisesRegex(
            acceptance.AcceptanceError, "exact runtime selection"
        ):
            acceptance.runtime_strategy_receipt(
                runtime_id=None,
                runtime_by_role={},
                require_heterogeneous=False,
            )

    def test_catalog_has_exact_rw19_persistence_projection_mission(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        self.assertEqual(len(catalog["missions"]), 23)
        self.assertEqual(
            len(
                {
                    assertion
                    for mission in catalog["missions"]
                    for assertion in mission["assertions"]
                }
            ),
            48,
        )
        self.assertEqual(catalog["missions"][18]["id"], "RW19")
        self.assertEqual(
            catalog["missions"][18]["assertions"],
            ["persistence_tiers_dashboard_projection_observed"],
        )

    def test_catalog_has_exact_rw20_rw21_delivery_and_debate_missions(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        poc = catalog["missions"][19]
        self.assertEqual(poc["id"], "RW20")
        self.assertEqual(
            poc["assertions"],
            ["poc_execution_proof_observed", "poc_review_cites_execution"],
        )
        debate = catalog["missions"][20]
        self.assertEqual(debate["id"], "RW21")
        self.assertEqual(
            debate["assertions"],
            ["debate_restatement_faithful", "debate_verdict_cites_rebuttal"],
        )
        self.assertIn("tool_execute", catalog["keeper_required_tools"])

    def test_catalog_has_exact_rw22_coverage_mission(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        coverage = catalog["missions"][21]
        self.assertEqual(coverage["id"], "RW22")
        self.assertEqual(
            coverage["assertions"],
            [
                "qa_coverage_execution_observed",
                "qa_coverage_passes_verification",
                "qa_coverage_review_matches_spec",
            ],
        )
        # The row exists to reject partial runs, so the tester must be able to
        # execute rather than only claim, and the work has to enter the typed
        # verification flow and actually pass it — submitting is not completing.
        self.assertIn("tool_execute", catalog["keeper_required_tools"])
        self.assertIn("keeper_task_claim", catalog["keeper_required_tools"])
        self.assertIn("keeper_task_done", catalog["keeper_required_tools"])

    def test_catalog_has_exact_rw23_goal_verifier_mission(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        goal_verifier = catalog["missions"][22]
        self.assertEqual(goal_verifier["id"], "RW23")
        self.assertEqual(
            goal_verifier["assertions"],
            [
                "goal_verifier_refutation_observed",
                "goal_verifier_reentry_proven",
                "goal_verifier_dashboard_browser_observed",
            ],
        )
        self.assertIn("Goal", goal_verifier["capabilities"])
        self.assertIn("Browser", goal_verifier["capabilities"])
        self.assertIn("masc_goal_transition", catalog["operator_required_tools"])
        self.assertTrue(catalog["approaches_apply_to_each_mission"])
        self.assertEqual(
            [approach["id"] for approach in catalog["execution_approaches"]],
            ["A", "B", "C"],
        )

    def test_runtime_serving_evidence_requires_exact_completed_receipt_per_role(self):
        keepers = {"coordinator": "keeper-c", "reviewer": "keeper-r"}
        expected = {"coordinator": "runtime-c", "reviewer": "runtime-r"}
        with tempfile.TemporaryDirectory() as tmp_name:
            base_path = Path(tmp_name)
            cursors = acceptance.capture_runtime_manifest_line_cursors(
                base_path=base_path, keepers_by_role=keepers
            )
            self.write_runtime_receipts(
                base_path,
                "keeper-c",
                [
                    self.runtime_receipt(
                        "runtime-c", keeper_name="keeper-c", fallback=False
                    )
                ],
            )
            self.write_runtime_receipts(
                base_path,
                "keeper-r",
                [
                    self.runtime_receipt(
                        "runtime-fallback", keeper_name="keeper-r", fallback=True
                    )
                ],
            )

            failed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )
            self.assertEqual(failed["status"], "failed")
            self.assertEqual(failed["served_role_count"], 1)
            self.assertEqual(
                failed["roles"]["reviewer"]["fallback_receipt_count"], 1
            )

            self.write_runtime_receipts(
                base_path,
                "keeper-r",
                [
                    self.runtime_receipt(
                        "runtime-fallback", keeper_name="keeper-r", fallback=True
                    ),
                    self.runtime_receipt(
                        "runtime-r", keeper_name="keeper-r", fallback=False
                    ),
                ],
            )
            passed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )
            self.assertEqual(passed["status"], "passed")
            self.assertEqual(passed["served_role_count"], 2)
            self.assertEqual(passed["distinct_served_runtime_count"], 2)

    def test_campaign_identity_slug_keeps_seconds_in_identity(self):
        first = acceptance.campaign_identity_slug("rw-20260821-090001", 16)
        second = acceptance.campaign_identity_slug("rw-20260821-090059", 16)

        self.assertNotEqual(first, second)
        self.assertLessEqual(len(first), 16)
        self.assertLessEqual(len(second), 16)

    def test_runtime_serving_evidence_rejects_stale_exact_receipt(self):
        keepers = {"coordinator": "keeper-c"}
        expected = {"coordinator": "runtime-c"}
        with tempfile.TemporaryDirectory() as tmp_name:
            base_path = Path(tmp_name)
            self.write_runtime_receipts(
                base_path,
                "keeper-c",
                [
                    self.runtime_receipt(
                        "runtime-c", keeper_name="keeper-c", fallback=False
                    )
                ],
            )
            cursors = acceptance.capture_runtime_manifest_line_cursors(
                base_path=base_path, keepers_by_role=keepers
            )
            self.append_runtime_receipts(
                base_path,
                "keeper-c",
                [
                    self.runtime_receipt(
                        "runtime-fallback", keeper_name="keeper-c", fallback=True
                    )
                ],
            )

            failed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )

            self.assertEqual(failed["status"], "failed")
            role = failed["roles"]["coordinator"]
            self.assertEqual(role["baseline_manifest_line_count"], 1)
            self.assertEqual(role["current_run_receipt_row_count"], 1)
            self.assertEqual(role["exact_success_count"], 0)
            self.assertEqual(role["fallback_receipt_count"], 1)

    def test_runtime_serving_evidence_rejects_malformed_receipt_identity(self):
        keepers = {"coordinator": "keeper-c"}
        expected = {"coordinator": "runtime-c"}
        with tempfile.TemporaryDirectory() as tmp_name:
            base_path = Path(tmp_name)
            cursors = acceptance.capture_runtime_manifest_line_cursors(
                base_path=base_path, keepers_by_role=keepers
            )
            malformed = self.runtime_receipt(
                "runtime-c", keeper_name="wrong-keeper", fallback=False
            )
            malformed["runtime_id"] = "different-top-level-runtime"
            self.write_runtime_receipts(base_path, "keeper-c", [malformed])

            failed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )

            self.assertEqual(failed["status"], "failed")
            self.assertEqual(
                failed["roles"]["coordinator"]["exact_success_count"], 0
            )
            self.assertTrue(
                any("keeper_name mismatch" in error for error in failed["parse_errors"])
            )
            self.assertTrue(
                any(
                    "top-level runtime_id does not match decision" in error
                    for error in failed["parse_errors"]
                )
            )

    def test_rw23_task_is_not_exposed_to_autonomous_work_before_refutation(self):
        setup_source = inspect.getsource(acceptance.MissionRun.setup_product_state)
        rw23_source = inspect.getsource(
            acceptance.MissionRun.run_goal_verifier_refute_reenter_prove
        )

        # The success-token Task and Goal assignment both used to be visible
        # during fleet setup. A capable coordinator completed them autonomously
        # before RW23 could write the failing artifact. Keep both inside the
        # directed RW23 phase and the verifier Goal out of ordinary fleet scope.
        self.assertNotIn("goal-verifier-task-create", setup_source)
        self.assertNotIn("goal-verifier-assign", setup_source)
        self.assertIn("goal-verifier-task-create", rw23_source)
        self.assertIn("goal-verifier-assign", rw23_source)
        self.assertLess(
            rw23_source.index("goal-verifier-task-create"),
            rw23_source.index("goal-verifier-refute-artifact"),
        )
        self.assertLess(
            rw23_source.index('wait_for_verifier_task_verdict("in_progress")'),
            rw23_source.index("goal-verifier-assign"),
        )

    def test_rw23_uses_durable_verdict_without_parsing_board_text(self):
        rw23_source = inspect.getsource(
            acceptance.MissionRun.run_goal_verifier_refute_reenter_prove
        )

        # masc_tasks is a human-facing Board rendering in the live server. The
        # verifier history event is the typed durable authority for both the
        # rejected and approved transitions.
        self.assertNotIn("wait_for_verifier_task_status", rw23_source)
        self.assertEqual(rw23_source.count("wait_for_verifier_task_verdict"), 2)
        self.assertIn('wait_for_verifier_task_verdict("in_progress")', rw23_source)
        self.assertIn('wait_for_verifier_task_verdict("done")', rw23_source)

    def test_persistence_browser_validator_requires_exact_monotonic_fleet(self):
        expected = {"keeper-a", "keeper-b"}
        with tempfile.TemporaryDirectory() as tmp_name:
            screenshot = Path(tmp_name) / "keeper-persistence-proof.png"
            screenshot.write_bytes(b"png-evidence")
            digest = hashlib.sha256(screenshot.read_bytes()).hexdigest()
            proof = {
                "schema": "masc.keeper_persistence_browser_evidence.v1",
                "generated_at": "2026-08-14T12:00:00Z",
                "interaction": "manual_refresh",
                "tiers": [
                    self.tier("1h", ["keeper-a", "keeper-b"], []),
                    self.tier("2h", ["keeper-a"], ["keeper-b"]),
                    self.tier("4h", ["keeper-a"], ["keeper-b"]),
                    self.tier("24h", [], ["keeper-a", "keeper-b"]),
                ],
                "screenshot_file": screenshot.name,
                "screenshot_bytes": screenshot.stat().st_size,
                "screenshot_sha256": digest,
            }

            valid, detail = acceptance.validate_persistence_browser_evidence(
                proof,
                screenshot,
                expected,
            )
            self.assertTrue(valid, detail)

            proof["tiers"][2] = self.tier(
                "4h",
                ["keeper-b"],
                ["keeper-a"],
            )
            valid, detail = acceptance.validate_persistence_browser_evidence(
                proof,
                screenshot,
                expected,
            )
            self.assertFalse(valid)
            self.assertIn("duration monotonicity", detail)

    @staticmethod
    def tier(tier_id, observed, missing):
        keeper_count = len(observed) + len(missing)
        observed_count = len(observed)
        status = (
            "fail"
            if keeper_count == 0 or observed_count == 0
            else "pass"
            if observed_count == keeper_count
            else "warn"
        )
        return {
            "id": tier_id,
            "status": status,
            "evidence_kind": "durable_turn_span",
            "keeper_count": keeper_count,
            "observed_count": observed_count,
            "missing_count": len(missing),
            "observed_keepers": observed,
            "missing_keepers": missing,
        }

    @staticmethod
    def runtime_receipt(runtime_id, *, keeper_name, fallback):
        return {
            "schema_version": 1,
            "ts": "2026-08-21T09:00:00Z",
            "keeper_name": keeper_name,
            "trace_id": f"trace-{runtime_id}",
            "keeper_turn_id": 1,
            "event": "receipt_appended",
            "runtime_id": runtime_id,
            "status": "ok",
            "decision": {
                "outcome": "ok",
                "runtime_id": runtime_id,
                "runtime_attempt_count": 1,
                "runtime_fallback_applied": fallback,
                "runtime_outcome": "completed",
            },
        }

    @staticmethod
    def write_runtime_receipts(base_path, keeper, rows):
        manifest_root = (
            base_path / ".masc" / "keepers" / keeper / "runtime-manifests"
        )
        manifest_root.mkdir(parents=True, exist_ok=True)
        (manifest_root / "trace.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in rows),
            encoding="utf-8",
        )

    @staticmethod
    def append_runtime_receipts(base_path, keeper, rows):
        manifest_path = (
            base_path
            / ".masc"
            / "keepers"
            / keeper
            / "runtime-manifests"
            / "trace.jsonl"
        )
        with manifest_path.open("a", encoding="utf-8") as handle:
            handle.write("".join(json.dumps(row) + "\n" for row in rows))


if __name__ == "__main__":
    unittest.main()
