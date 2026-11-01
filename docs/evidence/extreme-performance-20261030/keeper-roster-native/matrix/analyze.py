import argparse
import hashlib
import json
import sys
from pathlib import Path


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return None
    return {'samples': len(ordered), 'p50_ns': ordered[int(.5 * (len(ordered) - 1) + .5)],
            'p95_ns': ordered[int(.95 * (len(ordered) - 1) + .5)], 'max_ns': ordered[-1]}


parser = argparse.ArgumentParser()
parser.add_argument('--matrix', type=Path, required=True)
parser.add_argument('--support', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
sys.path.insert(0, str(args.support.resolve()))
from qualify import qualify_arm

raw = (args.matrix / 'execution.json').read_bytes()
capture = json.loads(raw)
records = []
previous_end = None
predecessors_safe = True
for item in capture['records']:
    execution = item['execution']
    case = f"owners-{execution['population']}-{execution['variant']}"
    directory = args.matrix / 'runs' / case
    qualification = qualify_arm(directory, execution, capture['config']['variants'][execution['variant']])
    chronology = previous_end is None or execution['started_unix'] >= previous_end
    admitted = qualification['eligible'] and predecessors_safe and chronology
    report = directory / 'tui-observer/frame-timing.txt'
    frames = [json.loads(line) for line in report.read_text().splitlines() if line.startswith('{')]
    frames = [row for row in frames if row.get('schema') == 'masc.tui.frame.v2']
    observation = json.loads((directory / 'tui-observer/observation.json').read_text())
    summary_path, failure_path = directory / 'summary.json', directory / 'failure.json'
    records.append({'case': case, 'population': execution['population'], 'variant': execution['variant'],
                    'source': execution['source_actual'], 'returncode': execution['returncode'],
                    'qualification': qualification, 'predecessors_safe': predecessors_safe,
                    'sequential_execution_receipts': chronology, 'arm_eligible': admitted,
                    'native_list_build': distribution([int(row['elapsed_ns']) for row in frames
                                                      if row.get('phase') == 'build' and row.get('surface') == 'keeper-list']),
                    'native_all_present': distribution([int(row['elapsed_ns']) for row in frames if row.get('phase') == 'present']),
                    'whole_tui_cpu_seconds': observation['user_cpu_seconds'] + observation['system_cpu_seconds'],
                    'whole_tui_wall_seconds': (int(observation['ended_ns']) - int(observation['started_ns'])) / 1e9,
                    'workload_summary': json.loads(summary_path.read_text()) if summary_path.exists() else None,
                    'failure': json.loads(failure_path.read_text()) if failure_path.exists() else None,
                    'loadavg_before': execution['loadavg_before'], 'loadavg_after': execution['loadavg_after'],
                    'cpu_count': execution['cpu_count'],
                    'frame_report_sha256': hashlib.sha256(report.read_bytes()).hexdigest()})
    predecessors_safe = predecessors_safe and qualification['next_arm_safe'] and chronology
    previous_end = execution['ended_unix']
for record in records:
    peers = [row for row in records if row['population'] == record['population']]
    record['pair_comparison_eligible'] = (len(peers) == 2 and
        {row['variant'] for row in peers} == {'control', 'candidate'} and
        all(row['arm_eligible'] for row in peers))
value = {'scope': 'Six-arm native workload matrix. The invoked controller path applied source/resource checks before expansion; current raw reports are requalified here. Controller/qualifier bytes were not independently pinned at invocation; listed support hashes are read at analysis time. Failed workload arms retain timings as diagnostics only. One arm per source/population, uncontrolled shared host, differing build wrappers/dependency provenance. No causal/stable fleet speedup, applied UI cardinality/key/physical paint or 100us completion claim.',
         'matrix_passed': capture['passed'], 'quantile': 'sorted[int(q*(n-1)+0.5)] over exact raw integer nanoseconds',
         'matrix_execution_sha256': hashlib.sha256(raw).hexdigest(),
         'analysis_source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
         'support_read_after_sha256': {name: hashlib.sha256((args.support / name).read_bytes()).hexdigest()
                                       for name in ['run.py', 'qualify.py', 'probe/tui_observer.py']},
         'records': records}
with args.output.open('x') as stream:
    json.dump(value, stream, indent=2)
    stream.write('\n')
for record in records:
    print(json.dumps({key: record[key] for key in ['case', 'returncode', 'arm_eligible', 'pair_comparison_eligible', 'native_list_build', 'whole_tui_cpu_seconds', 'failure']}))
