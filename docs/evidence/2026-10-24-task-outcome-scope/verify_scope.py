#!/usr/bin/env python3
"""Execute actual Task aggregation/component source with an explicit input port.

This does not execute workspace hooks, persistence, telemetry or Goal policy.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

BASE = '3e8a9f3f26f841ad9fc7508555f07e84e19a5ff5'
PACKAGES = 'yojson,ppx_deriving_yojson,ppx_deriving.show'
INPUT_PORT = '''let fixture_rows : task_metric list ref = ref []
let read_recent () ~agent_id:_ ~days:_ = Ok (1000.0, !fixture_rows)
'''
HARNESS = '''let row ~task_id ~success ~completed_at : Metrics_store_eio.task_metric =
  { id = task_id; agent_id = "producer"; task_id; started_at = 100.0;
    completed_at; success; error_message = None; collaborators = [];
    handoff_from = None; handoff_to = None }
let report rows =
  Metrics_store_eio.fixture_rows := rows;
  match Metrics_store_eio.calculate_agent_metrics () ~agent_id:"producer" ~days:7 with
  | Ok (Some metrics) ->
    `Assoc ["metrics", Metrics_store_eio.agent_metrics_to_yojson metrics;
            "components", Tool_components.components_for ~min_avg:(Some 1.0) metrics]
  | Ok None | Error _ -> failwith "fixture aggregation failed"
let () =
  let approved = row ~task_id:"approved" ~success:true ~completed_at:(Some 101.0) in
  let cancelled = row ~task_id:"cancelled" ~success:false ~completed_at:(Some 102.0) in
  let pending = row ~task_id:"pending" ~success:false ~completed_at:None in
  let json = `Assoc ["approved", report [approved];
                     "mixed", report [approved;cancelled];
                     "pending", report [pending]] in
  print_endline (Yojson.Safe.to_string json)
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    manifest, outputs = {}, {}

    def source(path, baseline):
        if baseline:
            return subprocess.check_output(['git', 'show', f'{BASE}:{path}'], cwd=repo).decode()
        return (repo / path).read_text()

    def run(command, work, log):
        result = subprocess.run(command, cwd=work, capture_output=True, text=True)
        log.write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f'exit {result.returncode}: {command}; see {log}')
        return result.stdout

    for name, baseline in [('baseline', True), ('candidate', False)]:
        work = out / name
        work.mkdir()
        hashes, fragments = {}, {}

        def retain(path):
            data = source(path, baseline)
            hashes[path] = hashlib.sha256(data.encode()).hexdigest()
            return data

        metric = retain('lib/metrics_store_eio.ml')
        types = metric[metric.index('type task_metric ='):metric.index('(** Config type alias for clarity *)')]
        aggregate = metric[metric.index('module Task_map ='):metric.index('(** Successful inventory includes only observed agent directories. *)')]
        fragments['metric_types'] = types
        fragments['metric_aggregation'] = aggregate
        (work / 'metrics_store_eio.ml').write_text(types + '\nlet ( let* ) = Result.bind\n' + INPUT_PORT + aggregate)
        tool = retain('lib/tool_agent.ml')
        components = tool[tool.index('let components_for '):tool.index('(** Handle masc_agent_fitness.')]
        fragments['fitness_components'] = components
        (work / 'tool_components.ml').write_text(components)
        (work / 'masc_time_constants.ml').write_text(retain('lib/config/masc_time_constants.ml'))
        order = ['masc_time_constants.ml']
        if not baseline:
            for path in ('lib/types/task_outcome_measurement.mli', 'lib/types/task_outcome_measurement.ml'):
                (work / Path(path).name).write_text(retain(path))
                order.append(Path(path).name)
        order += ['metrics_store_eio.ml', 'tool_components.ml']
        for filename in order:
            run(['ocamlfind', 'ocamlc', '-package', PACKAGES, '-w', '+4+32+69',
                 '-warn-error', '+a', '-c', filename], work, work / (filename + '.compile.txt'))
        objects = [str(Path(filename).with_suffix('.cmo')) for filename in order if filename.endswith('.ml')]
        (work / 'probe.ml').write_text(HARNESS)
        run(['ocamlfind', 'ocamlc', '-package', PACKAGES, '-linkpkg', *objects,
             'probe.ml', '-o', 'scope-probe'], work, work / 'link.txt')
        raw = run([str(work / 'scope-probe')], work, work / 'probe-output.json')
        outputs[name] = json.loads(raw)
        if not baseline:
            (work / 'test_task_outcome_measurement.ml').write_text(retain('test/test_task_outcome_measurement.ml'))
            run(['ocamlfind', 'ocamlc', '-package', 'yojson,alcotest', '-linkpkg',
                 '-w', '+4+32+69', '-warn-error', '+a', 'task_outcome_measurement.cmo',
                 'test_task_outcome_measurement.ml', '-o', 'scope-tests'],
                work, work / 'test-compile.txt')
            (work / 'test-logs').mkdir()
            run([str(work / 'scope-tests'), '--color=never', '--show-errors',
                 '-o', str(work / 'test-logs')], work, work / 'test-run.txt')
        manifest[name] = {'source_sha256': hashes, 'fragments': fragments}

    before, after = outputs['baseline'], outputs['candidate']
    assert before['approved']['components']['reliability'] == 1
    assert 'outcome_basis' not in before['approved']['metrics']
    for scenario, completed, success in [('approved', 1, 1), ('mixed', 2, 0.5), ('pending', 0, None)]:
        metrics, components = after[scenario]['metrics'], after[scenario]['components']
        assert metrics['outcome_basis'] == 'task_lifecycle'
        assert metrics['external_acceptance'] == {'kind': 'unobserved', 'completed_tasks': completed}
        assert components['task_lifecycle_success'] == success and 'reliability' not in components
    manifest.update(baseline_commit=BASE, input_port=INPUT_PORT, probe=HARNESS,
                    compiler=subprocess.check_output(['ocamlc', '-version'], text=True).strip(),
                    scope='Actual aggregation/component fragments, full new observation module and focused tests; input rows injected at read_recent; no producer hook, event, persistence, Goal policy, Dune, CI or live proof')
    (out / 'source-manifest.json').write_text(json.dumps(manifest, indent=2))
    (out / 'observations.json').write_text(json.dumps(outputs, indent=2))
    print(json.dumps({'out': str(out), 'focused_tests_passed': 2,
                      'approved_lifecycle_success': 1, 'external_acceptance': 'unobserved'}))


if __name__ == '__main__':
    main()
