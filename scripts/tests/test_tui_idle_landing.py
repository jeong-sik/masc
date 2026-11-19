# pyright: strict
"""Where idle.py's keys left the TUI: the surface on screen when the window
starts, read from the frame report, and keys that stop at the first failure.

    python3 -m unittest scripts.tests.test_tui_idle_landing

No TUI, relay or MASC server runs here.
"""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'harness' / 'tui'))
import idle  # noqa: E402
from pty_driver import Child, Jump, Key, Press, Sent  # noqa: E402
from vte import Vte  # noqa: E402

WINDOW = (5_000, 9_000)  # nanoseconds since the TUI started


def frame(phase: str, ordinal: int, surface: str, started_ns: int) -> str:
    return json.dumps({'schema': idle.FRAME_SCHEMA, 'phase': phase, 'frame': ordinal, 'surface': surface,
                       'started_ns': str(started_ns), 'elapsed_ns': '100'})


class SurfaceAtStartTest(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.report = Path(scratch.name) / 'screen.frame-timing.txt'

    def surface_at_start(self, lines: list[str]) -> str | None:
        self.report.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        frames = idle.frames_in(self.report, *WINDOW)
        assert not isinstance(frames, str), frames
        return frames.surface_at_start

    def test_the_last_present_before_the_window_names_the_screen(self) -> None:
        # The jump: overview, then the palette, then the destination; the
        # present at 4_000 wrote nothing new and still names the surface.
        self.assertEqual(self.surface_at_start([
            frame('build', 1, 'overview', 1_000), frame('present', 1, 'overview', 1_100),
            frame('present', 2, 'palette', 2_000), frame('build', 3, 'approvals', 3_000),
            frame('present', 3, 'approvals', 3_100), frame('present', 4, 'approvals', 4_000),
            frame('present', 5, 'approval-detail', 6_000)]), 'approvals')

    def test_a_build_alone_does_not_name_the_screen(self) -> None:
        # A frame built but not presented before the window never reached the terminal.
        self.assertEqual(self.surface_at_start([
            frame('present', 1, 'overview', 1_000), frame('build', 2, 'keeper-detail', 4_500)]), 'overview')

    def test_no_present_before_the_window_says_nothing(self) -> None:
        self.assertIsNone(self.surface_at_start([frame('present', 1, 'overview', 6_000)]))

    def test_dropped_presents_say_nothing_unless_a_kept_one_follows_the_start(self) -> None:
        # The TUI keeps the first frames of a phase. Without a kept present
        # after the window start, a dropped one may have come before it.
        dropped = '  present omitted=3 after first 512 frames'
        before = frame('present', 1, 'help', 4_000)
        self.assertIsNone(self.surface_at_start([before, dropped]))
        self.assertEqual(self.surface_at_start([before, frame('present', 2, 'help', 7_000), dropped]), 'help')


class LandingTest(unittest.TestCase):
    def test_a_screen_that_shows_another_surface_fails(self) -> None:
        landed = idle.Landing('approval-detail', 'approvals').report()
        self.assertFalse(landed['ok'])
        self.assertTrue(idle.screen_failed({'opened': True, 'keys_ok': True, 'landed': landed}))

    def test_a_report_that_does_not_say_fails(self) -> None:
        landed = idle.Landing('keeper-detail', None).report()
        self.assertTrue(idle.screen_failed({'opened': True, 'keys_ok': True, 'landed': landed}))

    def test_the_named_surface_passes(self) -> None:
        landed = idle.Landing('board-read', 'board-read').report()
        self.assertFalse(idle.screen_failed({'opened': True, 'keys_ok': True, 'landed': landed}))


class PressKeysTest(unittest.TestCase):
    def test_keys_stop_at_the_first_that_fails(self) -> None:
        # A jump that finds no palette leaves the TUI where it started, and
        # the moves meant for the destination would reach that screen.
        pressed: list[Key] = []

        def fake_press(child: Child, vte: Vte, key: Key) -> Sent:
            del child, vte
            pressed.append(key)
            return Sent('jump', False, 'palette-not-open') if isinstance(key, Jump) else Sent('move', True, 'sent')

        keys: list[Key] = [Jump('go Operations / Usage'), Press(b'p')]
        with mock.patch.object(idle, 'press', fake_press):
            sent = idle.press_keys(Child(0, -1, 0.0), Vte(10, 3), keys)
        self.assertEqual(pressed, keys[:1])
        self.assertEqual([entry.ok for entry in sent], [False])


if __name__ == '__main__':
    unittest.main()
