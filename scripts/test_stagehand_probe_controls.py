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


class ControlReceipts(unittest.TestCase):
    def run_fake(self, failure=None, code=2):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "probe"
            binary.write_text("#!/usr/bin/env python3\nimport sys\n"
                              "print('PRIVATE_CONFIG_CANARY', file=sys.stderr)\n"
                              "if '--self-test' in sys.argv:\n print('fixture validators: passed')\n"
                              "else:\n"
                              + (f" print({failure!r}, file=sys.stderr)\n sys.exit({code})\n" if failure else
                                 " print('runtime configuration and Exact lane publication: passed (no model callbacks)')\n"))
            binary.chmod(0o700)
            receipt = root / "receipt.json"
            console = io.StringIO()
            with contextlib.redirect_stdout(console):
                result = controls.run_controls(binary, root / "fixtures", root / "config", receipt)
            text = receipt.read_text() + console.getvalue()
            self.assertNotIn("PRIVATE_CONFIG_CANARY", text)
            return result, json.loads(receipt.read_text()), text

    def test_pass_records_both_controls(self):
        code, receipt, _ = self.run_fake()
        self.assertEqual(code, 0)
        self.assertEqual([row["status"] for row in receipt["controls"]], ["passed", "passed"])
        self.assertEqual(receipt["provider_execution"], "not_run_in_ci")

    def test_known_setup_failure_is_retained_and_fails_gate(self):
        code, receipt, _ = self.run_fake("registry_publication_rejected")
        self.assertEqual(code, 1)
        self.assertEqual(receipt["controls"][1], {
            "name": "configuration_publication", "status": "failed", "exit_code": 2,
            "category": "registry_publication_rejected"})

    def test_raw_failure_is_not_published(self):
        code, receipt, text = self.run_fake("PRIVATE_CONFIG_CANARY: secret=not-for-publication")
        self.assertEqual(code, 1)
        self.assertEqual(receipt["controls"][1]["category"], "unclassified_control_failure")
        self.assertNotIn("not-for-publication", text)

    def test_only_setup_exit_accepts_category(self):
        _, receipt, _ = self.run_fake("registry_publication_rejected", code=1)
        self.assertEqual(receipt["controls"][1]["category"], "unclassified_control_failure")

    def test_failed_receipt_is_packaged_without_claiming_pass(self):
        _, receipt, _ = self.run_fake("registry_publication_rejected")
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
