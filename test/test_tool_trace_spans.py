import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/harness/perf/tool_trace_spans.py'
spec = importlib.util.spec_from_file_location('tool_trace_spans', SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def event(kind, call, ts, **extra):
    return {**dict(record_type='tool_execution_' + kind, worker_run_id='worker',
                   tool_use_id=call, tool_name='capture', tool_turn=1, tool_planned_index=0, ts=ts), **extra}


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

    def test_reused_call_id_in_different_invocations_is_distinct(self):
        paths = []
        for turn, planned in [(1, 0), (2, 0), (2, 1)]:
            coords = dict(tool_turn=turn, tool_planned_index=planned)
            paths.append(self.write([event('started', 'same', 1, **coords),
                                     event('finished', 'same', 2, **coords)],
                                    name=f'{turn}-{planned}.jsonl'))
        report = probe.report(paths)
        self.assertEqual(report['summary'][0]['paired'], 3)
        self.assertEqual([(source['rows'][0]['tool_turn'], source['rows'][0]['tool_planned_index'])
                          for source in report['sources']], [(1, 0), (2, 0), (2, 1)])
        combined = self.write([event('started', 'same', 1), event('finished', 'same', 2),
                              event('started', 'same', 3, tool_turn=2),
                              event('finished', 'same', 4, tool_turn=2)])
        self.assertEqual(probe.report([combined])['summary'][0]['paired'], 2)

    def test_mismatched_invocation_is_incomplete_not_paired(self):
        for changed in [dict(tool_turn=2), dict(tool_planned_index=1)]:
            with self.subTest(changed=changed):
                source = probe.collect(self.write([event('started', 'same', 1),
                    event('finished', 'same', 2, **changed)]))
                self.assertEqual(source['rows'], [])
                self.assertEqual(source['pending_starts'], 1)
                self.assertEqual(source['orphan_finishes'], 1)

    def test_invocation_coordinates_are_required_nonnegative_integers(self):
        for field in ['tool_turn', 'tool_planned_index']:
            for value in [None, True, -1, 1.0, '1']:
                with self.subTest(field=field, value=value):
                    with self.assertRaisesRegex(ValueError, 'invocation coordinates'):
                        probe.collect(self.write([event('started', 'a', 1, **{field: value})]))
            missing = event('started', 'a', 1)
            del missing[field]
            with self.assertRaisesRegex(ValueError, 'invocation coordinates'):
                probe.collect(self.write([missing]))

    def test_output_cannot_overwrite_input_or_symlink_or_hardlink(self):
        source = self.write([event('started', 'a', 1), event('finished', 'a', 2)])
        original = source.read_bytes()
        symlink = source.with_name('alias-symlink.json')
        symlink.symlink_to(source)
        hardlink = source.with_name('alias-hardlink.json')
        hardlink.hardlink_to(source)
        for destination in [source, symlink, hardlink]:
            with self.subTest(destination=destination):
                result = subprocess.run([sys.executable, str(SCRIPT), str(source),
                                         '--output', str(destination)],
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('must not overwrite', result.stderr)
                self.assertEqual(source.read_bytes(), original)

    def test_nonfinite_derived_span_rejected(self):
        with self.assertRaisesRegex(ValueError, 'nonfinite derived span'):
            probe.collect(self.write([event('started', 'a', -1e308),
                                      event('finished', 'a', 1e308)]))

    def test_nonfinite_timestamp_rejected(self):
        with self.assertRaises(ValueError):
            probe.report([self.write([event('started', 'a', float('nan'))])])


if __name__ == '__main__':
    unittest.main()
