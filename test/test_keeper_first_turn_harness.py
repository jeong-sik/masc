"""Acceptance must not mistake an archived snapshot for canonical persistence."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('first_turn', ROOT / 'scripts/keeper-first-turn-smoke.py')
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


class CanonicalAcceptance(unittest.TestCase):
    def test_only_exact_session_file_proves_final_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            trace = base / '.masc/traces/session-test'
            trace.mkdir(parents=True)
            fixture = SMOKE.ModelFixture('marker', base)
            fixture.tool_name = 'Execute'
            proof = {'marker': 'marker', 'hostname': 'guest', 'uid': 42, 'cwd': '/masc-work/keeper'}
            data = {'session_id': 'session-test', 'messages': [
                {'role': 'assistant', 'content': [{'id': fixture.call_id, 'name': 'Execute'}]},
                {'role': 'tool', 'content': [{'content': json.dumps(proof)}]},
                {'role': 'assistant', 'content': [{'text': fixture.final}]}]}
            (trace / 'agent-core-snapshot-123.json').write_text(json.dumps(data))
            self.assertIsNone(SMOKE.checkpoint_proof(base, fixture))
            (trace / 'session-test.json').write_text(json.dumps(data))
            path, result = SMOKE.checkpoint_proof(base, fixture)
            self.assertEqual(path.name, 'session-test.json')
            self.assertEqual(result, data)
            data['messages'][-1]['role'] = 'user'
            (trace / 'session-test.json').write_text(json.dumps(data))
            self.assertIsNone(SMOKE.checkpoint_proof(base, fixture))

    def test_malformed_session_identity_is_not_canonical(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / '.masc').mkdir()
            (base / '.masc/7.json').write_text('{"session_id":7,"messages":[]}')
            self.assertIsNone(SMOKE.checkpoint_proof(base, SMOKE.ModelFixture('marker', base)))


if __name__ == '__main__':
    unittest.main()
