"""Exercise the fixture/controller contract with a fake PTY client.

The fake deliberately is not a MASC executable; these tests do not establish
that the pinned binaries build, poll, or produce any particular byte result.
"""
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
import time
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "measure-viewport-cadence-bytes.py"
spec = importlib.util.spec_from_file_location("viewport_cadence_bytes", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

FAKE = '''#!{python}
import os, tty
tty.setraw(0)
os.write(1, b'FAKE_TTY_READY')
import json, sys, time, urllib.request
mode = {mode!r}
port = sys.argv[sys.argv.index('--port') + 1]
root = 'http://127.0.0.1:' + port + '/api/v1/dashboard/browser-lane/'
request = json.dumps({{'lane':'live','clientId':'fixture-client-0001','tabId':7}}).encode()
def post(path):
    req = urllib.request.Request(root + path, data=request, headers={{'Content-Type':'application/json'}})
    with urllib.request.urlopen(req, timeout=4) as reply:
        return json.load(reply)
def write(data):
    os.write(1, data)
while os.read(0, 1) != b'\\x1e':
    pass
post('read')
write(b'Read 250.0 ms')
while os.read(0, 1) != b'\\x0f':
    pass
previous = None
initial_png = None
for number in range(1, 10):
    if mode == 'missing' and number == 5:
        break
    data = post('screenshot')['data']
    title = data['title']
    if initial_png is None:
        initial_png = data['data']
    changed = title != previous
    if mode != 'noise_only' and (mode == 'before' or previous is None or
                                 (changed and mode not in ('no_control', 'unrelated_control'))):
        write(title.encode() + b'\\x1b]1337;File=inline=1:' + data['data'].encode() + b'\\x07')
    if mode == 'unrelated_control' and number == 8:
        # Deliberately emit a hard-coded title and the stored first image,
        # independently of the current response data.
        write(b'Cadence control changed' + b'\\x1b]1337;File=inline=1:' + initial_png.encode() + b'\\x07')
    write(b'unrelated terminal output')
    previous = title
    time.sleep(0.06)
time.sleep(5)
'''


class HarnessTest(unittest.TestCase):
    def setUp(self):
        self.old = (module.STARTUP_SEC, module.READY_TIMEOUT_SEC, module.POLL_TIMEOUT_SEC, module.SESSION_SEC)
        module.STARTUP_SEC, module.READY_TIMEOUT_SEC, module.POLL_TIMEOUT_SEC, module.SESSION_SEC = 1.0, 3.0, 3.0, 2.0
        self.control_title = 'Control-' + module.secrets.token_hex(12)
        self.tmp = tempfile.TemporaryDirectory(prefix="masc-viewport-contract-")
        self.root = Path(self.tmp.name).resolve()

    def tearDown(self):
        module.STARTUP_SEC, module.READY_TIMEOUT_SEC, module.POLL_TIMEOUT_SEC, module.SESSION_SEC = self.old
        self.tmp.cleanup()

    def executable(self, mode):
        exe = self.root / (mode + '.py')
        exe.write_text(FAKE.format(python=sys.executable, mode=mode))
        exe.chmod(0o755)
        return exe

    def measure(self, mode):
        exe = self.executable(mode)
        base = self.root / (mode + '-base')
        (base / '.masc').mkdir(parents=True)
        return module.measure(exe, base, self.root / (mode + '-capture.bin'), self.control_title,
                              startup_marker=b'FAKE_TTY_READY')

    def test_equal_poll_windows_and_changed_image_control(self):
        before, after = self.measure('before'), self.measure('after')
        verdict = module.judge(before, after)
        self.assertEqual(before['poll_count'], module.EXPECTED_POLLS)
        self.assertEqual(after['constant_samples'], module.CONSTANT_SAMPLES)
        self.assertEqual([w['poll'] for w in before['windows']], list(range(1, 9)))
        self.assertTrue(verdict['valid'], (before, after))
        self.assertTrue(verdict['comparison_passed'])
        self.assertTrue(verdict['control_windows_observed'])
        self.assertEqual(before['constant_windows_with_title_and_image'], 5)
        self.assertEqual(after['constant_windows_with_title_and_image'], 0)
        self.assertGreaterEqual(after['session_duration_sec'], module.SESSION_SEC)
        self.assertGreater(after['session_total_bytes'], 0)
        fixture = json.loads((self.root / after['fixture_capture']).read_text())
        self.assertEqual(len(fixture['screenshot_exchanges']), module.EXPECTED_POLLS)
        self.assertTrue(any(e['path'].endswith('/browser-lane/read') for e in fixture['setup_exchanges']))
        titles = [e['response']['data']['title'] for e in fixture['screenshot_exchanges']]
        self.assertEqual(titles[7], self.control_title)
        self.assertNotIn(self.control_title, titles[:7] + titles[8:])

    def test_unrelated_output_without_title_and_image_does_not_pass_control(self):
        result = self.measure('no_control')
        self.assertGreater(result['control_tick_bytes'], 0, result)
        self.assertFalse(result['control_window_observed'])
        self.assertFalse(result['valid'])

    def test_discarded_screenshot_with_unrelated_output_is_invalid(self):
        result = self.measure('noise_only')
        self.assertEqual(result['poll_count'], module.EXPECTED_POLLS)
        self.assertGreater(result['constant_ticks_bytes'], 0)
        self.assertFalse(result['initial_window_observed'])
        self.assertFalse(result['control_window_observed'])
        self.assertFalse(result['valid'])

    def test_fixed_control_title_and_old_image_are_rejected(self):
        # The fake emits a hard-coded title and an earlier image independently
        # of this response; it cannot predict the per-run title.
        result = self.measure('unrelated_control')
        self.assertFalse(result['control_window_observed'])
        self.assertFalse(result['valid'])

    def test_overlapping_responses_invalidate_the_boundary(self):
        current = {'released_at': 1.0, 'completed_at': 3.0}
        self.assertFalse(module.response_boundary_ordered(current, {'received_at': 2.0}))
        self.assertTrue(module.response_boundary_ordered(current, {'received_at': 4.0}))
        self.assertFalse(module.response_boundary_ordered({'released_at': 1.0}, {'received_at': 4.0}))

    def test_reset_before_reply_is_an_error_not_a_delivered_poll(self):
        fixture = module.Fixture(self.root, self.control_title)
        with module.fixture_server(fixture) as port:
            body = json.dumps({'lane': 'live', 'clientId': module.CLIENT, 'tabId': 7}).encode()
            client = socket.create_connection(('127.0.0.1', port), timeout=3)
            client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
            client.sendall(b'POST /api/v1/dashboard/browser-lane/screenshot HTTP/1.1\r\n'
                           b'Host: localhost\r\nContent-Type: application/json\r\n'
                           + f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
            event = fixture.requests.get(timeout=3)
            client.close()
            time.sleep(0.1)  # let the loopback reset reach the server before release
            event['gate'].set()
            deadline = time.monotonic() + 3
            while fixture.responses_complete < 1 and time.monotonic() < deadline:
                time.sleep(0.01)
        self.assertEqual(fixture.poll_count, 1)
        self.assertTrue(fixture.errors)
        self.assertFalse(fixture.exchanges[0]['reply_written'])

    def test_missing_polls_invalidate_even_when_noise_flows(self):
        result = self.measure('missing')
        self.assertNotEqual(result['poll_count'], module.EXPECTED_POLLS)
        self.assertFalse(result['valid'])

    def test_judge_requires_expected_counts_and_positive_delta(self):
        good = {'poll_count': 9, 'constant_samples': 5, 'constant_ticks_bytes': 100,
                'constant_windows_with_title_and_image': 5, 'control_window_observed': True, 'valid': True}
        short = dict(good, poll_count=8)
        self.assertFalse(module.judge(short, short)['poll_counts_match'])
        no_delta = module.judge(good, good)
        self.assertTrue(no_delta['valid'])
        self.assertFalse(no_delta['comparison_passed'])
        only_noise_changed = module.judge(good, dict(good, constant_ticks_bytes=50))
        self.assertFalse(only_noise_changed['comparison_passed'])
        self.assertFalse(module.judge(good, dict(good, valid=False))['comparison_passed'])

    def test_three_session_main_with_fake_clients(self):
        before = self.executable('before')
        after = self.executable('after')
        out = self.root / 'report.json'
        real_measure = module.measure

        def with_fake_marker(exe, base, capture, title):
            return real_measure(exe, base, capture, title, startup_marker=b'FAKE_TTY_READY')

        with mock.patch.object(module, 'measure', side_effect=with_fake_marker), \
             mock.patch.object(sys, 'argv', ['measure', '--before', str(before),
                                            '--after', str(after), '--out', str(out)]):
            self.assertEqual(module.main(), 0)
        report = json.loads(out.read_text())
        self.assertTrue(report['comparison_passed'])
        self.assertEqual(report['constant_samples_per_side'], 15)
        for label in ('before', 'after'):
            self.assertEqual(len(report[label]), 3)
            for index, session in enumerate(report[label], 1):
                self.assertEqual(session['poll_count'], 9)
                self.assertEqual(session['session_poll_count'], 8)
                self.assertTrue((self.root / f'capture-{label}-{index}.bin').exists())
                self.assertTrue((self.root / session['fixture_capture']).exists())

    def test_main_fails_on_no_reduction_but_writes_report(self):
        same = {'poll_count': 9, 'constant_samples': 5, 'constant_ticks_bytes': 100,
                'constant_windows_with_title_and_image': 5, 'control_window_observed': True, 'valid': True}
        out = self.root / 'report.json'
        with mock.patch.object(module.secrets, 'token_hex', return_value='ab' * 12), \
             mock.patch.object(module, 'measure', side_effect=[same] * (2 * module.SESSIONS)) as measure, \
             mock.patch.object(sys, 'argv', ['measure', '--before', '/before', '--after', '/after',
                                            '--out', str(out)]):
            self.assertEqual(module.main(), 3)
        report = json.loads(out.read_text())
        self.assertFalse(report['comparison_passed'])
        self.assertEqual(report['control_title'], 'Control-' + 'ab' * 12)
        self.assertEqual([call.args[3] for call in measure.call_args_list],
                         [report['control_title']] * (2 * module.SESSIONS))
        self.assertEqual(len(report['before']), module.SESSIONS)
        self.assertEqual(len(report['after']), module.SESSIONS)
        self.assertEqual(len(report['session_comparisons']), module.SESSIONS)


if __name__ == '__main__':
    unittest.main()
