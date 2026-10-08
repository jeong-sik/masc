"""Captured fixture provenance must survive replay without relabeling."""
import gzip
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/capture-tui-ci-frames.py"
spec = importlib.util.spec_from_file_location("capture_frames", SCRIPT)
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CaptureOrigin(unittest.TestCase):
    def test_matching_recorded_origins(self):
        for label, origin in (("CI fixture PTY", "ci"), ("local fixture PTY", "local")):
            self.assertEqual(origin, capture.capture_origin(
                [{"provenance": label}], {"origin": origin}, origin))

    def test_flag_cannot_relabel_record(self):
        for label, requested in (("CI fixture PTY", "local"), ("local fixture PTY", "ci")):
            with self.assertRaises(ValueError):
                capture.capture_origin([{"provenance": label}], {}, requested)

    def test_missing_mixed_and_unknown_records_are_refused(self):
        for records in ([], [{}], [{"provenance": {}}], [{"provenance": "unknown"}],
                        [{"provenance": "CI fixture PTY"}, {"provenance": "local fixture PTY"}]):
            with self.assertRaises(ValueError):
                capture.capture_origin(records, {}, "ci")

    def test_run_metadata_cannot_contradict_record(self):
        for origin in ("local", "operator-authorized local PTY", "unknown", None):
            with self.assertRaises(ValueError):
                capture.capture_origin([{"provenance": "CI fixture PTY"}], {"origin": origin}, "ci")

    def test_archived_primary_list_conflict_is_rejected(self):
        evidence = ROOT / "docs/evidence/tui-reading-validation-20261008"
        frames = capture.captures(gzip.decompress((evidence / "logs/primary-lists.log.gz").read_bytes()).decode())
        run = json.loads((evidence / "screens-manifest.json").read_text())["run"]
        self.assertTrue(frames)
        with self.assertRaises(ValueError):
            capture.capture_origin(frames, run, "local")

    def test_cli_refuses_before_writing_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "log").write_text('STUDIO_CAPTURE={"provenance":"CI fixture PTY"}\n')
            (root / "run.json").write_text(json.dumps({"headSha": "fixture-head"}))
            result = subprocess.run([sys.executable, str(SCRIPT), "--log", str(root / "log"),
                "--run-info", str(root / "run.json"), "--expected-head", "fixture-head",
                "--out", str(root / "out"), "--origin", "local"], capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("capture origin rejected", result.stderr)
            self.assertFalse((root / "out").exists())


if __name__ == "__main__":
    unittest.main()
