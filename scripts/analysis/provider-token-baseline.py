#!/usr/bin/env python3
"""Read-only token audit. Emits aggregates and source hashes, never prompt bodies."""
import argparse
import collections
import datetime
import hashlib
import json
from pathlib import Path
import statistics

parser = argparse.ArgumentParser()
parser.add_argument('--masc-root', type=Path, required=True)
parser.add_argument('--date', required=True, help='UTC ledger date, YYYY-MM-DD')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
day = datetime.date.fromisoformat(args.date)
month, stem = day.strftime('%Y-%m'), day.strftime('%d')
sources, malformed = [], []

def read_rows(path):
    # Capture the current bytes once; rotations/appends after this read are outside this sample.
    raw = path.read_bytes()
    sources.append({'path': str(path.relative_to(args.masc_root)),
                    'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
    rows = []
    for number, line in enumerate(raw.splitlines(), 1):
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            malformed.append({'path': str(path.relative_to(args.masc_root)), 'line': number})
    return rows

def stats(values):
    known = [v for v in values if isinstance(v, (int, float))]
    return {'observations': len(values), 'known': len(known), 'sum': sum(known),
            'median': statistics.median(known) if known else None,
            'max': max(known) if known else None}

ledger = read_rows(args.masc_root / 'costs' / month / (stem + '.jsonl'))
usage = {}
for row in ledger:
    # Never combine raw per-round observations with settled turn deltas.
    key = (row.get('model'), row.get('usage_projection'), row.get('usage_trust'))
    group = usage.setdefault(key, [])
    group.append(row)
usage_rows = []
for key, rows in sorted(usage.items()):
    usage_rows.append({'model': key[0], 'projection': key[1], 'trust': key[2],
                      'rows': len(rows),
                      'tokens': {f: stats([r.get(f) for r in rows]) for f in
                                 ['input_tokens', 'output_tokens', 'cache_read_tokens',
                                  'cache_creation_tokens', 'cache_miss_input_tokens']}})
wire = []
for path in sorted((args.masc_root / 'wire-capture' / month).glob(stem + '*.jsonl')):
    wire.extend(row for row in read_rows(path) if 'system_prompt' in row)
previous, pairs = {}, collections.Counter()
for row in sorted(wire, key=lambda r: r.get('ts', '')):
    name = row.get('keeper')
    old = previous.get(name)
    if old is not None:
        pairs['pairs'] += 1
        for field in ['system_prompt', 'tools_ref', 'extra_system_context']:
            if old.get(field) is not None and row.get(field) is not None:
                pairs[field + '_comparable'] += 1
                pairs[field + '_unchanged'] += old[field] == row[field]
    previous[name] = row
blocks, components, shapes = collections.defaultdict(list), collections.defaultdict(list), collections.Counter()
turn_count = 0
for path in sorted((args.masc_root / 'keepers').glob('*/turn-records/' + month + '/' + stem + '.jsonl')):
    for row in read_rows(path):
        turn_count += 1
        shape = row.get('model_input_measurement')
        shapes[(shape, row.get('usage_scope'))] += 1
        for block in row.get('blocks', []):
            blocks[block['block']].append(block['bytes'])
        if shape == 'wire_shape':
            for component in row.get('input_components') or []:
                components[component['component']].append(component['bytes'])
report = {'sample_finished_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'utc_date': args.date, 'source_files': sources, 'malformed_lines': malformed,
          'ledger_interval': [min(r['timestamp'] for r in ledger), max(r['timestamp'] for r in ledger)],
          'usage_by_projection': usage_rows,
          'hook_requests': {'count': len(wire), 'adjacent_by_keeper': dict(pairs),
                            'tool_schema_bytes': stats([r.get('tool_schema_bytes') for r in wire]),
                            'extra_context_bytes': stats([r.get('extra_system_context_bytes') for r in wire])},
          'turn_records': {'count': turn_count,
                           'shapes': [{'shape': k[0], 'usage_scope': k[1], 'rows': v} for k, v in sorted(shapes.items())],
                           'prompt_blocks_bytes': {k: stats(v) for k, v in blocks.items()},
                           'wire_shape_components_bytes': {k: stats(v) for k, v in components.items()}},
          'limits': ['UTC-day prefix snapshots are not an atomic snapshot of the whole runtime.',
                     'Hook captures are not final provider HTTP bytes; repeated hooks are not deduplicated requests.',
                     'Byte counts are not tokenizer counts. CLI durable_shape excludes client-owned history expansion.',
                     'Raw observations and resolved deltas overlap; never add these projections.',
                     'Provider usage measures reported accounting, not hardware counters or all failed attempts.']}
args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(args.output)
