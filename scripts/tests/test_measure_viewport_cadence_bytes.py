"""Exercise the fixture/controller contract with a fake PTY client.

The fake deliberately is not a MASC executable; these tests do not establish
that the pinned binaries build, poll, or produce any particular byte result.
"""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "measure-viewport-cadence-bytes.py"
PINS_PATH = MODULE_PATH.parent / "resolve-viewport-cadence-pins.sh"
spec = importlib.util.spec_from_file_location("viewport_cadence_bytes", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

FAKE = '''#!{python}
import os, tty
tty.setraw(0)
os.write(1, b'FAKE_TTY_READY')
import json, select, socket, sys, time, urllib.request
mode = {mode!r}
port = sys.argv[sys.argv.index('--port') + 1]
root = 'http://127.0.0.1:' + port + '/api/v1/dashboard/browser-lane/'
request = json.dumps({{'lane':'live','clientId':'fixture-client-0001','tabId':7}}).encode()
initial_read = json.dumps({{'lane':'live','clientId':'fixture-client-0001'}}).encode()
def post(path, body=request):
    req = urllib.request.Request(root + path, data=body, headers={{'Content-Type':'application/json'}})
    with urllib.request.urlopen(req, timeout=4) as reply:
        return json.load(reply)
def post_without_reading():
    with socket.create_connection(('127.0.0.1', int(port)), timeout=4) as client:
        client.sendall(b'POST /api/v1/dashboard/browser-lane/screenshot HTTP/1.1\\r\\n'
                       b'Host: localhost\\r\\nContent-Type: application/json\\r\\n'
                       + f'Content-Length: {{len(request)}}\\r\\nConnection: close\\r\\n\\r\\n'.encode()
                       + request)
def write(data):
    os.write(1, data)
def read_key():
    key = os.read(0, 1)
    with open(sys.argv[0] + '.keys', 'ab') as keys:
        keys.write(key)
    return key
while read_key() != b'\\x1e':
    pass
post('read', initial_read)
if mode == 'no_selected_tab':
    sys.exit(0)
if mode == 'delayed_read':
    # A busy TUI consumes and ignores early Ctrl-O input.
    deadline = time.monotonic() + 0.4
    while time.monotonic() < deadline:
        if select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
            read_key()
# A selected-tab read can only be launched once the initial response is applied.
post('read')
while read_key() != b'\\x0f':
    pass
previous = None
initial_png = None
for number in range(1, 10):
    if select.select([0], [], [], 0)[0] and read_key() == b'\\x0f':
        break  # A duplicate input would dismiss the open viewport.
    if mode == 'missing' and number == 5:
        break
    if mode == 'unread':
        post_without_reading()
        write(b'unrelated terminal output')
        time.sleep(0.06)
        continue
    data = post('screenshot')['data']
    image = data['data']
    if initial_png is None:
        initial_png = data['data']
    changed = image != previous
    if mode != 'noise_only' and (mode == 'before' or previous is None or
                                 (changed and mode not in ('no_control', 'unrelated_control', 'detached_control'))):
        sequence = b'\\x1b]1337;File=inline=1:' + image.encode() + b'\\x07'
        write(sequence[:11]); write(sequence[11:])
    if mode == 'unrelated_control' and number == 8:
        # The old image is not the control response's marked image.
        write(b'\\x1b]1337;File=inline=1:' + initial_png.encode() + b'\\x07')
    if mode == 'detached_control' and number == 8:
        # A payload printed after an empty OSC is not an image transmission.
        write(b'\\x1b]1337;File=inline=1:\\x07' + image.encode())
    write(b'unrelated terminal output')
    previous = image
    time.sleep(0.06)
time.sleep(5)
'''


class HarnessTest(unittest.TestCase):
    def setUp(self):
        self.old = (module.STARTUP_SEC, module.READY_TIMEOUT_SEC, module.POLL_TIMEOUT_SEC,
                    module.SESSION_SEC, module.CADENCE_SEC)
        module.STARTUP_SEC, module.POLL_TIMEOUT_SEC, module.SESSION_SEC = 1.0, 3.0, 2.0
        module.CADENCE_SEC = 0.06
        self.control_image = module.make_control_png()
        self.tmp = tempfile.TemporaryDirectory(prefix="masc-viewport-contract-")
        self.root = Path(self.tmp.name).resolve()

    def tearDown(self):
        (module.STARTUP_SEC, module.READY_TIMEOUT_SEC, module.POLL_TIMEOUT_SEC,
         module.SESSION_SEC, module.CADENCE_SEC) = self.old
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
        return module.measure(exe, base, self.root / (mode + '-capture.bin'), self.control_image,
                              startup_marker=b'FAKE_TTY_READY')

    def test_equal_poll_windows_and_changed_image_control(self):
        before, after = self.measure('before'), self.measure('after')
        verdict = module.judge(before, after)
        self.assertEqual(before['poll_count'], module.EXPECTED_POLLS, before)
        self.assertEqual(after['constant_samples'], module.CONSTANT_SAMPLES, after)
        self.assertEqual([w['poll'] for w in before['windows']], list(range(1, 9)))
        self.assertTrue(verdict['valid'], (before, after))
        self.assertTrue(verdict['comparison_passed'])
        self.assertTrue(verdict['control_windows_observed'])
        self.assertEqual(before['constant_windows_with_image'], 5)
        self.assertEqual(after['constant_windows_with_image'], 0)
        self.assertGreaterEqual(after['session_duration_sec'], module.SESSION_SEC)
        self.assertGreater(after['session_total_bytes'], 0)
        fixture = json.loads((self.root / after['fixture_capture']).read_text())
        self.assertEqual(fixture['schema'], 'masc.viewport_fixture.v2')
        self.assertEqual(fixture['control_png_sha256'],
                         hashlib.sha256(base64.b64decode(self.control_image)).hexdigest())
        self.assertEqual(len(fixture['screenshot_exchanges']), module.EXPECTED_POLLS)
        self.assertTrue(any(e['path'].endswith('/browser-lane/read') for e in fixture['setup_exchanges']))
        responses = [e['response']['data'] for e in fixture['screenshot_exchanges']]
        images = [response['data'] for response in responses]
        self.assertEqual(images[7], self.control_image)
        self.assertNotIn(self.control_image, images[:7] + images[8:])
        self.assertTrue(all({k: v for k, v in response.items() if k != 'data'}
                            == {k: v for k, v in responses[0].items() if k != 'data'}
                            for response in responses))

    def test_waits_for_selected_tab_before_sending_one_open_key(self):
        result = self.measure('delayed_read')
        self.assertTrue(result['selected_tab_cadence_observed'], result)
        self.assertEqual(result['poll_count'], module.EXPECTED_POLLS, result)
        self.assertTrue(result['valid'], result)
        keys = Path(result['executable'] + '.keys').read_bytes()
        self.assertEqual(keys, b'\x1e\x0f')
        fixture = json.loads((self.root / result['fixture_capture']).read_text())
        reads = [entry for entry in fixture['setup_exchanges']
                 if entry['path'].endswith('/browser-lane/read')]
        self.assertNotIn('tabId', reads[0]['request'])
        self.assertEqual(reads[1]['request']['tabId'], 7)

    def test_no_selected_tab_read_does_not_send_open_key(self):
        result = self.measure('no_selected_tab')
        self.assertFalse(result['selected_tab_cadence_observed'])
        self.assertEqual(result['poll_count'], 0)
        self.assertFalse(result['valid'])
        self.assertEqual(Path(result['executable'] + '.keys').read_bytes(), b'\x1e')

    def test_unrelated_output_without_control_image_does_not_pass_control(self):
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

    def test_unread_screenshot_responses_with_noise_are_invalid(self):
        result = self.measure('unread')
        self.assertEqual(result['poll_count'], module.EXPECTED_POLLS)
        self.assertGreater(result['control_tick_bytes'], 0)
        self.assertFalse(result['control_window_observed'])
        self.assertFalse(result['valid'])

    def test_old_image_is_rejected_as_control(self):
        result = self.measure('unrelated_control')
        self.assertFalse(result['control_window_observed'])
        self.assertFalse(result['valid'])

    def test_payload_after_empty_osc_is_not_an_image(self):
        result = self.measure('detached_control')
        self.assertTrue(result['initial_window_observed'])
        self.assertFalse(result['control_window_observed'])
        self.assertFalse(result['valid'])

    def test_control_png_preserves_pixel_data_and_chunk_checksums(self):
        def chunks(png):
            self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
            result, offset = [], 8
            while offset < len(png):
                length = struct.unpack_from('>I', png, offset)[0]
                tag = png[offset + 4:offset + 8]
                body = png[offset + 8:offset + 8 + length]
                checksum = struct.unpack_from('>I', png, offset + 8 + length)[0]
                self.assertEqual(checksum, zlib.crc32(tag + body) & 0xFFFFFFFF)
                result.append((tag, body))
                offset += 12 + length
            self.assertEqual(offset, len(png))
            self.assertEqual(result[-1][0], b'IEND')
            return result

        baseline = chunks(module.PNG)
        marked = chunks(base64.b64decode(self.control_image))
        self.assertEqual([chunk for chunk in marked if chunk[0] != b'tEXt'], baseline)
        self.assertEqual(struct.unpack('>II', baseline[0][1][:8]), (80, 60))
        self.assertEqual(zlib.decompress(b''.join(body for tag, body in baseline if tag == b'IDAT')),
                         zlib.decompress(b''.join(body for tag, body in marked if tag == b'IDAT')))

    def test_image_payload_must_be_in_one_complete_iterm_sequence(self):
        payload = self.control_image.encode()
        valid = b'\x1b]1337;File=inline=1;width=78:' + payload + b'\x07'
        # The capture joins PTY reads before checking each response window.
        self.assertTrue(module.has_iterm_image(b''.join(bytes([b]) for b in valid), self.control_image))
        self.assertFalse(module.has_iterm_image(valid[:-1], self.control_image))
        self.assertFalse(module.has_iterm_image(b'\x1b]1337;File=inline=1:\x07' + payload,
                                               self.control_image))
        self.assertFalse(module.has_iterm_image(b'\x1b]1337;File=inline=1:' + payload + b'other\x07',
                                               self.control_image))
        self.assertFalse(module.has_iterm_image(b'\x1b]1337;File=inline=1;\x1b[0mwidth=78:'
                                               + payload + b'\x07', self.control_image))
        for fields in (b'inline=1;inline=0', b'inline=0;inline=1'):
            self.assertFalse(module.has_iterm_image(b'\x1b]1337;File=' + fields + b':'
                                                   + payload + b'\x07', self.control_image))

    def test_overlapping_responses_invalidate_the_boundary(self):
        current = {'released_at': 1.0, 'completed_at': 3.0}
        self.assertFalse(module.response_boundary_ordered(current, {'received_at': 2.0}))
        self.assertTrue(module.response_boundary_ordered(current, {'received_at': 4.0}))
        self.assertFalse(module.response_boundary_ordered({'released_at': 1.0}, {'received_at': 4.0}))

    def test_reset_before_reply_is_an_error_not_a_delivered_poll(self):
        fixture = module.Fixture(self.root, self.control_image)
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
                'constant_windows_with_image': 5, 'control_window_observed': True, 'valid': True}
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

        def with_fake_marker(exe, base, capture, image):
            return real_measure(exe, base, capture, image, startup_marker=b'FAKE_TTY_READY')

        with mock.patch.object(module, 'measure', side_effect=with_fake_marker), \
             mock.patch.object(sys, 'argv', ['measure', '--before', str(before),
                                            '--after', str(after), '--out', str(out)]):
            self.assertEqual(module.main(), 0)
        report = json.loads(out.read_text())
        self.assertEqual(report['schema'], 'masc.viewport_cadence_bytes.v3')
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
                'constant_windows_with_image': 5, 'control_window_observed': True, 'valid': True}
        out = self.root / 'report.json'
        with mock.patch.object(module.secrets, 'token_hex', return_value='ab' * 12), \
             mock.patch.object(module, 'measure', side_effect=[same] * (2 * module.SESSIONS)) as measure, \
             mock.patch.object(sys, 'argv', ['measure', '--before', '/before', '--after', '/after',
                                            '--out', str(out)]):
            self.assertEqual(module.main(), 3)
        report = json.loads(out.read_text())
        self.assertFalse(report['comparison_passed'])
        images = [call.args[3] for call in measure.call_args_list]
        self.assertTrue(all(image == images[0] for image in images))
        self.assertEqual(report['control_png_sha256'],
                         hashlib.sha256(base64.b64decode(images[0])).hexdigest())
        self.assertEqual(len(report['before']), module.SESSIONS)
        self.assertEqual(len(report['after']), module.SESSIONS)
        self.assertEqual(len(report['session_comparisons']), module.SESSIONS)


class PinsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='masc-viewport-pins-')
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.runner = self.root / 'runner'
        self.runner.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Viewport test')
        self.git('config', 'user.email', 'viewport-test@example.invalid')
        # The disposable fixture is not the user's repository; do not invoke
        # machine-wide hooks or signing settings while manufacturing commits.
        (self.root / 'empty-hooks').mkdir()
        self.git('config', 'core.hooksPath', str(self.root / 'empty-hooks'))
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'tag.gpgsign', 'false')
        self.git('commit', '--quiet', '--allow-empty', '-m', 'before')
        self.before = self.git('rev-parse', 'HEAD').stdout.strip()
        self.git('tag', '-a', 'before-tag', '-m', 'annotated tag')
        self.git('commit', '--quiet', '--allow-empty', '-m', 'after')
        self.after = self.git('rev-parse', 'HEAD').stdout.strip()
        self.git('update-ref', 'refs/remotes/origin/feature', self.after)
        (self.repo / 'blob.txt').write_text('not a commit')
        self.blob = self.git('hash-object', '-w', 'blob.txt').stdout.strip()

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, text=True, capture_output=True, check=True)

    def resolve(self, before, after):
        env = dict(os.environ, BEFORE_SHA=before, AFTER_REF=after,
                   RUNNER_TEMP=str(self.runner), GITHUB_ENV=str(self.root / 'github-env'))
        return subprocess.run(['bash', str(PINS_PATH)], cwd=self.repo, env=env,
                              text=True, capture_output=True)

    def test_inputs_are_resolved_to_commit_heads_and_recorded(self):
        self.git('checkout', '--quiet', '--detach', self.before)
        result = self.resolve('before-tag', 'feature')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.after)
        self.assertEqual((self.runner / 'source-heads.txt').read_text(),
                         f'before_sha={self.before}\nafter_sha={self.after}\n')
        self.assertEqual((self.root / 'github-env').read_text(),
                         f'BEFORE_SHA={self.before}\nAFTER_SHA={self.after}\n')

    def test_invalid_or_option_like_input_does_not_record_or_checkout(self):
        self.git('checkout', '--quiet', '--detach', self.before)
        for before, after in [('before-tag', '--help'), ('--help', 'feature'),
                              ('before-tag', self.blob), (self.blob, 'feature')]:
            result = self.resolve(before, after)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), self.before)
            self.assertFalse((self.runner / 'source-heads.txt').exists())
            self.assertFalse((self.root / 'github-env').exists())


if __name__ == '__main__':
    unittest.main()
