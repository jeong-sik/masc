import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/harness/perf/tool_trace_spans.py'
spec = importlib.util.spec_from_file_location('tool_trace_spans', SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def event(kind, call, ts, **extra):
    return {**dict(record_type='tool_execution_' + kind, worker_run_id='worker',
                   tool_use_id=call, tool_name='capture', ts=ts), **extra}


class TraceSpans(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def write(self, events, name='trace.jsonl'):
        path = Path(self.temp.name) / name
        path.write_text(''.join(json.dumps(e) + '\n' for e in events))
        return path

    def test_interleaving_outcomes_and_no_payload_disclosure(self):
        path = self.write([event('started', 'a', 1, tool_input={'secret': 'PRIVATE'}),
                           event('started', 'b', 1.01),
                           event('finished', 'b', 1.02, tool_error=True),
                           event('finished', 'a', 1.04, tool_error=False, tool_result='PRIVATE')])
        report = probe.report([path])
        groups = {g['outcome']: g for g in report['summary']}
        self.assertAlmostEqual(groups['succeeded']['p50_ms'], 40)
        self.assertAlmostEqual(groups['failed']['p50_ms'], 10)
        self.assertNotIn('PRIVATE', json.dumps(report))

    def test_incomplete_clock_regression_and_unknown_are_explicit(self):
        path = self.write([event('started', 'pending', 1), event('finished', 'orphan', 2),
                           event('started', 'backward', 3), event('finished', 'backward', 2)])
        report = probe.report([path])
        self.assertEqual(report['sources'][0]['pending_starts'], 1)
        self.assertEqual(report['sources'][0]['orphan_finishes'], 1)
        self.assertEqual(report['summary'][0]['outcome'], 'unknown')
        self.assertEqual(report['summary'][0]['clock_regressions'], 1)
        self.assertIsNone(report['summary'][0]['p50_ms'])

    def test_duplicate_and_mismatched_identities_rejected(self):
        for events in ([event('started', 'a', 1), event('started', 'a', 2)],
                       [event('started', 'a', 1), event('finished', 'a', 2, tool_name='other')]):
            with self.assertRaises(ValueError):
                probe.report([self.write(events)])
        path = self.write([event('started', 'a', 1), event('finished', 'a', 2)])
        with self.assertRaises(ValueError):
            probe.report([path, path])

    def test_nonfinite_timestamp_rejected(self):
        with self.assertRaises(ValueError):
            probe.report([self.write([event('started', 'a', float('nan'))])])


if __name__ == '__main__':
    unittest.main()
