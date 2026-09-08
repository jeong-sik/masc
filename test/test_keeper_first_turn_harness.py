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


class KataProjectionAcceptance(unittest.TestCase):
    def setUp(self):
        self.projection = SMOKE.kata_path_projection(Path('/workspace'), 'keeper', '/masc-work')
        self.raw = {'marker': 'unique', 'cwd': '/masc-work/keeper', 'hostname': 'guest', 'uid': 1001}
        self.model = dict(self.raw, cwd='/workspace/.masc/playground/keeper')

    def test_only_cwd_is_projected_and_raw_proof_is_preserved(self):
        original = dict(self.raw)
        self.assertEqual(self.projection.match_proof(self.raw, self.model), self.model)
        self.assertEqual(self.raw, original)
        self.assertEqual(str(self.projection.guest_cwd(self.model['cwd'])), '/masc-work/keeper')
        nested = dict(self.raw, cwd='/masc-work/keeper/repo/subdir')
        projected = dict(self.model, cwd='/workspace/.masc/playground/keeper/repo/subdir')
        self.assertEqual(self.projection.match_proof(nested, projected), projected)

    def test_unmapped_or_traversing_model_paths_are_rejected(self):
        for cwd in ('/masc-work/keeper', '/workspace/.masc/playground/other',
                    '/workspace/.masc/playground/keeper-extra', 'repo',
                    '/workspace/.masc/playground/keeper/../other',
                    '/workspace/.masc/playground/keeper/repo/../repo'):
            with self.subTest(cwd=cwd), self.assertRaises(SMOKE.SmokeError):
                self.projection.guest_cwd(cwd)

    def test_raw_guest_path_must_match_exact_projection(self):
        for cwd in ('/masc-work/other', '/masc-work/keeper/subdir',
                    '/masc-work/keeper/../keeper', '/workspace/.masc/playground/keeper'):
            with self.subTest(cwd=cwd), self.assertRaises(SMOKE.SmokeError):
                self.projection.match_proof(dict(self.raw, cwd=cwd), self.model)

    def test_empty_proofs_and_invalid_cwd_are_rejected(self):
        for proof in ({}, None, [], dict(self.raw, cwd=None), dict(self.raw, cwd=''),
                      dict(self.raw, cwd=42)):
            with self.subTest(proof=proof), self.assertRaises(SMOKE.SmokeError):
                self.projection.match_proof(proof, self.model)
        for proof in ({}, None, [], dict(self.model, cwd=None), dict(self.model, cwd='')):
            with self.subTest(proof=proof), self.assertRaises(SMOKE.SmokeError):
                self.projection.match_proof(self.raw, proof)

    def test_other_fields_are_not_rewritten_or_ignored(self):
        for changed in (dict(self.raw, marker='wrong'), dict(self.raw, uid=0),
                        dict(self.raw, hostname='other'), dict(self.raw, extra=True)):
            with self.subTest(proof=changed), self.assertRaises(SMOKE.SmokeError):
                self.projection.match_proof(changed, self.model)


if __name__ == '__main__':
    unittest.main()
