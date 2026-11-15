"""Run the TUI latency probe against a fake server and a fake TUI.

The fakes are not MASC. These tests show that `observed_surfaces` names every
surface the TUI recorded writing, also one it first wrote after the Build
frames its frame-timing summary keeps, that a list the TUI stopped recording
ends in `null` with the frame from which the surface is unknown, and that
without surface runs no list is given and `surface_record` says why. They do
not show what a real TUI writes.
"""
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TESTS = Path(__file__).resolve().parent
PERF = TESTS.parent / 'harness' / 'perf'
PROBE = PERF / 'tui_latency_probe.py'
sys.path[:0] = [str(PERF), str(TESTS)]
surfaces = importlib.import_module('tui_request_surfaces')
fakes = importlib.import_module('tui_request_fakes')

PROBE_TIMEOUT_S = 60
MODE_ENV = 'FAKE_TUI_MODE'
RESULT_FILE = 'result.json'
TIMING_FILE = 'frame-timing.txt'
# What the TUI writes at the end of each frame; the probe is ready once it
# follows the Dashboard title.
AUTOWRAP_ON = b'\x1b[?7h'
# The TUI's summary keeps the first 512 Build frames (max_frames_per_phase,
# bin/masc_tui_frame_timing.ml). The fake writes more than that before it
# reads the Tab, so the surface the Tab opens is first written after them.
SUMMARY_FRAMES = 512
FRAMES_BEFORE_TAB = SUMMARY_FRAMES + 88
FIRST_SURFACE = 'overview'
TAB_SURFACE = 'planning-list'

# FAKE_TUI_MODE: normal; capped keeps only the first surface run, as the TUI
# does past its cap; summary-only writes the summary and no surface runs;
# no-report writes no frame-timing report. Each frame opens with the frame
# start and ends with autowrap-on. The summary is the TUI's for the first
# SUMMARY_FRAMES Build frames: one line per surface, most frames first, then
# the frames it left out.
FAKE_TUI = '''
import json, os, select, signal, tty
mode = os.environ.get(MODE_ENV, 'normal')
tty.setraw(0)
tags, runs = [], []
def frame(text, shows):
    signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGTERM])
    os.write(1, START + text + END)
    tags.append(shows)
    if not runs or runs[-1]['surface'] != shows:
        runs.append(dict(schema=RUN_SCHEMA, surface=shows, first_written_frame=len(tags)))
    signal.pthread_sigmask(signal.SIG_UNBLOCK, [signal.SIGTERM])
def summary():
    kept = tags[:SUMMARY_FRAMES]
    counts = {}
    for tag in kept:
        counts[tag] = counts.get(tag, 0) + 1
    lines = ['build frames=%d mean=0.10ms p50=0.10 p95=0.10 p99=0.10 max=0.10' % len(kept)]
    for tag, n in sorted(counts.items(), key=lambda item: -item[1]):
        lines.append('  build[%s] frames=%d mean=0.10ms p50=0.10 p95=0.10 p99=0.10 max=0.10'
                     % (tag, n))
    if len(tags) > len(kept):
        lines.append('  build omitted=%d after first %d frames'
                     % (len(tags) - len(kept), SUMMARY_FRAMES))
    return lines
def surface_lines():
    if mode == 'capped':
        count = dict(schema=COUNT_SCHEMA, written_frames=len(tags), runs=1,
                     omitted=len(runs) - 1, unknown_from_written_frame=runs[1]['first_written_frame'])
        return [json.dumps(row) for row in runs[:1] + [count]]
    count = dict(schema=COUNT_SCHEMA, written_frames=len(tags), runs=len(runs), omitted=0,
                 unknown_from_written_frame=None)
    return [json.dumps(row) for row in runs + [count]]
def leave(*_):
    os.write(1, END + END)
    if mode != 'no-report':
        lines = summary() + ([] if mode == 'summary-only' else surface_lines())
        with open(os.environ['MASC_TUI_FRAME_TIMING'], 'a') as out:
            out.write(''.join(line + chr(10) for line in lines))
    os._exit(0)
signal.signal(signal.SIGTERM, leave)
frame(b'MASC Dashboard', FIRST_SURFACE)
for _ in range(FRAMES_BEFORE_TAB - 1):
    frame(b'tick', FIRST_SURFACE)
while True:
    if select.select([0], [], [], 0.05)[0] and os.read(0, 16):
        frame(b'pressed', TAB_SURFACE)
'''


