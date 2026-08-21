import hashlib
import importlib.util
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


if __name__ == "__main__":
    unittest.main()
