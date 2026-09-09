"""Exercise the standalone curator CLI with a local model HTTP fixture.
Run: uv run --with jsonschema python -m unittest discover -s scripts/tests -p test_workspace_memory_curator.py
"""
import http.server
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CuratorScenario(unittest.TestCase):
    def run_curator(self, proposal, context=None, response_fields=None, raw_response=None, http_status=200):
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                value = {'models': [{'name': 'local-test', 'digest': 'fixture-digest'}]} if self.path == '/api/tags' else {'version': 'fixture'}
                self.wfile.write(json.dumps(value).encode())

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                assert request['model'] == 'local-test'
                assert request['stream'] is True
                assert request['format']['required'] == ['shared_claims', 'conflicts', 'excluded']
                self.send_response(http_status)
                self.end_headers()
                value = {'done': True, 'message': {'content': json.dumps(proposal)}, **(response_fields or {})}
                self.wfile.write(raw_response if raw_response is not None else json.dumps(value).encode())

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            context_path = ROOT / 'docs/evidence/2026-09-10-workspace-memory-curator/input.json'
            if context is not None:
                context_path = Path(directory) / 'input.json'
                context_path.write_text(json.dumps(context))
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/curate-workspace-memory.py'),
                    '--context', str(context_path),
                    '--endpoint', f'http://127.0.0.1:{server.server_port}', '--model', 'local-test',
                    '--output', str(output)], capture_output=True, text=True)
                receipt = json.loads((output / 'receipt.json').read_text())
                artifact = json.loads((output / 'proposal.json').read_text()) if (output / 'proposal.json').exists() else None
                captured = json.loads((output / 'request.json').read_text())
                self.captures = {path.name: path.read_bytes() for path in output.iterdir()}
                return result, receipt, artifact, captured
            finally:
                server.shutdown()
                server.server_close()
                thread.join()

    def test_proposal_preserves_revision_and_conflict_provenance(self):
        proposal = {'shared_claims': [{'claim': 'Analyst corrected M to 21 seconds.', 'source_ids': ['s3', 's4']}],
            'conflicts': [{'description': 'PDF generation claim contradicted by reviewer byte observation.', 'source_ids': ['s1', 's2']}], 'excluded': []}
        result, receipt, artifact, captured = self.run_curator(proposal)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(receipt['status'], 'proposed')
        self.assertEqual(receipt['semantic_verification'], 'not_performed')
        self.assertEqual(artifact['status'], 'model_proposed')
        self.assertEqual(artifact['proposal'], proposal)
        self.assertEqual([source['keeper_id'] for source in artifact['sources']], ['writer', 'reviewer', 'analyst', 'analyst'])
        self.assertTrue(all(len(source['snapshot_sha256']) == 64 for source in artifact['sources']))
        self.assertNotIn('expected', captured['messages'][1]['content'])

    def test_missing_source_disposition_does_not_create_proposal(self):
        result, receipt, artifact, _ = self.run_curator({'shared_claims': [], 'conflicts': [], 'excluded': []})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt['status'], 'failed')
        self.assertIn('Source coverage mismatch', receipt['error'])
        self.assertIsNone(artifact)

    def test_retractions_and_invalidations_are_citable_without_current_facts(self):
        context = json.loads((ROOT / 'docs/evidence/2026-09-10-workspace-memory-curator/input.json').read_text())
        keeper = context['keepers'][0]
        snapshot = keeper['ordinary']['snapshot']
        removed = snapshot['facts'].pop()
        snapshot.update(revision=2, updated_at=25, change={
            'added': [], 'removed': [removed], 'retained': 0,
            'invalidated': [{'fact': removed, 'missing_premise_ids': ['premise-a']}],
        })
        keeper['source_bound'] = {'status': 'available', 'snapshot': {
            'revision': 3, 'updated_at': 26, 'trace_id': 'revalidation', 'facts': [],
            'invalidations': [{'source_path': 'report.pdf', 'invalidated_at': 26, 'reason': 'content_changed'}],
        }}
        proposal = {'shared_claims': [], 'conflicts': [{
            'description': 'The report claim was retracted and the file binding invalidated.',
            'source_ids': ['s1', 's2'],
        }], 'excluded': [{'source_id': source, 'reason': 'Unrelated to this report correction.'}
                        for source in ('s3', 's4', 's5')]}
        result, receipt, artifact, captured = self.run_curator(proposal, context=context)
        self.assertEqual(result.returncode, 0, result.stderr)
        model_input = json.loads(captured['messages'][1]['content'])
        self.assertEqual(model_input['snapshots'], artifact['snapshots'])
        self.assertTrue(all(len(row['snapshot_sha256']) == 64 for row in artifact['snapshots']))
        self.assertEqual(artifact['snapshots'][0]['metadata']['updated_at'], 25)
        self.assertEqual(artifact['snapshots'][0]['metadata']['change'], snapshot['change'])
        self.assertEqual(artifact['sources'][0]['evidence_path'], ['change'])
        self.assertEqual(artifact['sources'][1]['evidence_path'], ['invalidations', 0])
        self.assertEqual(artifact['sources'][1]['snapshot_id'], artifact['snapshots'][1]['snapshot_id'])
        self.assertEqual(receipt['source_count'], 5)

    def test_remote_model_response_is_refused_and_preserved(self):
        for field in ('remote_host', 'remote_model'):
            with self.subTest(field=field):
                result, receipt, artifact, _ = self.run_curator({}, response_fields={field: 'remote'})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('remote model response', receipt['error'])
                self.assertIsNone(artifact)
                self.assertEqual(json.loads(self.captures['chat.response.raw'])[field], 'remote')
                self.assertEqual(json.loads(self.captures['chat.http.json'])['status'], 200)

    def test_streamed_text_is_joined_only_after_terminal_event(self):
        proposal = {'shared_claims': [], 'conflicts': [],
                    'excluded': [{'source_id': f's{index}', 'reason': '검토 필요'} for index in range(1, 5)]}
        content = json.dumps(proposal, ensure_ascii=False)
        split = len(content) // 2
        events = [
            {'done': False, 'message': {'thinking': 'consider sources'}},
            {'done': False, 'message': {'content': content[:split]}},
            {'done': True, 'message': {'content': content[split:]}, 'eval_count': 42},
        ]
        raw = b''.join(json.dumps(event, ensure_ascii=False).encode() + b'\n' for event in events)
        result, receipt, artifact, _ = self.run_curator({}, raw_response=raw)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(artifact['proposal'], proposal)
        self.assertEqual(self.captures['chat.response.raw'], raw)
        self.assertEqual(receipt['eval_count'], 42)
        progress = json.loads(self.captures['progress.json'])
        self.assertEqual(progress['phase'], 'proposed')
        for key, value in {'chunks': 3, 'content_characters': len(content),
                           'thinking_characters': len('consider sources')}.items():
            self.assertEqual(progress[key], value)
            self.assertEqual(receipt[key], value)

    def test_stream_eof_cannot_turn_partial_output_into_a_proposal(self):
        raw = json.dumps({'done': False, 'message': {'content': '{}'}}).encode() + b'\n'
        result, receipt, artifact, _ = self.run_curator({}, raw_response=raw)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('without a terminal event', receipt['error'])
        self.assertIsNone(artifact)
        self.assertEqual(self.captures['chat.response.raw'], raw)
        progress = json.loads(self.captures['progress.json'])
        self.assertEqual(progress['phase'], 'failed')
        for key, value in {'chunks': 1, 'content_characters': 2, 'thinking_characters': 0}.items():
            self.assertEqual(progress[key], value)
            self.assertEqual(receipt[key], value)

    def test_failed_http_and_malformed_json_keep_original_response_bytes(self):
        for status in (200, 503):
            with self.subTest(status=status):
                raw = b'upstream unavailable; not JSON\xff'
                result, receipt, artifact, _ = self.run_curator({}, raw_response=raw, http_status=status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(receipt['status'], 'failed')
                self.assertIsNone(artifact)
                self.assertEqual(self.captures['chat.response.raw'], raw)
                self.assertEqual(json.loads(self.captures['chat.http.json'])['status'], status)


if __name__ == '__main__':
    unittest.main()
