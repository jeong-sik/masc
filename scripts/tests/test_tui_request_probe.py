"""Exercise the TUI request probe against a fake server and a fake TUI.

The fakes are not MASC. These tests show that the probe attributes requests
and events to windows, never starts its child when the server or the relay
cannot be verified, and reports an observation as incomplete when the TUI
never draws, leaves a step early, reaches the server around the relay or
sends bytes the relay cannot frame. They do not show what a real TUI sends.
"""
import importlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

TESTS = Path(__file__).resolve().parent
PERF = TESTS.parent / 'harness' / 'perf'
PROBE = PERF / 'tui_request_probe.py'
sys.path[:0] = [str(PERF), str(TESTS)]
events = importlib.import_module('tui_request_events')
surfaces = importlib.import_module('tui_request_surfaces')
probe = importlib.import_module('tui_request_probe')
fakes = importlib.import_module('tui_request_fakes')

PROBE_TIMEOUT_S = 60
MODE_ENV = 'FAKE_TUI_MODE'
# CPython warns after a fork while other OS threads run, then clears the
# warning (warn_about_fork_with_threads), so it can be seen but not raised.
FORK_WARNING = 'is multi-threaded'

# FAKE_TUI_MODE: normal; never-ready draws nothing; silent draws and sends no
# request; fault first sends bytes the relay cannot frame; exit-on-key exits 0
# at the first key; no-report writes no frame-timing report. As the TUI's
# presenter does, each frame opens with the frame start and ends with the
# autowrap-on sequence, and leaving writes autowrap-on twice and no frame
# start. Frames show `home` until a key makes them `pressed`. SIGTERM waits
# while a frame is written, so the report counts every frame.
FAKE_TUI = '''#!{python}
import http.client, json, os, select, signal, socket, sys, threading, time, tty
mode = os.environ.get({mode_env!r}, 'normal')
port = int(sys.argv[sys.argv.index('--port') + 1])
open({started!r}, 'w').close()
tty.setraw(0)
START, END = {frame_start!r}, {frame_end!r}
runs, written, surface = [], 0, None
def frame(text, shows):
    global written, surface
    signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGTERM])
    os.write(1, START + text + END)
    written += 1
    if shows != surface:
        runs.append(dict(schema={run_schema!r}, surface=shows, first_written_frame=written))
        surface = shows
    signal.pthread_sigmask(signal.SIG_UNBLOCK, [signal.SIGTERM])
def leave(*_):
    os.write(1, END + END)
    path = os.environ.get('MASC_TUI_FRAME_TIMING')
    if path and mode != 'no-report':
        count = dict(schema={count_schema!r}, written_frames=written, runs=len(runs), omitted=0,
                     unknown_from_written_frame=None)
        with open(path, 'a') as out:
            out.write(''.join(json.dumps(row) + chr(10) for row in runs + [count]))
    os._exit(0)
signal.signal(signal.SIGTERM, leave)
if mode == 'never-ready':
    while True:
        time.sleep(1)
frame(b'MASC Dashboard', 'home')
if mode == 'silent':
    while True:
        time.sleep(1)
if mode == 'fault':
    with socket.create_connection(('127.0.0.1', port)) as raw:
        raw.sendall(b'PRI * HTTP/2.0\\r\\n\\r\\nSM\\r\\n\\r\\n')
        raw.recv(1)
def hold():
    stream = http.client.HTTPConnection('127.0.0.1', port, timeout=30)
    stream.request('GET', '/hold?since=0')
    answer = stream.getresponse()
    while answer.read(8):
        pass
threading.Thread(target=hold, daemon=True).start()
reads = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
while True:
    reads.request('GET', '/json?tick=1')
    reads.getresponse().read()
    frame(b'tick', surface)
    if select.select([0], [], [], 0.1)[0] and os.read(0, 16):
        if mode == 'exit-on-key':
            os._exit(0)
        frame(b'pressed', 'pressed')
        reads.request('GET', '/json?pressed=1')
        reads.getresponse().read()
'''

