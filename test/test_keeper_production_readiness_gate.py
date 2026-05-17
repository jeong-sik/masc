import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


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
    def test_default_base_path_uses_explicit_runtime_roots(self):
        with (
            tempfile.TemporaryDirectory() as masc_base,
            tempfile.TemporaryDirectory() as me_root,
        ):
            with patch.dict(
                os.environ,
                {"MASC_BASE_PATH": masc_base, "ME_ROOT": me_root},
                clear=True,
            ):
                self.assertEqual(gate.default_base_path(), masc_base)
            with patch.dict(os.environ, {"ME_ROOT": me_root}, clear=True):
                self.assertEqual(gate.default_base_path(), me_root)
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(gate.default_base_path(), str(Path.cwd()))

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
            max_turns_per_keeper=0,
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

    def test_shared_receipt_file_tools_match_selected_turn(self):
        with tempfile.TemporaryDirectory() as tmp_name:
            root = Path(tmp_name)
            keeper = "prod-readiness"
            trace = "trace-prod-readiness"
            gate.write_fixture_turn(root, keeper, trace, 1, tools=False)
            gate.write_fixture_turn(root, keeper, trace, 2, tools=True)

            receipt_dir = (
                root / ".masc" / "keepers" / keeper / "execution-receipts" / "2026-05"
            )
            shared_receipt = receipt_dir / "14.jsonl"
            receipt_rows = []
            for receipt_path in (receipt_dir / "01.jsonl", receipt_dir / "02.jsonl"):
                receipt_rows.extend(
                    json.loads(line)
                    for line in receipt_path.read_text(encoding="utf-8").splitlines()
                    if line.strip()
                )
            gate.write_jsonl(shared_receipt, receipt_rows)

            manifest = (
                root
                / ".masc"
                / "keepers"
                / keeper
                / "runtime-manifests"
                / f"{trace}.jsonl"
            )
            manifest_rows = [
                json.loads(line)
                for line in manifest.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            for row in manifest_rows:
                links = row.get("links")
                if isinstance(links, dict) and links.get("receipt_path"):
                    links["receipt_path"] = str(shared_receipt)
            manifest.write_text(
                "".join(
                    json.dumps(row, sort_keys=True) + "\n" for row in manifest_rows
                ),
                encoding="utf-8",
            )

            summary = gate.evaluate(
                base_path=root,
                keepers=[keeper],
                trace_ids=[trace],
                max_traces_per_keeper=5,
                max_turns_per_keeper=0,
                thresholds=gate.Thresholds(
                    min_terminal_turns=2,
                    min_success_turns=2,
                    min_terminal_turns_per_keeper=2,
                    min_success_turns_per_keeper=2,
                    min_provider_turns_per_keeper=2,
                    min_success_provider_turns_per_keeper=2,
                ),
            )

            self.assertEqual(summary.status, "PASS", summary.failures)
            self.assertEqual(summary.metrics["tool_used_turns"], 1)
            self.assertEqual(summary.metrics["tool_log_ok_turns"], 1)

    def test_missing_checkpoint_fails_zero_missing_artifact_gate(self):
        tmp, root, keeper, trace = self.make_fixture()
        with tmp:
            checkpoint = (
                root / ".masc" / "keepers" / keeper / "checkpoints" / "turn-1.json"
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

    def test_missing_provider_attempt_rows_fail_closure_gate(self):
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
            rows = [
                json.loads(line)
                for line in manifest.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            rows = [
                row
                for row in rows
                if not (
                    row.get("keeper_turn_id") == 1
                    and row.get("event")
                    in {"provider_attempt_started", "provider_attempt_finished"}
                )
            ]
            manifest.write_text(
                "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
                encoding="utf-8",
            )

            summary = self.evaluate(root, keeper, trace)

            self.assertEqual(summary.status, "FAIL")
            self.assertLess(summary.derived["provider_closure_pct"], 100.0)
            self.assertTrue(
                any("provider_closure_pct" in failure for failure in summary.failures)
            )

    def test_missing_timestamp_fails_coverage_gate(self):
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
            rows = [
                json.loads(line)
                for line in manifest.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            rows[0].pop("ts", None)
            manifest.write_text(
                "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
                encoding="utf-8",
            )

            summary = self.evaluate(root, keeper, trace)

            self.assertEqual(summary.status, "FAIL")
            self.assertLess(summary.derived["timestamp_coverage_pct"], 100.0)
            self.assertTrue(
                any("timestamp_coverage_pct" in failure for failure in summary.failures)
            )


if __name__ == "__main__":
    unittest.main()
