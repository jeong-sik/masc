import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "keeper-production-readiness-gate.py"
)


def load_gate_module():
    spec = importlib.util.spec_from_file_location(
        "keeper_production_readiness_gate", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


gate = load_gate_module()


class KeeperProductionReadinessGateTest(unittest.TestCase):
    def make_fixture(self):
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        keeper = "prod-readiness"
        trace = "trace-prod-readiness"
        for turn in range(1, 4):
            gate.write_fixture_turn(root, keeper, trace, turn, tools=(turn == 2))
        return tmp, root, keeper, trace

    def evaluate(self, root: Path, keeper: str, trace: str):
        return gate.evaluate(
            base_path=root,
            keepers=[keeper],
            trace_ids=[trace],
            max_traces_per_keeper=5,
            thresholds=gate.Thresholds(),
        )

    def test_default_fixture_passes_quantitative_gate(self):
        with self.make_fixture()[0] as tmp_name:
            root = Path(tmp_name)
            keeper = "prod-readiness"
            trace = "trace-prod-readiness"

            summary = self.evaluate(root, keeper, trace)

            self.assertEqual(summary.status, "PASS")
            self.assertEqual(summary.metrics["terminal_turns"], 3)
            self.assertEqual(summary.derived["receipt_coverage_pct"], 100.0)
            self.assertEqual(summary.derived["checkpoint_coverage_pct"], 100.0)
            self.assertEqual(summary.derived["tool_log_coverage_pct"], 100.0)

    def test_missing_checkpoint_fails_zero_missing_artifact_gate(self):
        tmp, root, keeper, trace = self.make_fixture()
        with tmp:
            checkpoint = (
                root
                / ".masc"
                / "keepers"
                / keeper
                / "checkpoints"
                / "turn-1.json"
            )
            checkpoint.unlink()

            summary = self.evaluate(root, keeper, trace)

            self.assertEqual(summary.status, "FAIL")
            self.assertTrue(
                any("missing_artifacts" in failure for failure in summary.failures)
            )

    def test_timestamp_order_violation_fails(self):
        tmp, root, keeper, trace = self.make_fixture()
        with tmp:
            manifest = (
                root
                / ".masc"
                / "keepers"
                / keeper
                / "runtime-manifests"
                / f"{trace}.jsonl"
            )
            text = manifest.read_text(encoding="utf-8")
            text = text.replace(
                '"ts": "2026-05-13T00:01:07Z"',
                '"ts": "2026-05-13T00:01:59Z"',
                1,
            )
            manifest.write_text(text, encoding="utf-8")

            summary = self.evaluate(root, keeper, trace)

            self.assertEqual(summary.status, "FAIL")
            self.assertTrue(
                any("order_violations" in failure for failure in summary.failures)
            )


if __name__ == "__main__":
    unittest.main()
