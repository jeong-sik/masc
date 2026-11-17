"""Audit retained measurements; write new output to the requested destination."""
import argparse
import json
import statistics
from pathlib import Path

def audit(runs):
    assert len(runs) == 8
    pairs = {}
    for run in runs:
        assert run['exit_code'] == 0
        key = (run['pair'], run['side'])
        assert key not in pairs
        pairs[key] = run
        observed = run['observed']
        assert observed['ocaml_version'] == '5.5.2'
        assert observed['word_size'] == 64
        assert len(observed['results']) == 4
        for row in observed['results']:
            expected_alive = run['side'] == 'baseline' or row['ownership'] == 'caller_held'
            for witness in ['input_alive_before', 'input_alive_after',
                            'message_alive_before', 'message_alive_after']:
                assert row[witness] == expected_alive
            assert row['timed_full_major_calls'] == 24
            assert row['untimed_full_major_calls'] == 8
            assert row['timed_after_counts']['forced_major_collections'] - row['timed_before_counts']['forced_major_collections'] == 24
            assert row['gc_process_cpu_seconds'] > 0
            assert row['gc_wall_seconds'] > 0
    assert list(pairs) == [(0, 'baseline'), (0, 'candidate'), (1, 'candidate'),
                          (1, 'baseline'), (2, 'baseline'), (2, 'candidate'),
                          (3, 'candidate'), (3, 'baseline')]
    summaries = []
    for index, (rows, ownership) in enumerate([(32768, 'released'), (32768, 'caller_held'),
                                             (131072, 'released'), (131072, 'caller_held')]):
        values = []
        for pair in range(4):
            b = pairs[(pair, 'baseline')]
            c = pairs[(pair, 'candidate')]
            assert b['observed']['gc_control'] == c['observed']['gc_control']
            assert b['inherited_OCAMLRUNPARAM'] == c['inherited_OCAMLRUNPARAM']
            before = b['observed']['results'][index]
            after = c['observed']['results'][index]
            assert before['rows'] == after['rows'] == rows
            assert before['ownership'] == after['ownership'] == ownership
            for key in ['encoded_memo_bytes', 'first_head_sha256', 'content_digest', 'replay_head_sha256']:
                assert before[key] == after[key]
            values.append(dict(pair=pair,
                baseline_cpu_seconds=before['gc_process_cpu_seconds'],
                candidate_cpu_seconds=after['gc_process_cpu_seconds'],
                cpu_ratio=after['gc_process_cpu_seconds'] / before['gc_process_cpu_seconds'],
                wall_ratio=after['gc_wall_seconds'] / before['gc_wall_seconds'],
                baseline_live_words=before['after']['live_words'],
                candidate_live_words=after['after']['live_words'],
                candidate_minus_baseline_live_bytes=8 * (after['after']['live_words'] - before['after']['live_words']),
                baseline_gc_allocated_bytes=before['gc_allocated_bytes'],
                candidate_gc_allocated_bytes=after['gc_allocated_bytes']))
        summaries.append(dict(rows=rows, ownership=ownership,
            median_cpu_ratio=statistics.median(v['cpu_ratio'] for v in values),
            median_wall_ratio=statistics.median(v['wall_ratio'] for v in values),
            baseline_median_cpu_seconds=statistics.median(v['baseline_cpu_seconds'] for v in values),
            candidate_median_cpu_seconds=statistics.median(v['candidate_cpu_seconds'] for v in values),
            median_candidate_minus_baseline_live_bytes=statistics.median(v['candidate_minus_baseline_live_bytes'] for v in values),
            pairs=values))
    return dict(processes=8, pairs=4, measured_rows=32, explicit_timed_full_major_calls_per_row=24,
                additional_forced_collections='Gc.stat before and after timing;8 explicit preparatory calls',
                row_order='fixed four rows per process, not fresh process per row',
                scope='process CPU during explicit forced collections; no server CPU or RSS attribution',
                summaries=summaries)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('runs', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    assert not args.output.exists(), 'write new output; preserve existing evidence'
    args.output.write_text(json.dumps(audit(json.loads(args.runs.read_text())), indent=2) + '\n')
