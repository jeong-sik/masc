"""CLI HTTP scenarios for per-Keeper curation, synthesis and bound resume."""
from contextlib import contextmanager
import http.server
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/curate-workspace-memory.py'
CONTEXT = ROOT / 'docs/evidence/2026-09-10-workspace-memory-curator/input.json'


@contextmanager
def scenario():
    calls = []
    controls = {'failure': None, 'model_digest': 'fixture-digest', 'ps_status': 200,
        'block_stage': None, 'entered': threading.Event(), 'release': threading.Event()}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            status = controls['ps_status'] if self.path == '/api/ps' else 200
            self.send_response(status)
            self.end_headers()
            if self.path == '/api/tags':
                body = {'models': [{'name': 'local-test', 'digest': controls['model_digest']}]}
            elif self.path == '/api/ps':
                body = {'models': []}
            else:
                body = {'version': 'fixture'}
            self.wfile.write(json.dumps(body).encode())

        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            value = json.loads(payload['messages'][1]['content'])
            stage = 'synthesis' if 'keeper_proposals' in value else value['snapshots'][0]['keeper_id']
            calls.append({'stage': stage, 'payload': payload, 'input': value})
            if controls['block_stage'] == stage:
                controls['entered'].set()
                controls['release'].wait()
            if controls['failure'] == stage:
                self.send_response(503)
                self.end_headers()
                self.wfile.write(b'fixture stage failure')
                return
            if stage == 'synthesis':
                last_message = json.loads(payload['messages'][-1]['content'])
                if last_message.get('kind') != 'source_evidence':
                    ids = [row['source_id'] for row in value['source_index'] if row['keeper_id'] in ('writer', 'reviewer')]
                    result = {'action': 'read_sources', 'source_ids': ids if controls['failure'] != 'unknown_source' else ['unknown']}
                else:
                    claims = [row['fact']['claim'] for row in last_message['sources'] if 'fact' in row]
                    assert 'Report R was generated as PDF.' in claims
                    assert 'Report R contains plain Markdown bytes; PDF generation failed.' in claims
                    result = {'action': 'final', 'proposal': {
                        'shared_claims': [{'claim': 'Analyst corrected M to 21 seconds.',
                            'source_ids': [row['source_id'] for row in value['source_index'] if row['keeper_id'] == 'analyst']}],
                        'conflicts': [{'description': 'Writer and reviewer disagree about PDF bytes.',
                            'source_ids': [row['source_id'] for row in value['source_index'] if row['keeper_id'] in ('writer', 'reviewer')]}], 'excluded': []}}
                    if controls['failure'] == 'coverage':
                        result['proposal']['conflicts'] = []
            elif stage == 'writer':
                # The group hides the assertion in an exclusion, forcing synthesis
                # to retrieve the original bytes before it can report a conflict.
                result = {'shared_claims': [], 'conflicts': [], 'excluded': [
                    {'source_id': row['source_id'], 'reason': 'Not relevant to this group summary'} for row in value['sources']]}
            else:
                result = {'shared_claims': [{'claim': 'Keeper observation: ' + stage,
                    'source_ids': [source['source_id'] for source in value['sources']]}], 'conflicts': [], 'excluded': []}
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({'done': True, 'message': {'content': json.dumps(result)},
                'prompt_eval_count': 50, 'eval_count': 25}).encode() + b'\n')

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        def run(name, resume=None, context=CONTEXT, background=False):
            output = root / name
            argv = [sys.executable, str(SCRIPT), '--context', str(context), '--workspace-pass',
                '--endpoint', f'http://127.0.0.1:{server.server_port}', '--model', 'local-test', '--output', str(output)]
            if resume is not None:
                argv += ['--resume-from', str(resume)]
            if background:
                return subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True), output
            result = subprocess.run(argv, capture_output=True, text=True)
            return result, output, json.loads((output / 'receipt.json').read_text())
        try:
            yield run, calls, controls, root
        finally:
            controls['release'].set()
            server.shutdown()
            server.server_close()
            thread.join()


