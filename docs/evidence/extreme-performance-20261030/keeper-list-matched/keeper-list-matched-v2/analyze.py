"""Retrospective v1 qualification and unrounded raw native phase distributions."""
import argparse
import hashlib
import json
from pathlib import Path
from qualify import qualify_arm


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    return {'samples': len(values), 'p50_ns': values[int(.5 * (len(values)-1) + .5)],
            'p95_ns': values[int(.95 * (len(values)-1) + .5)], 'max_ns': values[-1]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--matrix', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    capture = json.loads((args.matrix / 'execution.json').read_text())
    records = []
    predecessors_clean = True
    previous_end = None
    for execution in capture['records']:
        case = f"owners-{execution['population']}-{execution['variant']}"
        directory = args.matrix / 'runs' / case
        qualification = qualify_arm(directory, execution, config['variants'][execution['variant']])
        chronology = previous_end is None or execution['started_unix'] >= previous_end
        qualification['prior_arms_cleanup_confirmed'] = predecessors_clean
        qualification['sequential_execution_receipts'] = chronology
        qualification['retrospectively_eligible'] = qualification['eligible'] and predecessors_clean and chronology
        predecessors_clean = predecessors_clean and qualification['next_arm_safe'] and chronology
        previous_end = execution['ended_unix']
        raw = [json.loads(line) for line in (directory / 'tui-observer/frame-timing.txt').read_text().splitlines()
               if line.startswith('{')]
        frames = [r for r in raw if r.get('schema') == 'masc.tui.frame.v2']
        observation = json.loads((directory / 'tui-observer/observation.json').read_text())
        summary = json.loads((directory / 'summary.json').read_text())
        records.append({
            'case': case, 'population': execution['population'], 'variant': execution['variant'],
            'source': execution['source_actual'], 'qualification': qualification,
            'list_build': distribution([int(r['elapsed_ns']) for r in frames if r.get('phase') == 'build' and r.get('surface') == 'keeper-list']),
            'all_present': distribution([int(r['elapsed_ns']) for r in frames if r.get('phase') == 'present']),
            'whole_tui_cpu_seconds': observation['user_cpu_seconds'] + observation['system_cpu_seconds'],
            'whole_tui_wall_seconds': (int(observation['ended_ns']) - int(observation['started_ns'])) / 1e9,
            'loadavg_before': execution['loadavg_before'], 'loadavg_after': execution['loadavg_after'],
            'cpu_count': execution['cpu_count'], 'workload_summary': summary,
        })
    value = {
        'scope': 'One unsampled owned native arm per population/source, matched observer inputs; retrospective v1 qualification, not a prospective cleanup gate. Whole binaries differ; shared host not quiesced. No causal speedup, stable fleet quantile, UI row cardinality, key application, paint or 100us completion claim.',
        'quantile': 'Sorted values at int(q*(n-1)+0.5); exact raw integer nanoseconds.',
        'matrix_execution_sha256': hashlib.sha256((args.matrix / 'execution.json').read_bytes()).hexdigest(),
        'config_sha256': hashlib.sha256(args.config.read_bytes()).hexdigest(),
        'records': records,
    }
    with args.output.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


if __name__ == '__main__':
    main()
