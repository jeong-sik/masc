"""Synthetic HTTP checks for the Goal confirmation CLI."""
import json
import signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit


SCRIPT = Path(__file__).resolve().parents[1] / 'goal-confirmation.py'
PROOF = {'inspection_operator_id': 'operator-a',
    'goal': {'id': 'goal-1', 'phase': 'awaiting_confirmation', 'criterion_revision': 'revision-1',
        'title': 'Goal', 'metric': 'cases', 'target_value': '10'},
    'verification': {'goal_id': 'goal-1', 'completion': {'state': 'proof_proven',
        'verdict': {'criterion': {'revision': 'revision-1', 'title': 'Goal', 'metric': 'cases', 'target_value': '10'},
                    'request_id': 'request-1', 'verification_run_id': 'run-1', 'outcome': 'proven', 'reason': None,
                    'evidence': '10 cases', 'recorded_at': '2026-11-01T00:00:00Z',
                    'authority': {'kind': 'system_llm_agent', 'actor': 'verifier'}}}}}
COMPLETED = json.loads(json.dumps(PROOF))
COMPLETED['goal']['phase'] = 'completed'
COMPLETED['verification']['completion'] = {'state': 'human_confirmed',
    'operator_id': 'operator-a', 'confirmed_at': '2026-11-01T00:00:00Z',
    'verdict': PROOF['verification']['completion']['verdict']}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_json(self, value, *, attested=False, status=200):
        raw = json.dumps(value).encode()
        if self.server.escape_token_in_json:
            raw = raw.replace(b'fixture-token', b'fixture\\u002dtoken')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        if attested:
            self.send_header('x-masc-workspace-read', 'matched-v1')
            if self.server.duplicate_workspace:
                self.send_header('x-masc-workspace-read', 'other')
            if self.server.instance is not None:
                self.send_header('x-masc-runtime-instance-id', self.server.instance)
                if self.server.duplicate_instance:
                    self.send_header('x-masc-runtime-instance-id', self.server.instance)
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.server.calls.append(('GET', self.path))
        if urlsplit(self.path).path == '/health':
            self.send_json({'paths': {'effective_base_path': self.server.base,
                'effective_masc_root': self.server.base + '/.masc'}})
        else:
            if self.server.hold_get_body:
                self.send_response(200)
                self.send_header('x-masc-workspace-read', 'matched-v1')
                self.send_header('x-masc-runtime-instance-id', self.server.instance)
                self.send_header('x-masc-runtime-instance-id', self.server.instance)
                self.end_headers()
                self.server.get_entered.set()
                self.server.release_get.wait(5)
                return
            if self.server.completed and self.server.fail_readback:
                self.send_json({'error': 'readback unavailable'}, status=503)
            else:
                self.send_json(COMPLETED if self.server.completed else self.server.get_response,
                    attested=self.server.attested)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.calls.append(('POST', body))
        if self.server.hold_post:
            self.server.post_entered.set()
            self.server.release_post.wait(5)
            return
        actor = {'Bearer fixture-token': 'operator-a', 'Bearer other-token': 'operator-b'}.get(self.headers.get('Authorization'))
        if body['expected_operator_id'] != actor or body.get('expected_runtime_instance_id') != self.server.instance or body['expected_workspace'] != {
            'base_path': self.server.base, 'masc_root': self.server.base + '/.masc'}:
            self.send_json({'error': 'precondition refused'}, status=400)
            return
        if self.server.post_error is not None:
            self.send_json(self.server.post_error, status=400)
            return
        self.server.completed = True
        self.send_json(self.server.post_response or (PROOF if self.server.invalid_post else COMPLETED))


