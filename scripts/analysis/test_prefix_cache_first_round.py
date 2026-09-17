"""Evidence contract: the first round of a turn is read apart from its later rounds,
a moved history head reads as a broken prefix, and a malformed line is counted, not dropped."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('prefix-cache-first-round.py')
DEPLOY = '2026-09-16T12:00:00Z'


def blob(sha):
    return {'bytes': 10, 'content_ref': f'[masc:blob sha256={sha * 64} bytes=10 mime=text/plain]'}


def snapshot(turn, captured_at, message_shas, tool_names):
    return {'keeper': 'k', 'runtime_profile': 'ollama_cloud.m', 'absolute_turn': turn,
            'captured_at': captured_at,
            'wire': {'body_bytes': 1000 * turn},
            'system_prompt': blob('s'),
            'messages': [{'index': i, 'role': 'user', 'artifact': blob(s)} for i, s in enumerate(message_shas)],
            'tool_schemas': [{'index': i, 'name': n, 'artifact': blob(n[0])} for i, n in enumerate(tool_names)]}


class PrefixCacheEvidence(unittest.TestCase):
    def audit(self, ledger_rows, snapshots, turn_records=(), receipts=(), extra_ledger_lines=''):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            ledger = root / 'costs' / '2026-09' / '16.jsonl'
            ledger.parent.mkdir(parents=True)
            ledger.write_text(''.join(json.dumps(r) + '\n' for r in ledger_rows) + extra_ledger_lines)
            keeper = root / 'keepers' / 'k'
            for kind, rows in (('provider-inputs', snapshots), ('turn-records', turn_records),
                               ('execution-receipts', receipts)):
                path = keeper / kind / '2026-09' / '16.jsonl'
                path.parent.mkdir(parents=True)
                path.write_text(''.join(json.dumps(r) + '\n' for r in rows))
            output = root / 'report.json'
            subprocess.run([sys.executable, str(SCRIPT), '--masc-root', str(root), '--date', '2026-09-16',
                            '--deploy-at', DEPLOY, '--output', str(output)],
                           check=True, capture_output=True, text=True)
            return json.loads(output.read_text())

    @staticmethod
    def request(turn, ordinal, ts, tokens, miss):
        return {'agent': 'k', 'runtime_id': 'ollama_cloud.m', 'keeper_turn_id': turn,
                'agent_core_turn_ordinal': ordinal, 'timestamp': ts, 'usage_projection': 'raw_observation',
                'input_tokens': tokens, 'cache_miss_input_tokens': miss}

    def test_first_rounds_are_read_apart_from_later_rounds(self):
        rows = [self.request(1, 1, '2026-09-16T13:00:00Z', 100, 100),
                self.request(1, 2, '2026-09-16T13:00:10Z', 120, 20),
                self.request(2, 3, '2026-09-16T13:10:00Z', 130, 65),
                self.request(2, 4, '2026-09-16T13:10:05Z', 140, 10)]
        report = self.audit(rows, [])
        [after] = [r for r in report['rounds_by_family_and_era'] if r['era'] == 'after_deploy']
        self.assertEqual(after['family'], 'ollama_cloud')
        self.assertEqual(after['first_rounds']['n'], 2)
        self.assertEqual(after['later_rounds']['n'], 2)
        self.assertAlmostEqual(after['first_rounds']['miss_ratio']['median'], 0.75)
        self.assertAlmostEqual(after['later_rounds']['miss_ratio']['median'], (20 / 120 + 10 / 140) / 2)
        self.assertAlmostEqual(after['share_of_missed_tokens_in_first_rounds'], 165 / 195)
        # Turn 2's first round came 590 s after turn 1's last request: the 300-900 s bucket.
        [gap] = report['first_round_miss_by_gap']
        self.assertEqual(gap['gap_seconds'], '300-900')
        self.assertAlmostEqual(gap['first_round_miss_ratio']['median'], 0.5)
        self.assertEqual(after['input_growth_per_turn_tokens']['median'], 30)
        # Without turn records the tool surface is unknown; the gap is still read.
        self.assertEqual(report['first_round_after_deploy_by_gap_and_tools'],
                         [{'family': 'ollama_cloud', 'gap': 'gap<15m', 'tools': 'unknown',
                           'first_round_miss_ratio': {'n': 1, 'median': 0.5, 'mean': 0.5, 'p90': 0.5},
                           'full_miss': 0}])

    def test_a_moved_history_head_reads_as_a_broken_prefix(self):
        before, after = 1_700_000_000.0, 1_800_000_000.0
        snaps = [snapshot(1, before, ['a', 'b', 'c'], ['x', 'y']),
                 snapshot(2, before + 60, ['b', 'c', 'd'], ['x', 'y']),        # head moved: prefix broken at 0
                 snapshot(3, after, ['a', 'b', 'c'], ['x', 'y']),
                 snapshot(4, after + 60, ['a', 'b', 'c', 'd'], ['x', 'y', 'z']),  # append: prefix intact
                 snapshot(5, after + 120, ['a', 'b', 'c', 'd', 'e'], ['x', 'z'])]  # y left: tools changed
        report = self.audit([], snaps)
        by_era = {r['era']: r for r in report['consecutive_snapshot_prefix']}
        self.assertEqual(by_era['before_deploy']['pairs'], 1)
        self.assertEqual(by_era['before_deploy']['prev_is_prefix_of_next'], 0)
        self.assertEqual(by_era['before_deploy']['first_diff_index']['median'], 0)
        self.assertEqual(by_era['after_deploy']['pairs'], 2)
        self.assertEqual(by_era['after_deploy']['prev_is_prefix_of_next'], 2)
        self.assertEqual(by_era['after_deploy']['lcp_share']['median'], 1.0)
        tools = report['tool_list_changes_after_deploy']
        self.assertEqual(tools['pairs_after_deploy'], 2)
        self.assertEqual(tools['kinds'].get('+'), 1)
        self.assertEqual(tools['kinds'].get('pure_append_at_end'), 1)
        self.assertEqual(tools['kinds'].get('-'), 1)
        self.assertEqual(tools['removed'], [['y', 1]])

    def test_settled_usage_oversized_bodies_and_turn_ends_are_counted(self):
        records = [{'keeper': 'k', 'runtime_profile': 'glm-coding.m', 'absolute_turn': 1, 'finish_reason': 'stop',
                    'input_tokens': 1000, 'cache_read_input_tokens': 700, 'ttfrc_ms': 3000,
                    'request_body_bytes': 2_000_000, 'tool_surface_ref': 't'},
                   {'keeper': 'k', 'runtime_profile': 'glm-coding.m', 'absolute_turn': 2,
                    'request_body_bytes': 3_000_000, 'tool_surface_ref': 't'}]
        receipts = [{'runtime': {'name': 'glm-coding.m', 'selected_model': 'k3'}, 'terminal_reason_code': 'x'},
                    {'runtime': {'name': 'glm-coding.m', 'selected_model': 'k3'}, 'terminal_reason_code': 'x'},
                    {'runtime': {'name': 'glm-coding.m', 'selected_model': 'g'}, 'terminal_reason_code': 'success'}]
        report = self.audit([], [], turn_records=records, receipts=receipts)
        [usage] = report['settled_usage_by_family']
        self.assertEqual((usage['family'], usage['rows'], usage['completed']), ('glm-coding', 2, 1))
        self.assertAlmostEqual(usage['cache_read_over_input'], 0.7)
        self.assertEqual(usage['ttfrc_ms_by_uncached_tokens']['0-2000']['median'], 3000)
        [big] = report['oversized_requests']
        self.assertEqual((big['rows'], big['completed'], big['max_bytes']), (2, 1, 3_000_000))
        self.assertEqual(report['turn_ends_by_selected_model'][0],
                         {'selected_model': 'k3', 'receipts': 2, 'terminal_reason_codes': [['x', 2]]})

    def test_a_malformed_line_is_counted_not_dropped(self):
        report = self.audit([self.request(1, 1, '2026-09-16T13:00:00Z', 10, 5)], [], extra_ledger_lines='{not json\n')
        self.assertEqual(report['requests_read'], 1)
        self.assertEqual(report['malformed'], [{'path': 'costs/2026-09/16.jsonl', 'line': 2}])


if __name__ == '__main__':
    unittest.main()
