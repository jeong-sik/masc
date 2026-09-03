"""What the frame-latency harness may call a measurement.

A run of the harness competes with everything else on the machine. If the
process is not scheduled, keypresses answer late while the TUI's own frame
clock stays small, and reading that as slow code sends the next change after
the wrong thing. If the chat never loaded, no frame had anything to draw and
the run is fast for the same wrong reason. The verdict names both cases so a
number that came out of one is not compared against a number that did not.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "tui-frame-latency.py"

SLOW_BUILD = "build frames=900 mean=64.00ms p50=64.00 p95=133.00 p99=167.00 max=653.00\n"
FAST_BUILD = "build frames=900 mean=1.00ms p50=0.60 p95=2.00 p99=4.00 max=13.00\n"


def load_harness():
    spec = importlib.util.spec_from_file_location("tui_frame_latency", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


harness = load_harness()


class MeasuredSession:
    """A session that reports the numbers a test chose, with no terminal."""

    def __init__(self, measurement: dict[str, float]) -> None:
        self.measurement = measurement

    def measure(self, _phase: object) -> dict[str, float]:
        return self.measurement


def judge(
    frames: int, latency_p50: float, timing: str, drew_empty_chat: bool = False
) -> tuple[str, str]:
    phase = harness.Phase("scenario", 0.0, 1.0)
    session = MeasuredSession({"frames": frames, "p50": latency_p50})
    return harness.judge([phase], session, timing, drew_empty_chat=drew_empty_chat)


class FrameLatencyVerdictTest(unittest.TestCase):
    def test_slow_frames_are_the_program_not_the_machine(self):
        # 64 ms to build, and a keypress waits for the frame in flight and its
        # own: half a second is what that costs, and it is the code's to fix.
        verdict, why = judge(frames=400, latency_p50=500.0, timing=SLOW_BUILD)
        self.assertEqual(verdict, "OK")
        self.assertIn("64.0 ms", why)

    def test_late_keypresses_with_quick_frames_are_starvation(self):
        verdict, why = judge(frames=400, latency_p50=500.0, timing=FAST_BUILD)
        self.assertEqual(verdict, "STARVED")
        self.assertIn("waiting for the machine", why)

    def test_slow_frames_can_also_be_starved(self):
        verdict, _ = judge(frames=400, latency_p50=2000.0, timing=SLOW_BUILD)
        self.assertEqual(verdict, "STARVED")

    def test_a_surface_that_drew_nothing_is_not_a_fast_surface(self):
        verdict, why = judge(frames=5, latency_p50=900.0, timing=FAST_BUILD)
        self.assertEqual(verdict, "EMPTY")
        self.assertIn("nothing to move", why)

    def test_a_chat_that_never_loaded_is_not_a_fast_chat(self):
        # The pane redrew a thousand times and every frame was quick, because
        # the transcript was not there to draw.
        verdict, why = judge(
            frames=900, latency_p50=1.0, timing=FAST_BUILD, drew_empty_chat=True
        )
        self.assertEqual(verdict, "EMPTY")
        self.assertIn("no-messages notice", why)

    def test_a_healthy_run_reports_both_clocks(self):
        verdict, why = judge(frames=400, latency_p50=40.0, timing=FAST_BUILD)
        self.assertEqual(verdict, "OK")
        self.assertIn("median keypress 40 ms", why)
        self.assertIn("median frame build 0.6 ms", why)

    def test_without_the_tui_clock_there_is_no_verdict(self):
        verdict, _ = judge(frames=400, latency_p50=40.0, timing="")
        self.assertEqual(verdict, "NO_TIMING")

    def test_the_build_percentile_is_read_from_the_report(self):
        self.assertAlmostEqual(harness.build_p50_ms(SLOW_BUILD), 64.0)
        self.assertIsNone(harness.build_p50_ms("present frames=1 mean=0.1ms p50=0.1\n"))


if __name__ == "__main__":
    unittest.main()
