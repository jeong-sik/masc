"""Combined-dispatch frame ownership at the actual capture log boundary."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("capture", Path(__file__).resolve().parents[1] / "scripts/capture-tui-ci-frames.py")
assert spec is not None and spec.loader is not None
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CaptureOwnership(unittest.TestCase):
    def test_combined_dispatch_selects_only_explicit_owner(self):
        # Identical frame names deliberately cannot identify the producer.
        surface = {"suite": "test_tui_surface_studio_pty", "name": "workspace", "screen": "surface"}
        navigation = {"suite": "test_tui_lane_visual_pty", "name": "workspace", "screen": "navigation"}
        primary = {"suite": "test_tui_board_heading_width", "name": "workspace", "screen": "primary"}
        usage = {"suite": "test_tui_usage_studio_pty", "name": "workspace", "screen": "usage"}
        unscoped = {"name": "workspace", "screen": "manual"}
        def record(value):
            return "STUDIO_CAPTURE=" + json.dumps(value)
        log = "\n".join([record(surface),
            "tests\trun\t2026-10-01T00:00:00Z " + record(navigation),
            record(primary), record(usage), record(unscoped),
            "tests\trun\t2026-10-01T00:00:00Z echo '" + record(surface) + "'",
            "tui surface studio PTY: PASS", "TUI navigation consistency: PASS"])
        self.assertEqual([surface], capture.captures(log, "test_tui_surface_studio_pty"))
        self.assertEqual([navigation], capture.captures(log, "test_tui_lane_visual_pty"))
        self.assertEqual([primary], capture.captures(log, "test_tui_board_heading_width"))
        self.assertEqual([usage], capture.captures(log, "test_tui_usage_studio_pty"))
        self.assertEqual([], capture.captures(log, "different_suite"))
        self.assertEqual([surface, navigation, primary, usage, unscoped], capture.captures(log))

    def test_unscoped_manual_capture_remains_available_without_selector(self):
        frame = {"name": "manual-workspace", "screen": "a manually recorded frame"}
        log = "STUDIO_CAPTURE=" + json.dumps(frame)
        self.assertEqual([frame], capture.captures(log))
        self.assertEqual([], capture.captures(log, "test_tui_surface_studio_pty"))


if __name__ == "__main__":
    unittest.main()