def fake_tui() -> str:
    constants = dict(MODE_ENV=MODE_ENV, START=surfaces.FRAME_START, END=AUTOWRAP_ON,
                     RUN_SCHEMA=surfaces.RUN_SCHEMA, COUNT_SCHEMA=surfaces.COUNT_SCHEMA,
                     SUMMARY_FRAMES=SUMMARY_FRAMES, FRAMES_BEFORE_TAB=FRAMES_BEFORE_TAB,
                     FIRST_SURFACE=FIRST_SURFACE, TAB_SURFACE=TAB_SURFACE)
    return (f'#!{sys.executable}\n'
            + ''.join(f'{name} = {value!r}\n' for name, value in constants.items())
            + FAKE_TUI)


class LatencyProbeTest(unittest.TestCase):
    def setUp(self):
        self.upstream = fakes.Upstream()
        self.addCleanup(self.upstream.close)
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.base = self.tmp / 'base'
        self.base.mkdir()
        self.upstream.base_path = str(self.base.resolve())
        self.fake = self.tmp / 'fake-tui'
        self.fake.write_text(fake_tui())
        self.fake.chmod(0o755)

    def observe(self, mode, returncode):
        """Send one Tab, then return the probe's result and its output directory."""
        out = self.tmp / f'out-{mode}'
        completed = subprocess.run(
            [sys.executable, str(PROBE), '--binary', str(self.fake), '--base-path', str(self.base),
             '--output-dir', str(out), '--port', str(self.upstream.port), '--tabs', '1',
             '--tab-interval', '0.2', '--settle', '0.5', '--ready-timeout', '10',
             '--termination-grace', '3'],
            capture_output=True, text=True, timeout=PROBE_TIMEOUT_S,
            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', MODE_ENV: mode})
        self.assertEqual(completed.returncode, returncode, completed.stdout + completed.stderr)
        return json.loads((out / RESULT_FILE).read_text()), out

    def test_a_surface_first_written_after_the_summarys_frames_is_observed(self):
        result, out = self.observe('normal', 0)
        self.assertTrue(result['observation_complete'])
        # The summary the probe used to read stops before the Tab's surface.
        timing = (out / TIMING_FILE).read_text()
        self.assertIn('  build omitted=', timing)
        self.assertNotIn(f'  build[{TAB_SURFACE}]', timing)
        self.assertEqual(result['observed_surfaces'], [FIRST_SURFACE, TAB_SURFACE])
        self.assertEqual(result['surface_record'],
                         {'frames_written': FRAMES_BEFORE_TAB + 1, 'runs': 2,
                          'unknown_from_written_frame': None, 'error': None})

    def test_surfaces_the_tui_stopped_recording_are_unknown_from_their_frame(self):
        result, _ = self.observe('capped', 0)
        self.assertEqual(result['observed_surfaces'], [FIRST_SURFACE, None])
        record = result['surface_record']
        self.assertEqual(record['unknown_from_written_frame'], FRAMES_BEFORE_TAB + 1)
        self.assertIsNone(record['error'])

    def test_without_surface_runs_no_surface_is_observed_and_the_record_says_why(self):
        cases = (('summary-only', 0, 'the report has no surface run count'),
                 ('no-report', 1, surfaces.NO_REPORT))
        for mode, returncode, reason in cases:
            with self.subTest(mode=mode):
                result, _ = self.observe(mode, returncode)
                self.assertIsNone(result['observed_surfaces'])
                self.assertEqual(result['surface_record'],
                                 {'frames_written': None, 'runs': None,
                                  'unknown_from_written_frame': None, 'error': reason})


if __name__ == '__main__':
    unittest.main()
