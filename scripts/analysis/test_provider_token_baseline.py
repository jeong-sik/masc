"""CLI evidence contract: partial accounting must not look like zero usage."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('provider-token-baseline.py')


class BaselineEvidence(unittest.TestCase):
    def audit(self, counts, extra_lines=""):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            ledger = root / 'costs' / '2026-09' / '09.jsonl'
            ledger.parent.mkdir(parents=True)
            rows = [{'timestamp': '2026-09-09T00:00:00Z', 'model': 'fixture',
                     'usage_projection': 'raw', 'usage_trust': 'reported',
                     'input_tokens': value} for value in counts]
            ledger.write_text(''.join(json.dumps(row) + '\n' for row in rows) + extra_lines)
            output = root / 'report.json'
            subprocess.run([sys.executable, str(SCRIPT), '--masc-root', str(root),
                            '--date', '2026-09-09', '--output', str(output)],
                           check=True, capture_output=True, text=True)
            return json.loads(output.read_text())

    def test_partial_usage_is_not_a_complete_total(self):
        report = self.audit([0, 12, None, True, -1, '8', 2.5])
        counts = report['usage_by_projection'][0]['tokens']['input_tokens']
        self.assertEqual(counts['known_sum'], 12)
        self.assertIsNone(counts['complete_sum'])
        self.assertEqual((counts['known'], counts['missing'], counts['invalid']), (2, 1, 4))
        output = report['usage_by_projection'][0]['tokens']['output_tokens']
        self.assertIsNone(output['known_sum'])
        self.assertIsNone(output['complete_sum'])
        self.assertEqual(output['missing'], 7)

    def test_reported_zero_is_measured_zero(self):
        counts = self.audit([0])['usage_by_projection'][0]['tokens']['input_tokens']
        self.assertEqual(counts['known_sum'], 0)
        self.assertEqual(counts['complete_sum'], 0)
        self.assertEqual(counts['missing'], 0)

    def test_broken_source_is_not_complete_evidence(self):
        report = self.audit([12], '{broken\n[]\n')
        self.assertFalse(report['source_decode_complete'])
        self.assertEqual(len(report['malformed_lines']), 2)
        counts = report['usage_by_projection'][0]['tokens']['input_tokens']
        self.assertEqual(counts['complete_sum'], 12)  # decoded group only

    def test_empty_day_is_no_measurement(self):
        report = self.audit([])
        self.assertEqual(report['ledger_interval'], [None, None])
        self.assertEqual(report['usage_by_projection'], [])
        self.assertIsNone(report['hook_requests']['tool_schema_bytes']['complete_sum'])


if __name__ == '__main__':
    unittest.main()
