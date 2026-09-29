"""Evidence must fail closed when workload or tracer capture is incomplete."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/harness/perf'))
from compare_checkpoint_history import validate
from checkpoint_history_artifact_session import seed


class Evidence(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identity = {'source': 'a'*40, 'sha256': {'main_eio.exe': 'b'*64}}
        self.put('identity.json', {**self.identity, 'pid': 42, 'histories': 1,
                                 'interval_s': 90, 'load_before': [0, 0, 0]})
        self.put('completed.json', {'cycles': 1, 'fixture_sha256': 'c'*64, 'load_after': [0, 0, 0]})
        self.put('cleanup.json', {'all_exited': True, 'errors': []})
        self.put('health-after.json', {'scheduler': {'samples': 60, 'p99_ms': 1, 'max_ms': 2}})
        self.inventory = {'path': '/api/v1/keepers/fixture/checkpoints', 'status': 200,
            'start_unix': 110, 'end_unix': 111, 'elapsed_ms': 1,
            'body': json.dumps({'history_errors': [], 'history': [{'snapshot_id': 'one'}]})}
        self.health = {'path': '/health', 'status': 200, 'elapsed_ms': 2, 'body': '{}'}
        self.requests()
        for name in ('rtev_fibers', 'rtev_watch'):
            (self.root / (name+'.txt')).write_text(
                'ready pid=42 started_at_unix=100.000000\n'
                'window started_at_unix=100.000000 ended_at_unix=190.000000\n'
                'pid=42 window_s=90.0 events=100 lost=0\n'
                'domain runs run_ms busy% >=10ms >=50ms >=100ms max_ms\n'
                '0 100 12.0 1.0% 0 0 0 1.0\n')

    def put(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def requests(self):
        (self.root / 'requests.jsonl').write_text('\n'.join(map(json.dumps, [self.inventory, self.health]))+'\n')

    def test_complete_capture(self):
        self.assertEqual(validate(self.root, self.identity, 1)['inventory']['n'], 1)

    def test_missing_request(self):
        with self.assertRaisesRegex(ValueError, 'incomplete workload'):
            validate(self.root, self.identity, 2)

    def test_invalid_checkpoint(self):
        self.inventory['body'] = json.dumps({'history_errors': [{'error_kind': 'parse_error'}], 'history': []})
        self.requests()
        with self.assertRaisesRegex(ValueError, 'invalid inventory'):
            validate(self.root, self.identity, 1)

    def test_workload_outside_trace(self):
        self.inventory['start_unix'] = 99
        self.requests()
        with self.assertRaisesRegex(ValueError, 'outside runtime-events'):
            validate(self.root, self.identity, 1)

    def test_lost_events(self):
        p = self.root / 'rtev_fibers.txt'
        p.write_text(p.read_text().replace('lost=0', 'lost=1'))
        with self.assertRaisesRegex(ValueError, 'lossy'):
            validate(self.root, self.identity, 1)

    def test_wrong_binary(self):
        with self.assertRaisesRegex(ValueError, 'identity differs'):
            validate(self.root, {**self.identity, 'source': 'd'*40}, 1)

    def test_failed_cleanup(self):
        self.put('cleanup.json', {'all_exited': False, 'errors': []})
        with self.assertRaisesRegex(ValueError, 'cleanup'):
            validate(self.root, self.identity, 1)

    def test_fixture_bytes_match_across_roots(self):
        roots = [self.root / 'before', self.root / 'after']
        manifests = []
        for root in roots:
            (root / '.masc').mkdir(parents=True)
            _, manifest = seed(root, 3, 2)
            manifests.append(manifest)
        self.assertEqual(manifests[0], manifests[1])
        self.assertEqual(len(manifests[0]), 5)


if __name__ == '__main__':
    unittest.main()