class ConfirmationCliTest(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.calls = []
        self.server.base = '/workspace-a'
        self.server.instance = '018f83d7-93a4-7f5d-9a72-123456789abc'
        self.server.duplicate_instance = False
        self.server.duplicate_workspace = False
        self.server.attested = True
        self.server.completed = False
        self.server.invalid_post = False
        self.server.post_response = None
        self.server.post_error = None
        self.server.get_response = PROOF
        self.server.escape_token_in_json = False
        self.server.fail_readback = False
        self.server.hold_post = False
        self.server.hold_get_body = False
        self.server.get_entered = threading.Event()
        self.server.release_get = threading.Event()
        self.server.post_entered = threading.Event()
        self.server.release_post = threading.Event()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.directory = tempfile.TemporaryDirectory()
        self.token = Path(self.directory.name) / 'token'
        self.token.write_text('fixture-token')
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.release_post.set()
        self.server.release_get.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), '--url', self.url,
            '--token-file', str(self.token), '--goal-id', 'goal-1', *args],
            capture_output=True, text=True, check=False)

    def test_inspection_attests_workspace_and_confirmation_keeps_its_operator(self):
        inspected = self.run_cli()
        self.assertEqual(inspected.returncode, 0, inspected.stderr)
        evidence = json.loads(inspected.stdout)
        self.assertEqual(evidence['expected_runtime_instance_id'], self.server.instance)
        self.assertNotIn('fixture-token', inspected.stdout)
        query = parse_qs(urlsplit(self.server.calls[1][1]).query)
        self.assertEqual(query['expected_base_path'], ['/workspace-a'])
        self.assertEqual(query['expected_masc_root'], ['/workspace-a/.masc'])
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(inspected.stdout)
        self.server.base = '/workspace-b'
        confirmed = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(confirmed.returncode, 0)
        self.assertEqual(self.server.calls[-1][1]['expected_workspace'],
            {'base_path': '/workspace-a', 'masc_root': '/workspace-a/.masc'})
        self.assertEqual(self.server.calls[-1][1]['expected_operator_id'], 'operator-a')
        self.assertEqual(self.server.calls[-1][1]['expected_runtime_instance_id'], evidence['expected_runtime_instance_id'])
        self.assertEqual(len([call for call in self.server.calls if call[0] == 'GET']), 2)
        self.server.base = '/workspace-a'
        self.token.write_text('other-token')
        self.assertNotEqual(self.run_cli('--confirm-evidence', str(evidence_path)).returncode, 0)
        self.assertEqual(self.server.calls[-1][1]['expected_operator_id'], 'operator-a')
        self.token.write_text('fixture-token')
        self.assertEqual(self.run_cli('--confirm-evidence', str(evidence_path)).returncode, 0)

    def test_unattested_or_unbound_evidence_never_confirms(self):
        self.server.attested = False
        self.assertNotEqual(self.run_cli().returncode, 0)
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(json.dumps(PROOF))
        self.assertNotEqual(self.run_cli('--confirm-evidence', str(evidence_path)).returncode, 0)
        self.assertFalse(any(call[0] == 'POST' for call in self.server.calls))

    def test_instance_change_or_missing_instance_never_silently_rebinds_evidence(self):
        inspected = self.run_cli()
        self.assertEqual(inspected.returncode, 0, inspected.stderr)
        evidence = json.loads(inspected.stdout)
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(inspected.stdout)
        self.server.instance = '018f83d7-93a4-7f5d-9a72-abcdef123456'
        result = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.server.completed)
        self.assertEqual(self.server.calls[-1][1]['expected_runtime_instance_id'], evidence['expected_runtime_instance_id'])
        before = len(self.server.calls)
        del evidence['expected_runtime_instance_id']
        evidence_path.write_text(json.dumps(evidence))
        self.assertNotEqual(self.run_cli('--confirm-evidence', str(evidence_path)).returncode, 0)
        self.assertEqual(len(self.server.calls), before)
        self.server.instance = None
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.server.instance = '018f83d7-93a4-7f5d-9a72-abcdef123456'
        self.server.duplicate_instance = True
        self.assertNotEqual(self.run_cli().returncode, 0)
        self.server.duplicate_instance = False
        self.server.duplicate_workspace = True
        self.assertNotEqual(self.run_cli().returncode, 0)

    def test_duplicate_instance_headers_are_rejected_before_a_stalled_body(self):
        self.server.hold_get_body = True
        process = subprocess.Popen([sys.executable, str(SCRIPT), '--url', self.url,
            '--token-file', str(self.token), '--goal-id', 'goal-1'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertTrue(self.server.get_entered.wait(5))
        try:
            _, stderr = process.communicate(timeout=2)
        finally:
            self.server.release_get.set()
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=2)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn('unique runtime instance', stderr)
        self.assertFalse(any(call[0] == 'POST' for call in self.server.calls))

    def test_post_or_readback_without_matching_completion_is_not_success(self):
        inspected = self.run_cli()
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(inspected.stdout)
        self.server.invalid_post = True
        result = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Confirmation result is not verified', result.stderr)
        self.assertEqual(len([call for call in self.server.calls if call[0] == 'POST']), 1)
        self.server.completed = False
        self.server.invalid_post = False
        self.server.fail_readback = True
        result = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Confirmation result is not verified', result.stderr)
        self.assertEqual(len([call for call in self.server.calls if call[0] == 'POST']), 2)

    def test_refuted_or_malformed_proof_is_never_accepted(self):
        inspected = self.run_cli()
        bad = json.loads(inspected.stdout)
        bad['verification']['completion']['verdict']['outcome'] = 'refuted'
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(json.dumps(bad))
        self.assertNotEqual(self.run_cli('--confirm-evidence', str(evidence_path)).returncode, 0)
        self.assertFalse(any(call[0] == 'POST' for call in self.server.calls))
        evidence_path.write_text(inspected.stdout)
        bad_completed = json.loads(json.dumps(COMPLETED))
        bad_completed['verification']['completion']['verdict']['outcome'] = 'refuted'
        self.server.post_response = bad_completed
        self.assertNotEqual(self.run_cli('--confirm-evidence', str(evidence_path)).returncode, 0)
        bad_completed['verification']['completion']['verdict']['outcome'] = 'proven'
        bad_completed['verification']['completion']['operator_id'] = True
        self.server.completed = False
        self.assertNotEqual(self.run_cli('--confirm-evidence', str(evidence_path)).returncode, 0)
        changed_criterion = json.loads(json.dumps(COMPLETED))
        changed_criterion['goal']['metric'] = 'other metric'
        changed_criterion['verification']['completion']['verdict']['criterion']['metric'] = 'other metric'
        self.server.post_response = changed_criterion
        self.server.completed = False
        self.assertNotEqual(self.run_cli('--confirm-evidence', str(evidence_path)).returncode, 0)

    def test_interrupt_after_dispatch_reports_uncertainty_without_replay(self):
        inspected = self.run_cli()
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(inspected.stdout)
        self.server.hold_post = True
        process = subprocess.Popen([sys.executable, str(SCRIPT), '--url', self.url,
            '--token-file', str(self.token), '--goal-id', 'goal-1', '--confirm-evidence', str(evidence_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertTrue(self.server.post_entered.wait(5))
        process.send_signal(signal.SIGINT)
        _, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 130)
        self.assertIn('Confirmation may have been sent', stderr)
        self.assertIn('request-1', stderr)
        self.assertEqual(len([call for call in self.server.calls if call[0] == 'POST']), 1)

    def test_deadline_after_dispatch_reports_uncertainty_without_replay(self):
        inspected = self.run_cli()
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(inspected.stdout)
        self.server.hold_post = True
        process = subprocess.Popen([sys.executable, str(SCRIPT), '--url', self.url,
            '--token-file', str(self.token), '--goal-id', 'goal-1', '--confirm-evidence', str(evidence_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertTrue(self.server.post_entered.wait(5))
        process.send_signal(signal.SIGALRM)
        _, stderr = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn('Confirmation result is not verified', stderr)
        self.assertIn('request deadline elapsed', stderr)
        self.assertEqual(len([call for call in self.server.calls if call[0] == 'POST']), 1)

    def test_candle_refusal_shows_repair_guidance_without_credential_echo(self):
        inspected = self.run_cli()
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(inspected.stdout)
        self.server.post_error = {'error': 'candle payout owed: configuration unavailable; '
            'human confirmation may already be recorded; repair and inspect the same proof'}
        result = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('configuration unavailable', result.stderr)
        self.assertIn('human confirmation may already be recorded', result.stderr)
        self.assertIn('request-1', result.stderr)
        self.assertEqual(len([call for call in self.server.calls if call[0] == 'POST']), 1)

        self.server.post_error = {'error': 'do not echo fixture-token'}
        result = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Credential echo withheld', result.stderr)
        self.assertNotIn('fixture-token', result.stderr + result.stdout)

    def test_server_error_cannot_write_terminal_controls(self):
        inspected = self.run_cli()
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(inspected.stdout)
        self.server.post_error = {'error': '설정 수리 필요\x1b[2J\x1b]0;title\x07\u202eend'}
        result = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('설정 수리 필요', result.stderr)
        self.assertIn(r'\x1b[2J', result.stderr)
        self.assertIn(r'\x07', result.stderr)
        self.assertIn(r'\u202e', result.stderr)
        self.assertNotIn('\x1b', result.stderr)
        self.assertNotIn('\x07', result.stderr)
        self.assertNotIn('\u202e', result.stderr)

    def test_success_response_cannot_echo_json_escaped_credential(self):
        self.server.get_response = json.loads(json.dumps(PROOF))
        self.server.get_response['verification']['completion']['verdict']['evidence'] = 'fixture-token'
        self.server.escape_token_in_json = True
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Credential echo withheld', result.stderr)
        self.assertNotIn('fixture-token', result.stderr + result.stdout)

    def test_nested_encoded_credential_is_withheld_from_proof_error_and_loaded_evidence(self):
        nested = r'{"token":"fixture\\u002dtoken"}'
        self.server.get_response = json.loads(json.dumps(PROOF))
        self.server.get_response['verification']['completion']['verdict']['evidence'] = nested
        inspected = self.run_cli()
        self.assertNotEqual(inspected.returncode, 0)
        self.assertIn('Credential echo withheld', inspected.stderr)
        self.assertNotIn('fixture', inspected.stdout)

        self.server.get_response = PROOF
        inspected = self.run_cli()
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(inspected.stdout)
        self.server.post_error = {'error': nested}
        refused = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn('Credential echo withheld', refused.stderr)
        self.assertNotIn('fixture', refused.stderr)

        evidence = json.loads(inspected.stdout)
        evidence['verification']['completion']['verdict']['evidence'] = nested
        evidence_path.write_text(json.dumps(evidence))
        before = len(self.server.calls)
        refused = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn('Credential echo withheld', refused.stderr)
        self.assertEqual(len(self.server.calls), before)

    def test_runtime_instance_header_cannot_echo_credential(self):
        self.token.write_text(self.server.instance)
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Credential echo withheld', result.stderr)
        self.assertNotIn(self.server.instance, result.stderr + result.stdout)

    def test_old_evidence_cannot_echo_the_current_credential(self):
        inspected = self.run_cli()
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(inspected.stdout)
        self.token.write_text('request-1')
        before = len(self.server.calls)
        result = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Credential echo withheld', result.stderr)
        self.assertNotIn('request-1', result.stderr + result.stdout)
        self.assertEqual(len(self.server.calls), before)

    def test_old_evidence_cannot_write_terminal_controls_on_failure(self):
        inspected = self.run_cli()
        evidence = json.loads(inspected.stdout)
        evidence['verification']['completion']['verdict']['request_id'] = 'request-1\x1b]0;title\x07'
        evidence_path = Path(self.directory.name) / 'evidence.json'
        evidence_path.write_text(json.dumps(evidence))
        self.server.post_error = {'error': 'refused'}
        result = self.run_cli('--confirm-evidence', str(evidence_path))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(r'\x1b]0;title\x07', result.stderr)
        self.assertNotIn('\x1b', result.stderr)


if __name__ == '__main__':
    unittest.main()
