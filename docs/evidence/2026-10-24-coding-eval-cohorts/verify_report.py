#!/usr/bin/env python3
"""Run the actual coding report sources with fail-on-use dependency ports.

No Dune, server, provider, sandbox, or grading execution is involved. Full
Eval_harness, Coding_eval_case, Coding_eval_report and CLI sources are compiled;
ports cover unrelated runtime/grader dependencies and fail if called. The
selected Trajectory type/formatter fragments are copied from the actual source.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess

BASE = '8eac5c07c290d134a9ef6acb1e298584bf9a1366'
SOURCES = {
    'json_util.ml': 'lib/core/json_util.ml',
    'list_util.ml': 'lib/core/list_util.ml',
    'eval_harness.mli': 'lib/eval_harness.mli',
    'eval_harness.ml': 'lib/eval_harness.ml',
    'keeper_operation_id.mli': 'lib/keeper_operation_identity/keeper_operation_id.mli',
    'keeper_operation_id.ml': 'lib/keeper_operation_identity/keeper_operation_id.ml',
    'coding_eval_case.ml': 'test/coding_eval_case.ml',
    'coding_eval_report.ml': 'test/coding_eval_report.ml',
    'coding_eval_report_cli.ml': 'test/coding_eval_report_cli.ml',
}
PORTS = {
    'shared_types.ml': 'module Json_kind = struct let name _ = failwith \"unused JSON kind port\" end\n',
    'string_util.ml': 'let utf8_prefix ~max_bytes:_ _ = failwith \"unused UTF8 prefix port\"\n',
    'eio.ml': 'module Cancel = struct exception Cancelled of exn end\n',
    'safe_ops.ml': 'let protect ~default:_ _ = failwith "unused Safe_ops port"\n',
    'fs_compat.ml': 'let load_file _ = failwith "unused Fs_compat port"\n',
    'eval_tool_selector.ml': '''type t = unit
type call = { tool_name : string; route_evidence : unit option }
let label _ = failwith "unused selector label port"
let matches _ _ = failwith "unused selector matching port"
let of_yojson _ : (t, string) result = failwith "unused selector decoder port"
''',
    'masc.ml': 'module Eval_harness = Eval_harness\nmodule Trajectory = Trajectory\n',
}
ORDER = ['shared_types.ml', 'string_util.ml', 'eio.ml', 'safe_ops.ml', 'fs_compat.ml', 'eval_tool_selector.ml',
         'trajectory.ml', 'json_util.ml', 'list_util.ml', 'eval_harness.mli',
         'eval_harness.ml', 'masc.ml', 'keeper_operation_id.mli',
         'keeper_operation_id.ml', 'coding_eval_case.ml', 'coding_eval_report.ml']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=pathlib.Path, required=True)
    parser.add_argument('--out', type=pathlib.Path, required=True)
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    manifest, observations = {}, {}

    def source(path, baseline):
        if baseline:
            return subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=repo)
        return (repo / path).read_bytes()

    def run(command, cwd, logfile, expected=0):
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
        logfile.write_text(result.stdout + result.stderr)
        if result.returncode != expected:
            raise RuntimeError(f'{command}: exit={result.returncode}; see {logfile}')
        return result

    for name, baseline in [('baseline', True), ('candidate', False)]:
        work = out / name
        work.mkdir()
        identities = {}
        for filename, path in SOURCES.items():
            data = source(path, baseline)
            (work / filename).write_bytes(data)
            identities[path] = hashlib.sha256(data).hexdigest()
        for filename, data in PORTS.items():
            (work / filename).write_text(data)
        trajectory = source('lib/trajectory/trajectory.ml', baseline).decode()
        type_part = trajectory[trajectory.index('type trajectory_outcome ='):trajectory.index('type trajectory =')]
        format_start = trajectory.index('let outcome_to_string =')
        format_end = trajectory.index('\nlet ', format_start + 1)
        format_part = trajectory[format_start:format_end]
        (work / 'trajectory.ml').write_text(type_part + '\n' + format_part + '\n')
        identities['lib/trajectory/trajectory.ml'] = hashlib.sha256(trajectory.encode()).hexdigest()
        manifest[name] = {'source_sha256': identities, 'ports': PORTS,
                          'trajectory_fragments': {'type': type_part, 'formatter': format_part}}
        policies = {}
        for filename in ORDER:
            strict = not baseline and filename in ('eval_harness.ml', 'eval_harness.mli', 'coding_eval_report.ml')
            warning_errors = '+a' if strict else '-a'
            policies[filename] = warning_errors
            run(['ocamlfind', 'ocamlc', '-package', 'yojson,re.pcre', '-w', '+4+32+69',
                 '-warn-error', warning_errors, '-c', filename], work, work / (filename + '.compile.log'))
        manifest[name]['warning_errors'] = policies
        objects = [str(pathlib.Path(filename).with_suffix('.cmo')) for filename in ORDER
                   if filename.endswith('.ml')]
        run(['ocamlfind', 'ocamlc', '-package', 'yojson,re.pcre', '-linkpkg',
             *objects, 'coding_eval_report_cli.ml', '-o', 'report-cli'],
            work, work / 'link.log')
        if not baseline:
            tests = source('test/test_coding_eval_cases.ml', baseline)
            (work / 'test_coding_eval_cases.ml').write_bytes(tests)
            identities['test/test_coding_eval_cases.ml'] = hashlib.sha256(tests).hexdigest()
            run(['ocamlfind', 'ocamlc', '-package', 'yojson,re.pcre,alcotest',
                 '-linkpkg', '-w', '+4+32+69', '-warn-error', '+a', *objects,
                 'test_coding_eval_cases.ml', '-o', 'report-regressions'],
                work, work / 'regression-compile.log')
            (work / 'test-logs').mkdir()
            run([str(work / 'report-regressions'), 'test', '--color=never',
                 '--show-errors', '-o', str(work / 'test-logs'), 'report', '0-4,10-17'],
                repo, work / 'regression-run.log')
            observations['report_regressions_passed'] = 13

    def row(model, index, passed, cost, digest='a' * 64, memory='off'):
        return dict(case_id='l1-calc-add', run_index=index, run_id=f'{model}-r{index}',
                    provider='fixture', model=model, experiment_digest=digest,
                    memory_mode=memory, status='ok', verify_exit=0 if passed else 1,
                    regression_exit=None, passed=passed, duration_ms=100,
                    recorded_at=1700000000, tool_calls=[], input_tokens=None,
                    output_tokens=None, cost_usd=cost, error=None)

    def report(name, case, rows):
        work = out / name
        inputs = work / (case + '.jsonl')
        if name == 'baseline':
            rows = [{key: value for key, value in item.items()
                     if key not in ('experiment_digest', 'memory_mode')} for item in rows]
        inputs.write_text(''.join(json.dumps(item) + '\n' for item in rows))
        destination = work / case
        run([str(work / 'report-cli'), '--cases', str(repo / 'benchmarks/coding/cases'),
             '--runs', str(inputs), '--out', str(destination)], work, work / (case + '.log'))
        return json.loads((destination / 'report.json').read_text())

    mixed = [row('model-a', index, True, 0.1) for index in range(1, 6)] + [
        row('model-b', index, False, 0.2) for index in range(1, 6)]
    baseline = report('baseline', 'mixed-models', mixed)
    candidate = report('candidate', 'mixed-models', mixed)
    assert len(baseline['results']) == 1 and baseline['results'][0]['pass_at_k'] == 0.5
    assert len(candidate['cohorts']) == 2 and 'overall_pass_rate' not in candidate
    by_model = {cohort['model']: cohort for cohort in candidate['cohorts']}
    assert by_model['model-a']['results'][0]['pass_at_k'] == 1
    assert by_model['model-b']['results'][0]['pass_at_k'] == 0
    assert abs(by_model['model-a']['cost']['cost_per_solved_task_usd'] - 0.1) < 1e-12
    assert by_model['model-b']['cost']['cost_per_solved_task_usd'] is None
    observations['model_split'] = {'baseline_pooled_pass_at_k': 0.5,
                                    'candidate_model_a': 1, 'candidate_model_b': 0}

    partial = [row('model-a', 1, True, 1.0), row('model-a', 2, False, None)]
    baseline = report('baseline', 'partial-cost', partial)
    candidate = report('candidate', 'partial-cost', partial)
    assert baseline['results'][0]['total_cost_usd'] == 1.0
    costs = candidate['cohorts'][0]['cost']
    assert costs['known_cost_usd'] == 1 and costs['observed_runs'] == 1 and costs['unreported_runs'] == 1
    assert costs['total_cost_usd'] is None and costs['cost_per_solved_task_usd'] is None
    assert candidate['cohorts'][0]['results'][0]['cost']['total_cost_usd'] is None
    observations['partial_cost'] = {'baseline_partial_total': 1.0, 'candidate_total': None,
                                    'candidate_observed': 1, 'candidate_unreported': 1}

    complete = report('candidate', 'failed-spend', [row('model-a', 1, True, 1.0), row('model-a', 2, False, 2.0)])
    assert complete['cohorts'][0]['cost']['cost_per_solved_task_usd'] == 3.0
    observations['failed_spend_included'] = 3.0
    dimensions = [row('model-a', 1, True, 1.0), row('model-a', 1, False, 2.0, digest='b' * 64),
                  row('model-a', 1, False, 2.0, memory='seeded')]
    candidate = report('candidate', 'separate-experiments', dimensions)
    assert len(candidate['cohorts']) == 3
    assert all(cohort['total_runs'] == 1 and not cohort['results'][0]['min_runs_met']
               for cohort in candidate['cohorts'])
    observations['experiment_memory_cohorts'] = 3

    manifest['compiler'] = subprocess.check_output(['ocamlc', '-version'], text=True).strip()
    manifest['baseline_commit'] = BASE
    manifest['corpus_case_sha256'] = {
        str(path.relative_to(repo)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted((repo / 'benchmarks/coding/cases').rglob('case.json'))
    }
    manifest['scope'] = 'Actual full report/case/eval sources and actual CLI, with explicit fail-on-use ports; not native MASC, provider, sandbox, Dune or CI'
    (out / 'source-manifest.json').write_text(json.dumps(manifest, indent=2))
    (out / 'observations.json').write_text(json.dumps(observations, indent=2))
    print(json.dumps({'out': str(out), 'observations': observations}))


if __name__ == '__main__':
    main()
