"""HTTP fixture coverage for the discovery probe, not installed acceptance."""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'verify-installed-workspace-memory-discovery.py'
COMMIT = 'a' * 40
BINARY = 'b' * 64
TOKEN = 'fixture-private-token-never-log'
KEEPERS = ('fixture-editor', 'fixture-designer')
CASES = {
    'valid': None,
    'valid_override': None,
    'scattered_markers': 'exactly one complete resolved discovery fragment',
    'null_instance': 'Runtime instance identity is missing',
    'degraded_health': 'Installed health degraded during observation',
    'base_changed': 'Runtime base or memory root changed during observation',
    'persistent_leak': 'leaked into the persisted-message preview',
    'identity_changed': 'Runtime identity changed during observation',
    'missing_publication': 'publication.json',
    'credential_echo': 'Credential echo withheld from evidence',
    'prompt_changed': 'Resolved discovery prompt changed during observation',
    'duplicate_fragment': 'exactly one complete resolved discovery fragment',
}


class InstalledDiscoveryProbeTests(unittest.TestCase):
    def run_case(self, case, expected_error):
        with tempfile.TemporaryDirectory(prefix='masc-discovery-probe-test-') as directory:
            base = Path(directory)
            store = base / '.masc/workspace-memory/proposals'
            store.mkdir(parents=True)
            proposal = {
                'context_sha256': 'c' * 64,
                'status': 'model_proposed',
                'sources': [],
                'snapshots': [],
                'gaps': [],
                'proposal': {'shared_claims': [], 'conflicts': [], 'excluded': []},
            }
            raw = json.dumps(proposal, sort_keys=True, separators=(',', ':')).encode()
            proposal_id = hashlib.sha256(raw).hexdigest()
            (store / (proposal_id + '.json')).write_bytes(raw)
            descriptor = {
                'schema': 'workspace.memory.publication.v1',
                'proposal_id': proposal_id,
                'context_sha256': 'c' * 64,
            }
            if case != 'missing_publication':
                (store.parent / 'publication.json').write_text(json.dumps(descriptor))
            token_file = base / 'token.private'
            token_file.write_text(TOKEN)
            token_file.chmod(0o600)

            if case == 'valid_override':
                template = 'Operator customized discovery: {{ proposal_id }} captured {{ context_sha256 }}\n'
            else:
                template = 'Shared workspace proposal {{proposal_id}} with input {{context_sha256}}\n'
            template += ('Read keeper_workspace_memory_read; model_proposed '
                         'not_performed not_checked_against_current_memory.')
            fragment = template
            for key, value in descriptor.items():
                fragment = fragment.replace('{{' + key + '}}', value)
                fragment = fragment.replace('{{ ' + key + ' }}', value)

            paths = []
            authentication_errors = []
            counts = {'health': 0, 'prompts': 0}

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *_):
                    pass

                def do_GET(self):
                    if self.headers.get('Authorization') != 'Bearer ' + TOKEN:
                        authentication_errors.append(self.path)
                        self.send_error(401)
                        return
                    paths.append(self.path)
                    if self.path == '/health?full=1':
                        counts['health'] += 1
                        after = counts['health'] > 1
                        instance = 'same-instance'
                        if case == 'null_instance':
                            instance = None
                        elif case == 'identity_changed' and after:
                            instance = 'changed-instance'
                        value = {
                            'status': 'degraded' if case == 'degraded_health' and after else 'ok',
                            'build': {
                                'binary_commit': COMMIT,
                                'executable_sha256': BINARY,
                                'runtime_instance_id': instance,
                            },
                            'paths': {
                                'effective_base_path': str(base / 'changed')
                                if case == 'base_changed' and after else str(base),
                                'effective_masc_root': str(base / '.masc'),
                            },
                        }
                    elif self.path == '/api/v1/prompts':
                        counts['prompts'] += 1
                        effective = template
                        if case == 'prompt_changed' and counts['prompts'] > 1:
                            effective += ' changed'
                        value = {'prompts': [{
                            'key': 'keeper.context.workspace_memory.available',
                            'effective': effective,
                            'source': 'override' if case == 'valid_override' else 'default',
                        }]}
                    elif self.path == '/api/v1/dashboard/workspace-memory-proposals?id=' + proposal_id:
                        value = {'id': proposal_id, 'proposal': proposal,
                                 'semantic_verification': 'not_performed'}
                    elif self.path in ['/api/v1/keepers/' + name + '/config' for name in KEEPERS]:
                        assembled = 'other context\n' + fragment
                        if case == 'scattered_markers':
                            assembled = ' '.join([
                                proposal_id, 'c' * 64, 'keeper_workspace_memory_read',
                                'model_proposed', 'not_performed', 'not_checked_against_current_memory',
                            ])
                        elif case == 'duplicate_fragment':
                            assembled += '\n' + fragment
                        value = {
                            'name': self.path.split('/')[4],
                            'prompt': {
                                'assembled_system_prompt': assembled,
                                'unified_user_message_preview': proposal_id
                                if case == 'persistent_leak' else 'stable-user',
                                'effective_system_prompt': 'stable-system',
                            },
                        }
                    else:
                        self.send_error(404)
                        return
                    if case == 'credential_echo':
                        value['echo'] = TOKEN
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps(value).encode())

            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            output = base / 'evidence'
            argv = [sys.executable, str(SCRIPT),
                    '--base-url', f'http://127.0.0.1:{server.server_port}',
                    '--base-path', str(base), '--token-file', str(token_file),
                    '--expected-commit', COMMIT, '--expected-binary-sha256', BINARY,
                    '--output', str(output)]
            for keeper in KEEPERS:
                argv.extend(['--keeper', keeper])
            try:
                process = subprocess.run(argv, capture_output=True, text=True, timeout=20)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()

            receipt = json.loads((output / 'receipt.json').read_text())
            self.assertFalse(authentication_errors)
            self.assertNotIn(TOKEN, process.stdout + process.stderr)
            for artifact in output.iterdir():
                self.assertNotIn(TOKEN.encode(), artifact.read_bytes(), artifact.name)
            hashes = json.loads((output / 'sha256.json').read_text())
            for name, digest in hashes.items():
                self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)
            self.assertEqual(receipt['semantic_verification'], 'not_performed')
            self.assertEqual(receipt['actual_keeper_dispatch'], 'not_measured')
            self.assertEqual(receipt['keeper_adoption'], 'not_measured')
            self.assertFalse(receipt['runtime_mutation'])
            if expected_error is None:
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertEqual(receipt['status'], 'passed')
                self.assertEqual(receipt['keepers'], list(KEEPERS))
                self.assertEqual([path for path in paths if path.endswith('/config')],
                                 ['/api/v1/keepers/' + name + '/config' for name in KEEPERS])
                self.assertEqual(counts, {'health': 2, 'prompts': 2})
            else:
                self.assertEqual(process.returncode, 1, process.stderr)
                self.assertEqual(receipt['status'], 'failed')
                self.assertIn(expected_error, receipt['error'])
            if case == 'credential_echo':
                self.assertFalse((output / 'health-before.response.raw').exists())


def scenario_test(case, expected_error):
    def test(self):
        self.run_case(case, expected_error)
    return test


for case, expected_error in CASES.items():
    setattr(InstalledDiscoveryProbeTests, 'test_' + case, scenario_test(case, expected_error))


if __name__ == '__main__':
    unittest.main()
