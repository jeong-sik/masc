"""Check how the probe tells which TUI surface was on screen in each window.

The reports and terminal output here are written by the tests. They show that
frame starts are counted across reads, that a report's surface runs are read
only when they fit together and fit the frames the terminal received, and
that a window gets the surfaces on screen in it, with the frames read
together with a step's keys kept in the window before. They do not show what
a real TUI writes.
"""
import importlib
import json
from pathlib import Path
import sys
import unittest

TESTS = Path(__file__).resolve().parent
PERF = TESTS.parent / 'harness' / 'perf'
sys.path[:0] = [str(PERF)]
surfaces = importlib.import_module('tui_request_surfaces')

START = surfaces.FRAME_START
# What the TUI writes at the end of each frame and twice as it exits.
AUTOWRAP_ON = b'\x1b[?7h'


def line(**fields):
    return json.dumps(fields, separators=(',', ':'))


def run(surface, first):
    return line(schema=surfaces.RUN_SCHEMA, surface=surface, first_written_frame=first)


def counted(written, runs, omitted=0, unknown=None):
    return line(schema=surfaces.COUNT_SCHEMA, written_frames=written, runs=runs,
                omitted=omitted, unknown_from_written_frame=unknown)


def report(*lines):
    return '\n'.join(('build frames=3 mean=0.80ms', '{"schema":"masc.tui.frame.v2","frame":1}',
                      *lines)) + '\n'


def rows(shown):
    return [(row.surface, row.seconds, row.frames) for row in shown]


class FrameClockTest(unittest.TestCase):
    def test_a_frame_start_split_across_reads_counts_once_when_it_completes(self):
        clock = surfaces.FrameClock()
        clock.feed(b'a' + START[:2], 1.0)
        clock.feed(START[2:] + b'b' + START + START, 2.0)
        clock.feed(START[:-1], 3.0)
        clock.feed(b'', 4.0)
        clock.feed(START[-1:] + AUTOWRAP_ON, 5.0)
        clock.feed(AUTOWRAP_ON + AUTOWRAP_ON, 6.0)
        self.assertEqual(clock.starts, [2.0, 2.0, 2.0, 5.0])


class RunsTest(unittest.TestCase):
    def test_runs_name_the_surface_of_each_written_frame(self):
        runs = surfaces.parse_runs(report(run('overview', 1), run('board', 4), counted(9, 2)))
        self.assertEqual(runs, surfaces.Runs((1, 4), ('overview', 'board'), None, 9))
        self.assertEqual([runs.surface(frame) for frame in (0, 1, 3, 4, 9)],
                         [None, 'overview', 'overview', 'board', 'board'])

    def test_frames_past_the_kept_runs_have_no_surface(self):
        runs = surfaces.parse_runs(report(run('a', 1), run('b', 2), counted(5, 2, 1, 4)))
        self.assertEqual([runs.surface(frame) for frame in (2, 3, 4, 5)], ['b', 'b', None, None])

    def test_a_report_whose_runs_do_not_fit_together_says_why(self):
        reports = {
            'no count': report(run('a', 1)),
            'first run not at frame 1': report(run('a', 2), counted(3, 1)),
            'out of order': report(run('a', 1), run('b', 3), run('c', 3), counted(4, 3)),
            'repeated surface': report(run('a', 1), run('a', 2), counted(2, 2)),
            'frame given as true': report(run('a', True), counted(1, 1)),
            'empty surface': report(run('', 1), counted(1, 1)),
            'run after the count': report(counted(0, 0), run('a', 1)),
            'second count': report(run('a', 1), counted(1, 1), counted(1, 1)),
            'count of runs is off': report(run('a', 1), counted(1, 2)),
            'omitted without a frame': report(run('a', 1), counted(3, 1, 1, None)),
            'frame without omitted': report(run('a', 1), counted(3, 1, 0, 2)),
            'unknown at a kept run': report(run('a', 1), run('b', 2), counted(3, 2, 1, 2)),
            'unknown past the written': report(run('a', 1), counted(3, 1, 1, 4)),
            'run past the written': report(run('a', 1), run('b', 4), counted(3, 2)),
            'written without runs': report(counted(2, 0)),
            'runs without written': report(run('a', 1), counted(0, 1)),
            'broken JSON': report('{"schema":'),
        }
        for name, text in reports.items():
            with self.subTest(name):
                self.assertIsInstance(surfaces.parse_runs(text), str)

    def test_a_string_with_unicode_line_breaks_stays_on_its_report_line(self):
        # Yojson writes U+0085, U+2028 and U+2029 inside strings as they are.
        ask = json.dumps({'schema': 'masc.tui.ask.v1', 'ask_id': 'a\x85b\u2028c\u2029d'},
                         ensure_ascii=False)
        self.assertEqual(surfaces.parse_runs(report(ask, run('a', 1), counted(1, 1))),
                         surfaces.Runs((1,), ('a',), None, 1))

    def test_the_frames_received_must_be_the_frames_written(self):
        text = report(run('a', 1), counted(3, 1))
        for received, fits in ((2, False), (3, True), (4, False)):
            with self.subTest(received=received):
                self.assertEqual(isinstance(surfaces.read_runs(text, received), surfaces.Runs), fits)


