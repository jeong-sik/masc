import hashlib
import importlib.util
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
    def test_catalog_has_exact_rw19_persistence_projection_mission(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        self.assertEqual(len(catalog["missions"]), 21)
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
