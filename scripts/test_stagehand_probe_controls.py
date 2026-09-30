"""Exercise public failure receipts with a fake executable; no model calls."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("controls", Path(__file__).with_name("stagehand-probe-controls.py"))
controls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controls)


REASONS = ["registry_publication_rejected", "fixtures_required"]


class ControlReceipts(unittest.TestCase):
    def run_fake(self, result=None, code=2, reasons=REASONS):
        """A fake probe: every control passes except configuration_publication,
        which writes [result] (a dict, a raw string, or nothing) and exits [code]."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "probe"
            binary.write_text(
                "#!/usr/bin/env python3\nimport json, sys\n"
                "print('PRIVATE_CONFIG_CANARY', file=sys.stderr)\n"
                "print('PRIVATE_CONFIG_CANARY stdout')\n"
                f"if '--list-setup-reasons' in sys.argv:\n print(json.dumps({reasons!r}))\n sys.exit(0)\n"
                "path = sys.argv[sys.argv.index('--control-result') + 1]\n"
                "if '--self-test' in sys.argv:\n"
                " open(path, 'x').write(json.dumps({'outcome': 'passed'}))\n sys.exit(0)\n"
                + (f"open(path, 'x').write({result!r} if isinstance({result!r}, str) else json.dumps({result!r}))\n"
                   if result is not None else "")
                + f"sys.exit({code})\n")
            binary.chmod(0o700)
            receipt = root / "receipt.json"
            console = io.StringIO()
            with contextlib.redirect_stdout(console):
                exit_code = controls.run_controls(binary, root / "fixtures", root / "config", receipt)
            text = receipt.read_text() + console.getvalue()
            self.assertNotIn("PRIVATE_CONFIG_CANARY", text)
            return exit_code, json.loads(receipt.read_text()), text

    def test_pass_records_both_controls(self):
        code, receipt, _ = self.run_fake({"outcome": "passed"}, code=0)
        self.assertEqual(code, 0)
        self.assertEqual([row["status"] for row in receipt["controls"]], ["passed", "passed"])
        self.assertEqual(receipt["provider_execution"], "not_run_in_ci")

    def test_listed_setup_reason_is_retained_and_fails_gate(self):
        code, receipt, _ = self.run_fake(
            {"outcome": "setup_refused", "reason": "registry_publication_rejected"})
        self.assertEqual(code, 1)
        self.assertEqual(receipt["controls"][1], {
            "name": "configuration_publication", "status": "failed", "exit_code": 2,
            "category": "registry_publication_rejected"})

    def test_unlisted_reason_is_not_published(self):
        code, receipt, text = self.run_fake(
            {"outcome": "setup_refused", "reason": "PRIVATE secret=not-for-publication"})
        self.assertEqual(code, 1)
        self.assertEqual(receipt["controls"][1]["category"], "control_result_invalid")
        self.assertNotIn("not-for-publication", text)

    def test_outcome_must_match_exit_status(self):
        _, receipt, _ = self.run_fake(
            {"outcome": "setup_refused", "reason": "registry_publication_rejected"}, code=1)
        self.assertEqual(receipt["controls"][1]["category"], "control_result_contradicts_exit")
        _, receipt, _ = self.run_fake({"outcome": "passed"}, code=2)
        self.assertEqual(receipt["controls"][1]["category"], "control_result_contradicts_exit")

    def test_internal_error_is_its_own_category(self):
        _, receipt, _ = self.run_fake({"outcome": "internal_error"}, code=3)
        self.assertEqual((receipt["controls"][1]["status"], receipt["controls"][1]["category"]),
                         ("failed", "internal_error"))

    def test_missing_or_malformed_result_fails(self):
        _, receipt, _ = self.run_fake(None, code=2)
        self.assertEqual(receipt["controls"][1]["category"], "control_result_missing")
        _, receipt, _ = self.run_fake("not json", code=2)
        self.assertEqual(receipt["controls"][1]["category"], "control_result_missing")
        _, receipt, _ = self.run_fake({"outcome": "unheard_of"}, code=2)
        self.assertEqual(receipt["controls"][1]["category"], "control_result_invalid")

    def test_reason_needs_the_probe_list(self):
        _, receipt, _ = self.run_fake(
            {"outcome": "setup_refused", "reason": "registry_publication_rejected"}, reasons="nope")
        self.assertEqual(receipt["controls"][1]["category"], "setup_reasons_unavailable")

    def test_failed_receipt_is_packaged_without_claiming_pass(self):
        _, receipt, _ = self.run_fake(
            {"outcome": "setup_refused", "reason": "registry_publication_rejected"})
        manifest_spec = importlib.util.spec_from_file_location(
            "manifest", Path(__file__).with_name("stagehand-probe-manifest.py"))
        manifest = importlib.util.module_from_spec(manifest_spec)
        manifest_spec.loader.exec_module(manifest)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["stagehand_model_probe.exe", "llm-generate-params.json", "README.md",
                         "native-dependencies.txt", "runtime-publication.toml"]:
                (root / name).write_text("synthetic fixture")
            (root / "offline-controls.json").write_text(json.dumps(receipt))
            manifest.write_manifest(root, "a" * 40)
            published = json.loads((root / "manifest.json").read_text())
            self.assertEqual(published["offline_controls"], receipt["controls"])
            self.assertEqual(published["provider_execution"], "not_run_in_ci")
            self.assertIn("offline-controls.json", published["sha256"])


if __name__ == "__main__":
    unittest.main()