class WorkspacePass(unittest.TestCase):
    def test_synthesis_preserves_all_original_evidence_and_cross_keeper_conflicts(self):
        with scenario() as (run, calls, controls, _):
            controls['ps_status'] = 404  # Observation unavailability must not gate curation.
            result, output, receipt = run('complete')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([row['stage'] for row in calls], ['writer', 'reviewer', 'analyst', 'synthesis', 'synthesis'])
            self.assertEqual([[source['source_id'] for source in row['input']['sources']] for row in calls[:3]],
                [['s1'], ['s2'], ['s3', 's4']])
            self.assertTrue(all(row['payload']['truncate'] is False and row['payload']['shift'] is False for row in calls))
            synthesis = calls[-1]['input']
            self.assertEqual([row['keeper_id'] for row in synthesis['keeper_proposals']], ['writer', 'reviewer', 'analyst'])
            self.assertEqual([row['source_id'] for row in synthesis['source_index']], ['s1', 's2', 's3', 's4'])
            artifact = json.loads((output / 'proposal.json').read_text())
            original = json.loads((output / 'sources.json').read_text())
            for key in ('sources', 'gaps', 'snapshots'):
                self.assertEqual(artifact[key], original[key])
            self.assertEqual(artifact['proposal']['conflicts'][0]['source_ids'], ['s1', 's2'])
            self.assertEqual(receipt['source_count'], 4)
            self.assertEqual(receipt['semantic_verification'], 'not_performed')
            self.assertEqual(receipt['measurement_scope'], 'final_synthesis_completion_request')
            self.assertEqual(receipt['workspace_pass']['resumed_group_ids'], [])
            lookup = json.loads(calls[-1]['payload']['messages'][-1]['content'])
            self.assertEqual(lookup['kind'], 'source_evidence')
            self.assertEqual(lookup['sources'], [row for row in original['sources'] if row['source_id'] in ('s1', 's2')])
            self.assertEqual(lookup['snapshots'], [row for row in original['snapshots'] if row['keeper_id'] in ('writer', 'reviewer')])
            self.assertEqual(synthesis['keeper_proposals'][0]['proposal']['shared_claims'], [])
            first_step = json.loads((output / 'synthesis/receipt.json').read_text())['steps'][0]['id']
            self.assertEqual(json.loads((output / 'synthesis' / first_step / 'ps-before.http.json').read_text())['status'], 404)
            self.assertEqual(json.loads((output / 'synthesis' / first_step / 'evidence-lookup.json').read_text()), lookup)

    def test_groups_metadata_evidence_by_snapshot_owner_and_preserves_gaps_only_keeper(self):
        with scenario() as (run, calls, _, root):
            context = json.loads(CONTEXT.read_text())
            writer = context['keepers'][0]['ordinary']['snapshot']
            writer['change'] = {'added': [], 'removed': [writer['facts'][0]], 'invalidated': [], 'retained': 0}
            context['keepers'].append({'keeper_id': 'empty-keeper', 'ordinary': {'status': 'missing'},
                'source_bound': {'status': 'unavailable', 'detail': 'fixture read failure'}})
            path = root / 'with-metadata.json'
            path.write_text(json.dumps(context))
            result, output, receipt = run('metadata', context=path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([row['stage'] for row in calls], ['writer', 'reviewer', 'analyst', 'synthesis', 'synthesis'])
            metadata_source = calls[0]['input']['sources'][1]
            self.assertEqual(metadata_source['source_id'], 's2')
            self.assertEqual(metadata_source['evidence_path'], ['change'])
            self.assertNotIn('keeper_id', metadata_source)
            self.assertEqual(calls[-1]['input']['source_index'][1]['keeper_id'], 'writer')
            self.assertEqual(calls[-1]['input']['keeper_proposals'][-1], {
                'keeper_id': 'empty-keeper', 'proposal': {'shared_claims': [], 'conflicts': [], 'excluded': []}})
            self.assertEqual(receipt['workspace_pass']['group_count'], 4)
            artifact = json.loads((output / 'proposal.json').read_text())
            self.assertEqual(len(artifact['sources']), 5)
            self.assertEqual(artifact['gaps'][-1]['observation']['detail'], 'fixture read failure')

    def test_partial_group_failure_resumes_only_unfinished_groups(self):
        with scenario() as (run, calls, controls, _):
            controls['failure'] = 'reviewer'
            failed, previous, receipt = run('failed')
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(receipt['status'], 'failed')
            self.assertFalse((previous / 'proposal.json').exists())
            self.assertFalse((previous / 'synthesis').exists())
            plan = json.loads((previous / 'plan.json').read_text())
            first = plan['groups'][0]['id']
            original_response = (previous / 'groups' / first / 'chat.response.raw').read_bytes()
            controls['failure'] = None
            result, output, receipt = run('resumed', resume=previous)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([row['stage'] for row in calls], ['writer', 'reviewer', 'reviewer', 'analyst', 'synthesis', 'synthesis'])
            self.assertEqual(receipt['workspace_pass']['resumed_group_ids'], [first])
            self.assertEqual((output / 'groups' / first / 'chat.response.raw').read_bytes(), original_response)
            self.assertEqual((previous / 'groups' / first / 'chat.response.raw').read_bytes(), original_response)
            self.assertEqual(json.loads((output / 'groups' / first / 'resume.json').read_text())['status'], 'reused_completed')

    def test_failed_synthesis_never_publishes_partial_result_and_reuses_completed_groups(self):
        with scenario() as (run, calls, controls, _):
            controls['failure'] = 'coverage'
            result, previous, receipt = run('bad-synthesis')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(receipt['status'], 'failed')
            self.assertFalse((previous / 'proposal.json').exists())
            self.assertIn('Source coverage mismatch', receipt['error'])
            controls['failure'] = None
            result, output, receipt = run('retry-synthesis', resume=previous)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([row['stage'] for row in calls], ['writer', 'reviewer', 'analyst', 'synthesis', 'synthesis', 'synthesis', 'synthesis'])
            self.assertEqual(len(receipt['workspace_pass']['resumed_group_ids']), 3)
            self.assertTrue((output / 'proposal.json').exists())

    def test_resume_rejects_changed_context_or_model_without_calling_inference(self):
        with scenario() as (run, calls, controls, root):
            result, previous, _ = run('complete')
            self.assertEqual(result.returncode, 0, result.stderr)
            count = len(calls)
            controls['model_digest'] = 'different-model-bytes'
            result, output, receipt = run('changed-model', resume=previous)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('binding does not match', receipt['error'])
            controls['model_digest'] = 'fixture-digest'
            changed = root / 'changed.json'
            changed.write_bytes(CONTEXT.read_bytes() + b'\n')
            result, output, receipt = run('changed-context', resume=previous, context=changed)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('binding does not match', receipt['error'])
            self.assertEqual(len(calls), count)
            self.assertFalse((output / 'proposal.json').exists())

    def test_unknown_evidence_lookup_does_not_create_final_proposal(self):
        with scenario() as (run, calls, controls, _):
            controls['failure'] = 'unknown_source'
            result, output, receipt = run('unknown-source')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('unknown original source IDs', receipt['error'])
            self.assertEqual([row['stage'] for row in calls], ['writer', 'reviewer', 'analyst', 'synthesis'])
            self.assertFalse((output / 'proposal.json').exists())

    def test_resume_cannot_duplicate_a_live_owned_run(self):
        with scenario() as (run, calls, controls, _):
            controls['block_stage'] = 'writer'
            process, previous = run('live-owner', background=True)
            try:
                self.assertTrue(controls['entered'].wait(10), 'fixture inference did not start')
                self.assertIsNone(process.poll())
                result, output, receipt = run('blocked-resume', resume=previous)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('currently owned', receipt['error'])
                self.assertEqual([row['stage'] for row in calls], ['writer'])
                self.assertIsNone(process.poll())
                self.assertFalse((output / 'proposal.json').exists())
            finally:
                controls['release'].set()
                stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout)['status'], 'proposed')

    def test_resume_rejects_tampered_completed_group(self):
        with scenario() as (run, calls, _, _):
            result, previous, _ = run('complete')
            self.assertEqual(result.returncode, 0, result.stderr)
            first = json.loads((previous / 'plan.json').read_text())['groups'][0]['id']
            saved = previous / 'groups' / first / 'result.json'
            changed = json.loads(saved.read_text())
            changed['excluded'][0]['reason'] = 'Tampered exclusion'
            saved.write_text(json.dumps(changed))
            result, output, receipt = run('tampered', resume=previous)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('evidence does not match', receipt['error'])
            self.assertEqual(len(calls), 5)
            self.assertFalse((output / 'proposal.json').exists())


if __name__ == '__main__':
    unittest.main()
