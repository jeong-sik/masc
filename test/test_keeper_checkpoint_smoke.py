#!/usr/bin/env python3
"""Decision tests for the first-turn checkpoint evidence consumer."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
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

    def test_ssh_restart_uses_the_new_call_and_final(self):
        self.fixture.call_id = 'ssh-restart-call'
        self.fixture.final = 'restart-final'
        self.messages[0]['content'][0]['id'] = self.fixture.call_id
        self.messages[1]['content'][0]['tool_use_id'] = self.fixture.call_id
        self.messages[2]['content'][0]['text'] = self.fixture.final
        self.assertIsNotNone(self.read())


if __name__ == '__main__':
    unittest.main()