# With SIGPIPE at its default the shell dies of its own SIGPIPE; ignored, it exits 3.
SIGPIPE_CHECK = '#!/bin/sh\nkill -PIPE $$\nexit 3\n'


class StepTest(unittest.TestCase):
    def test_steps_keep_their_text_and_the_bytes_they_send(self):
        self.assertEqual(probe.parse_step('tab:\\t:2.5'), probe.Step('tab', '\\t', b'\t', 2.5))
        self.assertEqual(probe.parse_step('rest::1'), probe.Step('rest', '', b'', 1.0))
        self.assertEqual(probe.parse_step('colon:a\\x3ab:1'),
                         probe.Step('colon', 'a\\x3ab', b'a:b', 1.0))
        self.assertEqual(probe.parse_step('e:\\u00e9:1').sent, 'é'.encode())

    def test_invalid_steps_say_why(self):
        for text in ('startup::1', 'two words::1', 'x:\u00e9:1', 'x::0', 'x::nan', 'x:\\x1:1',
                     'x:1', 'x:\\ud800:1'):
            with self.subTest(text=text):
                self.assertIsInstance(probe.parse_step(text), str)


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.upstream = fakes.Upstream()
        self.addCleanup(self.upstream.close)
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.base = self.tmp / 'base'
        self.base.mkdir()
        self.upstream.base_path = str(self.base.resolve())
        self.started = self.tmp / 'fake-tui-started'
        self.fake = self.tmp / 'fake-tui'
        self.fake.write_text(FAKE_TUI.format(
            python=sys.executable, mode_env=MODE_ENV, started=str(self.started),
            frame_start=surfaces.FRAME_START, frame_end=probe.READY_SUFFIX,
            run_schema=surfaces.RUN_SCHEMA,
            count_schema=surfaces.COUNT_SCHEMA))
        self.fake.chmod(0o755)
        self.out = self.tmp / 'out'

    def run_probe(self, *steps, mode='normal', binary=None, ready_timeout='10'):
        """Run the probe as a fresh process and check that it forked its child
        while it had one thread."""
        argv = [sys.executable, '-W', 'always::DeprecationWarning', str(PROBE),
                '--binary', str(binary or self.fake), '--base-path', str(self.base),
                '--output-dir', str(self.out), '--port', str(self.upstream.port), '--settle', '0.3',
                '--ready-timeout', ready_timeout, '--termination-grace', '3']
        for step in steps:
            argv += ['--step', step]
        completed = subprocess.run(
            argv, capture_output=True, text=True, timeout=PROBE_TIMEOUT_S,
            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', MODE_ENV: mode})
        self.assertNotIn(FORK_WARNING, completed.stderr)
        return completed

    def result(self, completed, returncode):
        self.assertEqual(completed.returncode, returncode, completed.stdout + completed.stderr)
        return json.loads((self.out / probe.RESULT_FILE).read_text())

    def test_each_window_counts_the_requests_that_started_in_it(self):
        result = self.result(self.run_probe('rest::0.8', 'press:x:0.8'), 0)
        self.assertTrue(result['observation_complete'])
        self.assertEqual(result['faults'], [])
        self.assertGreater(result['relayed_requests'], 0)
        windows = {window['label']: window for window in result['windows']}
        self.assertEqual(list(windows), ['startup', 'rest', 'press'])
        for before, after in zip(result['windows'], result['windows'][1:]):
            self.assertAlmostEqual(before['start_s'] + before['seconds'], after['start_s'], places=9)
        rest = {row['request']: row['count'] for row in windows['rest']['by_request']}
        press = {row['request']: row['count'] for row in windows['press']['by_request']}
        self.assertGreaterEqual(rest.get('GET /json?tick', 0), 1)
        self.assertNotIn('GET /json?pressed', rest)
        self.assertEqual(press.get('GET /json?pressed'), 1)
        self.assertEqual(windows['press']['keys'], 'x')
        ticks = [row for window in result['windows'] for row in window['by_event']
                 if row['event'] == f'/hold {events.COMMENT_EVENT}']
        self.assertTrue(ticks)
        (stream,) = result['streams']
        self.assertEqual((stream['request'], stream['status']), ('GET /hold?since', 200))
        self.assertIn(stream['ending'], ('client_closed', 'stopped'))
        shown = {window['label']: [row['surface'] for row in window['surfaces']]
                 for window in result['windows']}
        self.assertEqual(shown, {'startup': ['home'], 'rest': ['home'], 'press': ['home', 'pressed']})
        record = result['surface_record']
        self.assertIsNone(record['error'])
        self.assertEqual(record['frames_received'], record['frames_written'])
        for window in result['windows'][1:]:
            with self.subTest(window=window['label']):
                self.assertAlmostEqual(sum(row['seconds'] for row in window['surfaces']),
                                       window['seconds'], places=9)
        self.assertLessEqual(sum(row['frames'] for window in result['windows']
                                 for row in window['surfaces']), record['frames_received'])

    def test_a_tui_that_writes_no_surface_runs_leaves_every_window_unknown(self):
        result = self.result(self.run_probe('rest::0.5', mode='no-report'), 0)
        self.assertTrue(result['observation_complete'])
        self.assertEqual(result['surface_record']['error'], 'the TUI wrote no frame-timing report')
        self.assertEqual([window['surfaces'] for window in result['windows']], [None, None])

    def test_a_tui_that_never_draws_is_stopped_at_the_ready_timeout(self):
        result = self.result(self.run_probe('rest::0.5', mode='never-ready', ready_timeout='1'), 1)
        self.assertFalse(result['observation_complete'])
        self.assertIsNone(result['ready_after_s'])
        self.assertEqual([window['label'] for window in result['windows']], ['startup'])
        self.assertEqual((result['exit_code'], result['forced_kill']), (0, False))

    def test_a_step_the_tui_leaves_early_is_kept_as_unfinished(self):
        result = self.result(self.run_probe('press:x:5', mode='exit-on-key'), 1)
        self.assertFalse(result['observation_complete'])
        (press,) = [window for window in result['windows'] if window['label'] == 'press']
        self.assertFalse(press['finished'])
        self.assertLess(press['seconds'], 5)
        self.assertEqual(result['exit_code'], 0)

    def test_bytes_the_relay_cannot_frame_make_the_observation_incomplete(self):
        result = self.result(self.run_probe('rest::0.5', mode='fault'), 1)
        self.assertFalse(result['observation_complete'])
        self.assertEqual([fault['detail'].split(':', 1)[0] for fault in result['faults']], ['client'])

    def test_a_tui_whose_requests_never_reach_the_relay_is_not_an_observation(self):
        result = self.result(self.run_probe('rest::0.5', mode='silent'), 1)
        self.assertFalse(result['observation_complete'])
        self.assertEqual((result['relayed_requests'], result['faults']), (0, []))

    def test_the_tui_starts_with_sigpipe_at_its_default(self):
        check = self.tmp / 'sigpipe-check'
        check.write_text(SIGPIPE_CHECK)
        check.chmod(0o755)
        result = self.result(self.run_probe('rest::0.5', binary=check), 1)
        self.assertEqual(result['exit_code'], -signal.SIGPIPE)

    def test_the_child_never_runs_when_the_relay_reaches_another_runtime(self):
        self.upstream.runtimes = ['runtime-a', 'runtime-b']
        completed = self.run_probe('rest::0.5')
        self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
        self.assertIn('runtime-b', completed.stderr)
        self.assertFalse(self.started.exists())
        self.assertFalse((self.out / probe.RESULT_FILE).exists())

    def test_a_server_on_another_base_path_is_refused_before_any_child(self):
        self.upstream.base_path = str(self.tmp.resolve())
        completed = self.run_probe('rest::0.5')
        self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
        self.assertFalse(self.started.exists())
        self.assertFalse(self.out.exists())


if __name__ == '__main__':
    unittest.main()
