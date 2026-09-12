"""Offline evidence cases; these are not installed Keeper acceptance."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'inspect-workspace-memory-turn.py'
PROPOSAL = 'a' * 64
CONTEXT = 'b' * 64
FRAGMENT = f'{PROPOSAL} {CONTEXT} keeper_workspace_memory_read model_proposed not_performed not_checked_against_current_memory'
REF = 'trace-example#2'


def fixture():
    record = {'keeper': 'editor', 'trace_id': 'trace-example', 'absolute_turn': 2,
              'turn_ref': REF, 'turn_kind': 'autonomous', 'finish_reason': 'completed',
              'request_runtime_profile': 'local.model', 'request_body_bytes': 123,
              'raw_trace_run_ref': {'worker_run_id': 'worker-1', 'start_seq': 1, 'end_seq': 4,
                                    'session_id': 'trace-example', 'agent_name': 'agent_core-local.model',
                                    'path': '/captured/raw-trace.jsonl'}}
    provider = {'schema': 'masc.resolved-provider-input.v1',
                **{k: record[k] for k in ('keeper', 'trace_id', 'absolute_turn', 'turn_ref')},
                'runtime_profile': 'local.model',
                'wire': {'capture_id': 'worker-1', 'body_bytes': 123,
                         'phase': ['Pre_dispatch_serialization']},
                'system_prompt': {'text': 'keeper system 한글',
                                  'bytes': len('keeper system 한글'.encode('utf-8')),
                                  'sha256': hashlib.sha256('keeper system 한글'.encode('utf-8')).hexdigest()},
                'messages': [{'role': 'user', 'content': {'role': 'user', 'content_blocks':
                             [{'type': 'text', 'text': FRAGMENT}]}}]}
    common = {'trace_version': 4, 'worker_run_id': 'worker-1', 'session_id': 'trace-example',
              'agent_name': 'agent_core-local.model'}
    invocation = {'tool_name': 'keeper_workspace_memory_read', 'tool_use_id': 'call-1',
                  'tool_turn': 1, 'tool_planned_index': 0}
    trace = [{**common, 'seq': 1, 'record_type': 'run_started'},
             {**common, **invocation, 'seq': 2, 'record_type': 'tool_execution_started',
              'tool_input': {'id': PROPOSAL}},
             {**common, **invocation, 'seq': 3, 'record_type': 'tool_execution_finished',
              'tool_result': 'opaque result or retained artifact reference', 'tool_error': False},
             {**common, 'seq': 4, 'record_type': 'run_finished', 'stop_reason': 'Types.EndTurn'}]
    return {'keeper': 'editor', 'entries': [{'record': record}]}, provider, trace


class TurnInspectorTests(unittest.TestCase):
    def invoke(self, mutate=None):
        with tempfile.TemporaryDirectory(prefix='masc-turn-inspector-') as directory:
            root = Path(directory)
            turns, provider, trace = copy.deepcopy(fixture())
            if mutate:
                mutate(turns, provider, trace)
            files = {'turn-records': json.dumps(turns), 'provider-input': json.dumps(provider),
                     'raw-trace': '\n'.join(json.dumps(r) for r in trace),
                     'publication': json.dumps({'schema': 'workspace.memory.publication.v1',
                                                'proposal_id': PROPOSAL, 'context_sha256': CONTEXT}),
                     'fragment': FRAGMENT}
            command = [sys.executable, str(SCRIPT), '--keeper', 'editor', '--turn-ref', REF,
                       '--output', str(root / 'output')]
            for name, value in files.items():
                path = root / name
                path.write_text(value)
                command += ['--' + name, str(path)]
            result = subprocess.run(command, capture_output=True, text=True)
            receipt = json.loads((root / 'output/receipt.json').read_text())
            self.assertEqual(receipt['semantic_adoption'], 'not_verified')
            self.assertEqual(set(receipt['source_sha256']),
                             {'turn_records', 'provider_input', 'raw_trace', 'publication', 'fragment'})
            return result, receipt

    def test_matching_input_and_read_are_observations_not_adoption(self):
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(receipt['status'], 'inspected')
        self.assertEqual(receipt['system_prompt_integrity'], 'verified')
        self.assertEqual(receipt['message_artifact_integrity'], 'not_verified')
        self.assertEqual(receipt['complete_fragment_occurrences_in_captured_input'], 1)
        self.assertEqual(receipt['exact_id_read_invocations'][0]['completion'], 'success')
        self.assertEqual(receipt['exact_id_read_invocations'][0]['proposal_result'], 'not_examined')

    def test_absent_and_duplicate_fragment_are_counts_not_success(self):
        for text, count in [('no discovery', 0), (FRAGMENT * 2, 2)]:
            with self.subTest(count=count):
                _, receipt = self.invoke(lambda t, p, r: p['messages'][0]['content']['content_blocks'][0].update(text=text))
                self.assertEqual(receipt['complete_fragment_occurrences_in_captured_input'], count)

    def test_wrong_proposal_is_not_a_read(self):
        _, receipt = self.invoke(lambda t, p, r: r[1].update(tool_input={'id': 'c' * 64}))
        self.assertEqual(receipt['exact_id_read_invocations'], [])

    def test_failed_read_is_not_success(self):
        _, receipt = self.invoke(lambda t, p, r: r[2].update(tool_error=True))
        self.assertEqual(receipt['exact_id_read_invocations'][0]['completion'], 'error')

    def test_missing_completion_remains_missing(self):
        _, receipt = self.invoke(lambda t, p, r: r[2].update(record_type='hook_invoked'))
        self.assertEqual(receipt['exact_id_read_invocations'][0]['completion'], 'not_recorded')

    def test_duplicate_read_start_coordinates_are_rejected(self):
        def duplicate_start(turns, provider, trace):
            trace.insert(2, copy.deepcopy(trace[1]))
            for sequence, row in enumerate(trace, 1):
                row['seq'] = sequence
            turns['entries'][0]['record']['raw_trace_run_ref']['end_seq'] = len(trace)
        result, receipt = self.invoke(duplicate_start)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt['status'], 'invalid_evidence')
        self.assertEqual(receipt['error'], 'Duplicate tool invocation coordinates')

    def test_collision_before_proposal_or_tool_filter_is_rejected(self):
        for first in (True, False):
            for changed in ({'tool_input': {'id': 'c' * 64}}, {'tool_name': 'other_tool'}):
                with self.subTest(first=first, changed=changed):
                    def add_collision(turns, provider, trace):
                        collision = copy.deepcopy(trace[1])
                        collision.update(changed)
                        trace.insert(1 if first else 2, collision)
                        for sequence, row in enumerate(trace, 1):
                            row['seq'] = sequence
                        turns['entries'][0]['record']['raw_trace_run_ref']['end_seq'] = len(trace)
                    result, receipt = self.invoke(add_collision)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(receipt['error'], 'Duplicate tool invocation coordinates')

    def test_system_prompt_bytes_and_hash_are_verified(self):
        changes = {
            'altered_text': lambda t, p, r: p['system_prompt'].update(text='changed prompt'),
            'wrong_bytes': lambda t, p, r: p['system_prompt'].update(bytes=1),
            'character_count_not_utf8_bytes': lambda t, p, r: p['system_prompt'].update(bytes=len(p['system_prompt']['text'])),
            'wrong_hash': lambda t, p, r: p['system_prompt'].update(sha256='c' * 64),
            'missing_hash': lambda t, p, r: p['system_prompt'].pop('sha256'),
        }
        for name, change in changes.items():
            with self.subTest(name=name):
                result, receipt = self.invoke(change)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(receipt['status'], 'invalid_evidence')
        result, receipt = self.invoke(lambda t, p, r: p.update(system_prompt=None))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(receipt['system_prompt_integrity'], 'not_present')

    def test_run_reference_and_every_trace_row_identity_are_checked(self):
        changes = {
            'reference_session': lambda t, p, r: t['entries'][0]['record']['raw_trace_run_ref'].update(session_id='other'),
            'reference_agent': lambda t, p, r: t['entries'][0]['record']['raw_trace_run_ref'].update(agent_name='other'),
            'missing_reference_session': lambda t, p, r: t['entries'][0]['record']['raw_trace_run_ref'].pop('session_id'),
            'missing_reference_agent': lambda t, p, r: t['entries'][0]['record']['raw_trace_run_ref'].pop('agent_name'),
            'empty_reference_agent': lambda t, p, r: t['entries'][0]['record']['raw_trace_run_ref'].update(agent_name=''),
            'missing_trace_agent': lambda t, p, r: r[1].pop('agent_name'),
            'consistent_wrong_session': lambda t, p, r: [row.update(session_id='other') for row in r],
            'consistent_wrong_agent': lambda t, p, r: [row.update(agent_name='other') for row in r],
        }
        for index in range(4):
            for field in ('session_id', 'agent_name'):
                changes[f'{field}_row_{index}'] = lambda t, p, r, i=index, f=field: r[i].update({f: 'other'})
        for name, change in changes.items():
            with self.subTest(name=name):
                result, receipt = self.invoke(change)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(receipt['status'], 'invalid_evidence')

    def test_identity_and_incomplete_evidence_are_rejected(self):
        changes = {
            'keeper': lambda t, p, r: p.update(keeper='other'),
            'capture': lambda t, p, r: p['wire'].update(capture_id='other'),
            'runtime': lambda t, p, r: p.update(runtime_profile='other'),
            'trace': lambda t, p, r: r[1].update(worker_run_id='other'),
            'gap': lambda t, p, r: r.pop(1),
            'incomplete': lambda t, p, r: r[-1].update(record_type='hook_invoked'),
            'duplicate_turn': lambda t, p, r: t['entries'].append(t['entries'][0]),
            'wrong_finish': lambda t, p, r: r[2].update(tool_name='other'),
        }
        for name, change in changes.items():
            with self.subTest(name=name):
                result, receipt = self.invoke(change)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(receipt['status'], 'invalid_evidence')


if __name__ == '__main__':
    unittest.main()
