#!/usr/bin/env python3
"""Read-only metadata observation; never retains memory or prompt bodies."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--health-url', required=True)
parser.add_argument('--config-root', type=Path, required=True)
parser.add_argument('--repo', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
output_path = args.out.resolve()
artifact_root = (args.repo / 'artifacts').resolve()
if not output_path.is_relative_to(artifact_root):
    parser.error('--out must name a new file under the selected repository artifacts directory')
if output_path.exists():
    parser.error('--out already exists; select a new capture path')


def now():
    return dt.datetime.now(dt.timezone.utc)


def health():
    with urllib.request.urlopen(args.health_url, timeout=10) as response:
        value = json.load(response)
    build = value['build']
    return {
        'runtime_instance_id': build['runtime_instance_id'],
        'binary_commit': build['binary_commit'],
        'started_at': build['started_at'],
        'paths': value['paths'],
        'memory_availability': value.get('keeper_memory_execution'),
    }


def distribution(values):
    return {'observations': len(values), 'min': min(values), 'max': max(values),
            'median': statistics.median(values)} if values else {'observations': 0}


before = health()
window_end = now()
window_start = dt.datetime.fromisoformat(before['started_at'].replace('Z', '+00:00'))
runtime_root = Path(before['paths']['effective_masc_root'])
config_keepers = args.config_root / 'keepers'
snapshots, snapshot_errors, journals, record_files, records, record_errors = [], [], [], [], [], []
scan_started = now()
for path in sorted(config_keepers.glob('*.memory-current.json')):
    try:
        stat_before = path.stat()
        raw = path.read_bytes()
        observed_at = now().isoformat()
        value = json.loads(raw)
        stat_after = path.stat()
        facts = value.get('facts')
        snapshots.append({
            'keeper': path.name.removesuffix('.memory-current.json'),
            'path': str(path), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
            'revision': value.get('revision'),
            'fact_count': len(facts) if isinstance(facts, list) else None,
            'observed_at': observed_at,
            'path_stable_during_read': (stat_before.st_ino, stat_before.st_mtime_ns, stat_before.st_size)
            == (stat_after.st_ino, stat_after.st_mtime_ns, stat_after.st_size),
        })
    except (OSError, ValueError) as error:
        snapshot_errors.append({'path': str(path), 'error_type': type(error).__name__})
for path in sorted(config_keepers.glob('*.memory-journal.jsonl')):
    stat = path.stat()
    journals.append({'path': str(path), 'bytes': stat.st_size, 'mtime_ns': stat.st_mtime_ns})

days = []
day = window_start.date()
while day <= window_end.date():
    days.append(day)
    day += dt.timedelta(days=1)
block_names = {'memory_os_recall', 'librarian_working_context', 'recalled_memory', 'recalled_memory_status'}
for day in days:
    pattern = '*/turn-records/' + day.strftime('%Y-%m/%d.jsonl')
    for path in sorted((runtime_root / 'keepers').glob(pattern)):
        raw = path.read_bytes()
        record_files.append({'path': str(path), 'read_bytes': len(raw),
                             'sha256': hashlib.sha256(raw).hexdigest()})
        for line_number, line in enumerate(raw.splitlines(), 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
                timestamp = value.get('ts')
                if not isinstance(timestamp, (float, int)):
                    raise ValueError('timestamp missing')
            except (ValueError, TypeError):
                record_errors.append({'path': str(path), 'line': line_number})
                continue
            if not (window_start.timestamp() <= timestamp <= window_end.timestamp()):
                continue
            blocks = value.get('blocks')
            components = value.get('input_components')
            records.append({
                'path': str(path), 'line': line_number, 'ts': timestamp,
                'keeper': value.get('keeper'), 'turn_ref': value.get('turn_ref'),
                'runtime_profile': value.get('runtime_profile'),
                'block_observations': [b for b in blocks if b.get('block') in block_names]
                if isinstance(blocks, list) else None,
                'attributed_memory_components': [c for c in components
                    if c.get('component') in {'prompt.' + name for name in block_names}]
                if isinstance(components, list) else None,
                'request_body_bytes': value.get('request_body_bytes'),
            })

after = health()
sources = ['lib/keeper/keeper_memory_os_recall.ml', 'lib/keeper/keeper_memory_os_current.ml',
           'lib/keeper/keeper_memory_recall_blocks.ml', 'lib/keeper/keeper_run_tools_hooks.ml',
           'lib/config_dir_resolver/config_dir_resolver.ml', 'lib/types/turn_record.ml']
source_hashes = {}
for source in sources:
    installed = subprocess.check_output(['git', 'show', before['binary_commit'] + ':' + source], cwd=args.repo)
    current = (args.repo / source).read_bytes()
    source_hashes[source] = {'installed_sha256': hashlib.sha256(installed).hexdigest(),
                             'checkout_sha256': hashlib.sha256(current).hexdigest()}

block_sizes = [b['bytes'] for record in records for b in (record['block_observations'] or [])
               if b['block'] == 'memory_os_recall']
wire_sizes = [r['request_body_bytes'] for r in records if r['request_body_bytes'] is not None]
attributed_sizes = [c['bytes'] for record in records for c in (record['attributed_memory_components'] or [])
                    if c['component'] == 'prompt.memory_os_recall']
summary = {
    'json_rows_in_runtime_window': len(records),
    'distinct_turn_refs': len({r['turn_ref'] for r in records if r['turn_ref'] is not None}),
    'ordinary_snapshot_count': len(snapshots),
    'ordinary_snapshot_bytes': sum(r['bytes'] for r in snapshots),
    'ordinary_snapshot_fact_count': sum(r['fact_count'] for r in snapshots if r['fact_count'] is not None),
    'ordinary_snapshot_sizes': distribution([r['bytes'] for r in snapshots]),
    'memory_os_recall_block_sizes': distribution(block_sizes),
    'attributed_memory_os_recall_sizes': distribution(attributed_sizes),
    'complete_request_wire_sizes': distribution(wire_sizes),
    'legacy_memory_journal_bytes': sum(r['bytes'] for r in journals),
    'snapshot_errors': len(snapshot_errors), 'json_row_errors': len(record_errors),
}
output = {
    'issue': 25052, 'health_before': before, 'health_after': after,
    'runtime_identity_stable': all(before[k] == after[k] for k in ['runtime_instance_id', 'binary_commit', 'paths']),
    'record_window': {'from': window_start.isoformat(), 'through': window_end.isoformat()},
    'scan_window': {'from': scan_started.isoformat(), 'through': now().isoformat()},
    'config_root': str(args.config_root), 'source_hashes': source_hashes,
    'snapshots': snapshots, 'snapshot_errors': snapshot_errors, 'journal_file_metadata': journals,
    'turn_record_files': record_files, 'records': records, 'record_errors': record_errors, 'summary': summary,
    'limits': [
        'Read-only sequential observation; snapshot reads are not a fleet-wide transaction.',
        'JSON metadata inspection is not execution of the OCaml Turn_record decoder.',
        'Missing memory components are unknown, not zero; the latest request can be a post-tool round.',
        'Single snapshot observation does not establish a growth rate or a controlled workload comparison.',
        'No claim bodies, prompt bodies, credentials or provider requests are retained or generated.',
        'Availability is not provider execution, semantic relevance, use in decisions or cross-Keeper admission proof.',
    ],
}
output_path.parent.mkdir(parents=True, exist_ok=True)
with output_path.open('x') as destination:
    destination.write(json.dumps(output, indent=2) + '\n')
print(json.dumps({'path': str(output_path), 'sha256': hashlib.sha256(output_path.read_bytes()).hexdigest(),
                  'runtime_identity_stable': output['runtime_identity_stable'], 'summary': summary}))
