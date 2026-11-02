#!/usr/bin/env python3
"""Decision tests for the first-turn checkpoint evidence consumer."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/keeper-first-turn-smoke.py'
SPEC = importlib.util.spec_from_file_location('keeper_first_turn_smoke', SCRIPT)
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class CheckpointProofTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='checkpoint-proof-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.binary = self.base / 'masc'
        self.binary.write_bytes(b'pinned executable')
        proof = {'marker': 'marker', 'cwd': '/sandbox', 'hostname': 'guest', 'uid': 1000}
        self.fixture = SimpleNamespace(
            checkpoint_binary=str(self.binary), checkpoint_binary_sha256=smoke.file_sha256(self.binary),
            checkpoint_keeper='keeper', call_id='call', tool_name='Execute', final='final',
            marker='marker', proof=proof, checkpoint_env={'HOME': str(self.base)})
        self.path = self.base / '.masc/traces/trace/trace.json'
        self.messages = [
            {'role': 'assistant', 'content': [
                {'type': 'tool_use', 'id': 'call', 'name': 'Execute', 'input': {}}]},
            {'role': 'tool', 'content': [
                {'type': 'tool_result', 'tool_use_id': 'call', 'is_error': False,
                 'content': json.dumps(proof)}]},
            {'role': 'assistant', 'content': [{'type': 'text', 'text': 'final'}]},
        ]
        self.inspection = {
            'schema': 'masc.checkpoint-inspection.v1', 'status': 'available',
            'keeper': 'keeper', 'trace_id': 'trace', 'canonical_path': str(self.path),
            'reference': {'trace_id': 'trace', 'turn_count': 1, 'content_sha256': 'a' * 64},
            'history_boundary': {'closed_messages': 3, 'open_messages': 0},
            'checkpoint': {'session_id': 'trace', 'turn_count': 1, 'messages': self.messages},
        }

    def read(self, inspection=None, *, returncode=0, stderr=''):
        result = subprocess.CompletedProcess([], returncode, json.dumps(
            self.inspection if inspection is None else inspection), stderr)
        with mock.patch.object(smoke.subprocess, 'run', return_value=result) as invoke:
            answer = smoke.checkpoint_proof(self.base, self.fixture, 7.5)
        self.assertGreater(invoke.call_args.kwargs['timeout'], 0)
        self.assertLessEqual(invoke.call_args.kwargs['timeout'], 7.5)
        self.assertEqual(invoke.call_args.kwargs['env'], self.fixture.checkpoint_env)
        self.assertEqual(invoke.call_args.args[0][1], 'inspect-checkpoint')
        return answer

    def test_matching_call_result_and_final(self):
        path, data = self.read()
        self.assertEqual(path, self.path)
        self.assertEqual(data['reference']['content_sha256'], 'a' * 64)

    def test_final_must_be_closed_but_a_later_open_turn_is_allowed(self):
        open_final = copy.deepcopy(self.inspection)
        open_final['history_boundary'] = {'closed_messages': 2, 'open_messages': 1}
        self.assertIsNone(self.read(open_final))
        later_open = copy.deepcopy(self.inspection)
        later_open['checkpoint']['messages'].append({'role': 'user', 'content': [{'type': 'text', 'text': 'later'}]})
        later_open['history_boundary'] = {'closed_messages': 3, 'open_messages': 1}
        self.assertIsNotNone(self.read(later_open))
        invalid = copy.deepcopy(self.inspection)
        invalid['history_boundary'] = {'closed_messages': 3, 'open_messages': 1}
        with self.assertRaisesRegex(smoke.SmokeError, 'history boundary'):
            self.read(invalid)

    def test_wrong_order_or_result_is_not_evidence(self):
        variants = []
        wrong_id = copy.deepcopy(self.inspection)
        wrong_id['checkpoint']['messages'][1]['content'][0]['tool_use_id'] = 'another-call'
        variants.append(wrong_id)
        failed = copy.deepcopy(self.inspection)
        failed['checkpoint']['messages'][1]['content'][0]['is_error'] = True
        variants.append(failed)
        wrong_proof = copy.deepcopy(self.inspection)
        wrong_proof['checkpoint']['messages'][1]['content'][0]['content'] = json.dumps(
            dict(self.fixture.proof, hostname='other'))
        variants.append(wrong_proof)
        wrong_order = copy.deepcopy(self.inspection)
        wrong_order['checkpoint']['messages'][1:] = list(reversed(wrong_order['checkpoint']['messages'][1:]))
        variants.append(wrong_order)
        nested = copy.deepcopy(self.inspection)
        nested['checkpoint']['messages'][0]['content'][0] = {
            'type': 'tool_use', 'id': 'other', 'name': 'Other',
            'input': {'id': 'call', 'name': 'Execute'}}
        variants.append(nested)
        for variant in variants:
            with self.subTest(variant=variant):
                self.assertIsNone(self.read(variant))

    def test_missing_is_pending_but_invalid_inspection_fails(self):
        self.assertIsNone(self.read({'schema': self.inspection['schema'], 'keeper': 'keeper',
                                     'trace_id': 'trace', 'status': 'not_found'}))
        with self.assertRaisesRegex(smoke.SmokeError, 'inspection failed'):
            self.read(returncode=1, stderr='invalid checkpoint object')
        wrong_trace = copy.deepcopy(self.inspection)
        wrong_trace['reference']['trace_id'] = 'another-trace'
        with self.assertRaisesRegex(smoke.SmokeError, 'invalid reference'):
            self.read(wrong_trace)

    def test_changed_binary_is_rejected(self):
        self.binary.write_bytes(b'another executable')
        with self.assertRaisesRegex(smoke.SmokeError, 'changed before'):
            self.read()

    def test_unsupported_inspector_is_rejected_before_use(self):
        rejected = subprocess.CompletedProcess([], 124, '', 'unknown command')
        with mock.patch.object(smoke.subprocess, 'run', return_value=rejected) as invoke:
            with self.assertRaises(smoke.SmokeError):
                smoke.require_checkpoint_inspector(self.fixture)
        self.assertEqual(invoke.call_args.args[0][1:], ['inspect-checkpoint', '--help'])

    def test_inspector_capability_check_binds_the_pinned_binary(self):
        accepted = subprocess.CompletedProcess([], 0, '', '')
        with mock.patch.object(smoke.subprocess, 'run', return_value=accepted) as invoke:
            smoke.require_checkpoint_inspector(self.fixture)
        invoke.assert_called_once()

        self.binary.write_bytes(b'changed before help')
        with mock.patch.object(smoke.subprocess, 'run') as invoke:
            with self.assertRaisesRegex(smoke.SmokeError, 'before capability check'):
                smoke.require_checkpoint_inspector(self.fixture)
        invoke.assert_not_called()

        self.binary.write_bytes(b'pinned executable')
        def replace_during_help(*_args, **_kwargs):
            self.binary.write_bytes(b'changed during help')
            return accepted
        with mock.patch.object(smoke.subprocess, 'run', side_effect=replace_during_help):
            with self.assertRaisesRegex(smoke.SmokeError, 'during capability check'):
                smoke.require_checkpoint_inspector(self.fixture)

    def test_ssh_restart_uses_the_new_call_and_final(self):
        self.fixture.call_id = 'ssh-restart-call'
        self.fixture.final = 'restart-final'
        self.messages[0]['content'][0]['id'] = self.fixture.call_id
        self.messages[1]['content'][0]['tool_use_id'] = self.fixture.call_id
        self.messages[2]['content'][0]['text'] = self.fixture.final
        self.assertIsNotNone(self.read())

    def test_resume_keeps_the_first_turn_on_the_same_trace(self):
        initial = copy.copy(self.fixture)
        resumed = copy.copy(self.fixture)
        resumed.call_id, resumed.final = 'resumed-call', 'resumed-final'
        later = copy.deepcopy(self.messages)
        later[0]['content'][0]['id'] = resumed.call_id
        later[1]['content'][0]['tool_use_id'] = resumed.call_id
        later[2]['content'][0]['text'] = resumed.final
        data = copy.deepcopy(self.inspection)
        data['checkpoint']['messages'].extend(later)
        smoke.require_checkpoint_resume(data, 'trace', initial, resumed)
        for bad in (dict(data, trace_id='another-trace'),
                    dict(data, checkpoint=dict(data['checkpoint'], messages=later)),
                    dict(data, checkpoint=dict(data['checkpoint'], messages=later + self.messages))):
            with self.subTest(bad=bad), self.assertRaises(smoke.SmokeError):
                smoke.require_checkpoint_resume(bad, 'trace', initial, resumed)

    def test_chat_stream_requires_a_successful_matching_run(self):
        stream = self.base / 'chat.sse'
        run, thread = 'keeper-operation-run-request', 'keeper:keeper'
        events = [{'type': 'CUSTOM', 'name': 'KEEPER_CHAT_OPERATION_ACCEPTED',
                   'value': {'operation_id': 'request'}},
                  {'type': 'RUN_STARTED', 'runId': run, 'threadId': thread},
                  {'type': 'CUSTOM', 'runId': run, 'threadId': thread, 'name': 'KEEPER_REPLY_DETAILS',
                   'value': {'reply': 'final', 'turn_outcome': 'visible_reply'}},
                  {'type': 'RUN_FINISHED', 'runId': run, 'threadId': thread}]
        def write(items):
            stream.write_text(''.join('data: ' + json.dumps(item) + '\n\n' for item in items))
        write(events)
        smoke.require_chat_completion(stream, 'final', 'keeper', 'request')
        variants = [events[:-1], events + [{'type': 'RUN_ERROR', 'runId': run}],
                    events[:3] + [dict(events[3], runId='other')],
                    events[:2] + [dict(events[2], value={'reply': 'other', 'turn_outcome': 'visible_reply'}), events[3]],
                    [dict(events[0], value={'operation_id': 'other'})] + events[1:],
                    [events[0], dict(events[1], threadId='keeper:other')] + events[2:]]
        for variant in variants:
            with self.subTest(variant=variant), self.assertRaises(smoke.SmokeError):
                write(variant)
                smoke.require_chat_completion(stream, 'final', 'keeper', 'request')


def check_real_fixture(binary, root, *, expect_open=False):
    base = Path(root)
    fixture = SimpleNamespace(
        checkpoint_binary=binary, checkpoint_binary_sha256=smoke.file_sha256(binary),
        checkpoint_keeper='checkpoint-inspection-fixture', call_id='call', tool_name='Execute',
        final='finished', marker='marker',
        proof={'marker': 'marker', 'cwd': '/sandbox', 'hostname': 'guest', 'uid': 1000},
        checkpoint_env={'HOME': root, 'MASC_BASE_PATH': root, 'PATH': str(Path(sys.executable).parent)})
    answer = smoke.checkpoint_proof(base, fixture, 30)
    if expect_open:
        if answer is not None:
            raise AssertionError('an open final was accepted as a closed turn')
        return
    if answer is None:
        raise AssertionError('the real canonical checkpoint was not accepted')
    path, data = answer
    if not path.is_file() or data['reference']['turn_count'] < 1:
        raise AssertionError('the real canonical checkpoint reference is incorrect')


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] in ('--real-fixture', '--expect-open-fixture'):
        check_real_fixture(sys.argv[2], sys.argv[3], expect_open=sys.argv[1] == '--expect-open-fixture')
    else:
        unittest.main()
