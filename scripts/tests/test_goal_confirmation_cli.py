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
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        if attested:
            self.send_header('x-masc-workspace-read', 'matched-v1')
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.server.calls.append(('GET', self.path))
        if urlsplit(self.path).path == '/health':
            self.send_json({'paths': {'effective_base_path': self.server.base,
                'effective_masc_root': self.server.base + '/.masc'}})
        else:
            if self.server.completed and self.server.fail_readback:
                self.send_json({'error': 'readback unavailable'}, status=503)
            else:
                self.send_json(COMPLETED if self.server.completed else PROOF, attested=self.server.attested)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.calls.append(('POST', body))
        if self.server.hold_post:
            self.server.post_entered.set()
            self.server.release_post.wait(5)
            return
        actor = {'Bearer fixture-token': 'operator-a', 'Bearer other-token': 'operator-b'}.get(self.headers.get('Authorization'))
        if body['expected_operator_id'] != actor or body['expected_workspace'] != {
            'base_path': self.server.base, 'masc_root': self.server.base + '/.masc'}:
            self.send_json({'error': 'precondition refused'}, status=400)
            return
        self.server.completed = True
        self.send_json(self.server.post_response or (PROOF if self.server.invalid_post else COMPLETED))


class ConfirmationCliTest(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.calls = []
        self.server.base = '/workspace-a'
        self.server.attested = True
        self.server.completed = False
        self.server.invalid_post = False
        self.server.post_response = None
        self.server.fail_readback = False
        self.server.hold_post = False
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


if __name__ == '__main__':
    unittest.main()