class ShownTest(unittest.TestCase):
    runs = surfaces.Runs((1, 3), ('a', 'b'), None, 4)
    arrivals = (1.0, 2.0, 3.0, 4.0)

    def shown(self, first, end, start, stop, runs=None):
        return rows(surfaces.shown(self.arrivals, runs or self.runs, surfaces.FrameSpan(first, end),
                                   start, stop))

    def test_a_window_gets_each_surface_with_its_time_on_screen_and_frames(self):
        self.assertEqual(self.shown(0, 0, 0.0, 0.5), [])
        self.assertEqual(self.shown(0, 1, 0.5, 1.5), [('a', 0.5, 1)])
        self.assertEqual(self.shown(1, 3, 1.5, 3.5), [('a', 1.5, 1), ('b', 0.5, 1)])

    def test_the_last_frame_stays_on_screen_to_the_end_of_the_window(self):
        self.assertEqual(self.shown(4, 4, 4.5, 6.0), [('b', 1.5, 0)])

    def test_frames_with_no_recorded_surface_are_shown_as_none(self):
        runs = surfaces.Runs((1,), ('a',), 3, 4)
        self.assertEqual(self.shown(0, 4, 0.0, 10.0, runs), [('a', 2.0, 2), (None, 7.0, 2)])

    def test_frames_read_after_a_window_ended_add_no_time_to_it(self):
        # A TUI that exits during a step leaves frames for the probe's last
        # read, which can come after the step's window was cut at its end.
        runs = surfaces.Runs((1, 2), ('a', 'b'), None, 3)
        late = surfaces.shown((1.0, 5.0, 6.0), runs, surfaces.FrameSpan(0, 3), 0.0, 4.0)
        self.assertEqual(rows(late), [('a', 3.0, 1), ('b', 0.0, 2)])

    def test_frames_read_with_a_steps_keys_stay_in_the_window_before(self):
        # Three frames came in the read just before the keys went out at 2.0.
        runs = surfaces.Runs((1, 2, 4), ('a', 'b', 'c'), None, 4)
        arrivals = (1.0, 2.0, 2.0, 2.0)
        before = surfaces.shown(arrivals, runs, surfaces.FrameSpan(0, 4), 0.0, 2.0)
        after = surfaces.shown(arrivals, runs, surfaces.FrameSpan(4, 4), 2.0, 3.0)
        self.assertEqual(rows(before), [('a', 1.0, 1), ('b', 0.0, 2), ('c', 0.0, 1)])
        self.assertEqual(rows(after), [('c', 1.0, 0)])


if __name__ == '__main__':
    unittest.main()
