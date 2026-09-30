"""Compare the same checkpoint inventory fixture using two verified probe builds."""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys
import tempfile

from linux_probe_artifact import fetch, require
from compare_server_artifacts import run_child
from server_artifact_session import write_json


def stats(values):
    values = sorted(values)
    require(bool(values), 'no measurements')
    return {'n': len(values), 'p50_ms': statistics.median(values),
            'p95_ms': values[math.ceil(len(values)*.95)-1],
            'p99_ms': values[math.ceil(len(values)*.99)-1], 'max_ms': max(values)}


def validate(directory, identity, cycles, histories, noise):
    complete = json.loads((directory / 'completed.json').read_text())
    cleanup = json.loads((directory / 'cleanup.json').read_text())
    observed = json.loads((directory / 'identity.json').read_text())
    require(cleanup['all_exited'] and not cleanup['errors'], 'incomplete cleanup')
    require(observed['source'] == identity['source'] and observed['sha256'] == identity['sha256'],
            'session identity differs from verified artifact')
    require(observed['histories'] == histories and observed['noise'] == noise,
            'session fixture dimensions differ from requested workload')
    rows = [json.loads(line) for line in (directory / 'requests.jsonl').read_text().splitlines()]
    inventory = [row for row in rows if row['path'].endswith('/checkpoints')]
    require(len(inventory) == complete['cycles'] == observed['cycles'] == cycles, 'incomplete workload')
    for row in inventory:
        body = json.loads(row['body'])
        require(row['status'] == 200 and not body['history_errors']
                and len(body['history']) == observed['histories'], 'invalid inventory response')
    for name in ('rtev_fibers', 'rtev_watch'):
        trace_lines = (directory / (name + '.txt')).read_text().splitlines()
        header = next(line for line in trace_lines if line.startswith('pid='))
        window = dict(re.findall(r'(\w+)=([^ ]+)', next(line for line in trace_lines if line.startswith('window '))))
        require(all(float(window['started_at_unix']) <= row['start_unix'] <= row['end_unix'] <= float(window['ended_at_unix']) for row in inventory), 'workload outside runtime-events window')
        fields = dict(re.findall(r'(\w+)=([^ ]+)', header))
        require(int(fields['pid']) == observed['pid'] and int(fields['events']) > 0
                and int(fields['lost']) == 0, 'invalid or lossy runtime-events capture')
        require(abs(float(fields['window_s']) - cycles*observed['interval_s']) < 1,
                'runtime-events window differs')
    after = json.loads((directory / 'health-after.json').read_text())
    scheduler = after['scheduler']
    require(scheduler['samples'] > 0, 'scheduler probe has no observations')
    return {'fixture_sha256': complete['fixture_sha256'], 'source': identity['source'],
            'histories': observed['histories'], 'noise': observed['noise'],
            'cycles': observed['cycles'], 'interval_s': observed['interval_s'],
            'inventory': stats([row['elapsed_ms'] for row in inventory]),
            'health': stats([row['elapsed_ms'] for row in rows if row['path'] == '/health']),
            'scheduler': scheduler,
            'domain_0': next(line for line in (directory / 'rtev_fibers.txt').read_text().splitlines()
                             if re.match(r'^0\s+\d+\s+', line)),
            'load_before': observed['load_before'], 'load_after': complete['load_after']}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repository', required=True)
    p.add_argument('--repository-id', type=int, required=True)
    p.add_argument('--tracers', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--repetitions', type=int, default=3)
    p.add_argument('--cycles', type=int, default=90)
    p.add_argument('--histories', type=int, default=128)
    p.add_argument('--noise', type=int, default=8192)
    for role in ('baseline', 'candidate'):
        p.add_argument('--'+role+'-run', type=int, required=True)
        p.add_argument('--'+role+'-artifact', type=int, required=True)
        p.add_argument('--'+role+'-commit', required=True)
    args = p.parse_args()
    require(args.repetitions > 0 and args.cycles > 0, 'invalid measurement length')
    require(args.histories > 0 and args.noise >= 0, 'invalid fixture dimensions')
    args.output.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[3]
    write_json(args.output / 'plan.json', {**vars(args), 'tracers': str(args.tracers),
        'output': str(args.output), 'platform': platform.platform(), 'cpu_count': os.cpu_count(),
        'scope': '#39761 checkpoint inventory only; not #39766/#39774 or #25893 completion'})
    results = []
    with tempfile.TemporaryDirectory(prefix='masc-checkpoint-artifacts-') as temporary:
        identities = {}
        for role in ('baseline', 'candidate'):
            root = Path(temporary) / role
            identities[role] = fetch(root, repository=args.repository, repository_id=args.repository_id,
                source=getattr(args, role+'_commit'), run_id=getattr(args, role+'_run'),
                artifact_id=getattr(args, role+'_artifact'))
            write_json(args.output / (role+'-artifact.json'), identities[role])
        for pair in range(args.repetitions):
            order = ('baseline', 'candidate') if pair % 2 == 0 else ('candidate', 'baseline')
            for role in order:
                directory = args.output / f'{pair+1}-{role}'
                command = [sys.executable, str(repo / 'scripts/harness/perf/checkpoint_history_artifact_session.py'),
                    '--artifact', str(Path(temporary)/role), '--repo', str(repo), '--tracers', str(args.tracers),
                    '--cycles', str(args.cycles), '--histories', str(args.histories),
                    '--noise', str(args.noise), '--output', str(directory)]
                write_json(args.output / f'{pair+1}-{role}-command.json', command)
                run_child(command, args.output, f'{pair+1}-{role}-driver')
                results.append({'pair': pair+1, 'role': role, **validate(directory, identities[role], args.cycles, args.histories, args.noise)})
                validate_comparison(results)
    write_json(args.output / 'summary.json', results)
    (args.output / 'summary.md').write_text(render_summary(results))


def validate_comparison(results):
    require(bool(results), 'no comparison results')
    for field in ('fixture_sha256', 'histories', 'noise', 'cycles', 'interval_s'):
        require(all(row[field] == results[0][field] for row in results),
                f'comparison {field} differs')


def render_summary(results):
    validate_comparison(results)
    lines = ['# Checkpoint inventory comparison', '',
             f"Synthetic fixture: {results[0]['histories']} valid v11 histories and {results[0]['noise']} nonmatching entries; identical bytes.",
             f"Inventory samples per session: {results[0]['inventory']['n']}. HTTP p50 is the median; p95/p99 use nearest rank (ceil(n * quantile)). For 90 samples, p99 equals the maximum.",
             'HTTP times include scan, checkpoint decoding, response encoding and transport.',
             'Concurrent client starts do not prove overlap with directory sorting. Scheduler windows overlap; their percentiles are not pooled. Runtime-events domain 0 is the main domain.',
             'This experiment does not close task-611 or #25893.', '',
             '| Pair | Build | Inventory p50/p95/max ms | Health p50/p95/max ms | Scheduler p99/max ms |',
             '|---|---|---|---|---|']
    for row in results:
        def fmt(d): return '/'.join(f'{d[k]:.3f}' for k in ('p50_ms','p95_ms','max_ms'))
        s = row['scheduler']
        lines.append(f"| {row['pair']} | {row['role']} | {fmt(row['inventory'])} | {fmt(row['health'])} | {s.get('p99_ms')}/{s.get('max_ms')} |")
    lines += ['', '## Main-domain uninterrupted execution distribution', '',
              'Columns: domain, runs, run_ms, busy%, >=10ms, >=50ms, >=100ms, max_ms.', '', '```text']
    for row in results:
        lines.append(f"pair {row['pair']} {row['role']}: {row['domain_0']}")
    lines += ['```', '', 'Full per-domain GC/STW distributions and trace-loss counts are in each rtev_watch.txt.',
              'Raw responses, commands, hashes, host loads and cleanup receipts accompany each session.']
    return '\n'.join(lines)+'\n'


if __name__ == '__main__':
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    main()
