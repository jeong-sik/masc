#!/usr/bin/env python3
"""Execute exact projection bodies with deterministic effect ports; type actual modules."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('repo', 'out', 'opam-prefix', 'cmi-prefix'):
        parser.add_argument('--'+key, type=Path, required=True)
    parser.add_argument('--base', required=True)
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    if repo not in out.parents or out.relative_to(repo).parts[0] != 'artifacts':
        parser.error('output must be a new directory under repo/artifacts')
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, PATH=str(args.opam_prefix/'bin')+os.pathsep+os.environ['PATH'])
    hashes = {}

    def run(argv, label, cwd=out):
        result = subprocess.run(list(map(str, argv)), env=env, cwd=cwd, text=True, capture_output=True)
        (out/(label+'.stdout.txt')).write_text(result.stdout)
        (out/(label+'.stderr.txt')).write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(label+': '+result.stderr[-5000:])
        return result.stdout

    def source(path, baseline=False):
        raw = subprocess.check_output(['git','-C',str(repo),'show',args.base+':'+path]) if baseline else (repo/path).read_bytes()
        hashes[('baseline:' if baseline else 'candidate:')+path] = hashlib.sha256(raw).hexdigest()
        return raw.decode()

    def extract(text, start, stop):
        return start+text.split(start, 1)[1].split(stop, 1)[0]

    version = run(['ocamlopt','-version'], 'compiler').strip()
    if version != '5.5.2':
        raise RuntimeError('OCaml5.5.2 required')
    directory = Path(__file__).parent
    ports = (directory/'ports.ml').read_text()
    pieces = [ports]
    for baseline, suffix in [(True, 'baseline'), (False, 'candidate')]:
        fleet = source('lib/server/server_routes_http_runtime_health_fleet.ml', baseline)
        base_fields = extract(fleet, 'let keeper_fleet_runtime_resolution_base_fields', 'let fd_accountant_snapshot_json')
        full_start = 'let keeper_fleet_runtime_resolution_fields' if baseline else 'let full_runtime_resolution_fields'
        full = extract(fleet, full_start, 'let keeper_fleet_runtime_resolution_light_fields')
        pieces.append('module Fleet_'+suffix+' = struct\nopen Ports\n'+base_fields+full+'end\n')
        runtime = source('lib/server/server_dashboard_http_runtime_info.ml', baseline)
        runtime_start = 'let runtime_resolution_json (' if baseline else 'let runtime_resolution_json_with_fleet_fields'
        resolution = extract(runtime, runtime_start, 'let light_runtime_resolution_json')
        tools = extract(runtime, 'let dashboard_tools_cache_ttl_sec', 'let dashboard_tools_http_json')
        pieces.append('module '+suffix.capitalize()+' = struct\nmodule Server_routes_http_runtime=Fleet_'+suffix+'\n'+resolution+tools+'end\n')
    health = source('lib/server/server_routes_http_runtime.ml')
    section = extract(health, '  let reaction_ledger_json =', '  let keeper_waiting_inventory_json =')
    pieces.append('let compute_section ~name:_ ?section_timings_ref:_ f=f ()\n'
                  'let full_health_ledger_section ~execution_snapshot ()=\nlet section_timings_ref=None in\n'+section+'reaction_ledger_json\n')
    pieces.append((directory/'cases.ml').read_text())
    (out/'probe.ml').write_text('\n'.join(pieces))
    run(['ocamlfind','ocamlopt','-g','-package','yojson','-linkpkg','-w','+4+8+32+69',
         '-warn-error','+4+8+32+69','probe.ml','-o','probe'], 'compile-native')
    measured = json.loads(run([out/'probe'], 'native'))

    prefix_raw = args.cmi_prefix.read_bytes()
    prefix = json.loads(prefix_raw)
    prefix[0] = str(args.opam_prefix/'bin/ocamlc')
    typing = out/'actual-typing'
    typing.mkdir()
    prefix[prefix.index('-I')+1] = str(typing)
    checks = []
    modules = ['server_routes_http_runtime_health_fleet', 'server_routes_http_runtime',
               'server_dashboard_http_runtime_info']
    # These actual masc_server units are unwrapped. Compile their changed CMIs
    # first in the isolated current directory, ahead of dependency artifacts.
    for module in modules:
        for ext in ('mli','ml'):
            path = 'lib/server/'+module+'.'+ext
            raw = source(path)
            local = typing/(module+'.'+ext)
            local.write_text(raw)
            run(prefix+['-thread','-c',local.name], 'typing-'+module+'.'+ext, cwd=typing)
            checks.append({'source':path,'sha256':hashlib.sha256(raw.encode()).hexdigest(),
                           'fatal_warnings':[4,8,32,69],'exit_code':0})
    regression_checks = []
    baseline_typing = out/'baseline-test-typing'
    baseline_typing.mkdir()
    for path in ['test/test_server_runtime_bootstrap.ml','test/test_dashboard_http_core.ml']:
        attempts = []
        for baseline in (True, False):
            raw = source(path, baseline)
            target_dir = baseline_typing if baseline else typing
            local = target_dir/Path(path).name
            local.write_text(raw)
            command = prefix.copy()
            command[command.index('-I')+1] = str(target_dir)
            result = subprocess.run(command+['-thread','-c',local.name], env=env, cwd=target_dir,
                                    text=True, capture_output=True)
            label = ('baseline-' if baseline else 'candidate-')+local.stem
            (out/(label+'.stderr.txt')).write_text(result.stderr)
            if result.returncode and not ('make inconsistent assumptions' in result.stderr
                                          and 'Workspace_utils_paths_backend' in result.stderr):
                raise RuntimeError(label+': '+result.stderr[-4000:])
            attempts.append({'baseline':baseline,'exit_code':result.returncode,
                             'stderr_sha256':hashlib.sha256(result.stderr.encode()).hexdigest()})
        run(prefix+['-stop-after','parsing','-c',local.name], 'parse-'+local.stem, cwd=typing)
        regression_checks.append({'source':path,'sha256':hashlib.sha256(raw.encode()).hexdigest(),
          'typing_attempts':attempts,'parse_exit_code':0,
          'typing_limit':'Both baseline and candidate stop at prebuilt dependency assumptions over Workspace_utils_paths_backend. Whole regression typing/execution is not certified.'})
    consumers = [
      'dashboard/src/api/dashboard-tools-prompts.ts', 'dashboard/src/types/dashboard-execution.ts',
      'dashboard/src/components/tools/tool-state.ts', 'dashboard/src/components/tools/tools-main.ts',
      'dashboard/src/components/tools/config-resolution-panel.ts',
      'dashboard/src/components/schedule/schedule-surface.ts', 'dashboard/src/store.ts',
      'dashboard/src/store-normalizers.ts', 'lib/tui_decode_tools.ml', 'bin/masc_tui_loader.ml',
      'bin/masc_tui_http.ml', 'scripts/keeper-waiting-inventory.sh',
      'scripts/harness/workload/keeper_skill_use_proof.py',
      'scripts/harness/workload/join_natural_keeper_skill_ledger.py',
      'scripts/harness/perf/response_latency_probe.py',
      'lib/server/server_routes_http_routes_dashboard.ml', 'lib/server/server_dashboard_snapshot_select.ml',
      'lib/server/server_dashboard_snapshot_sources.ml']
    for path in consumers:
        source(path)
    result = {'schema':'tools-runtime-projection-proof.v1','base':args.base,'compiler':version,
              'source_sha256':hashes,'actual_cmi_prefix_sha256':hashlib.sha256(prefix_raw).hexdigest(),
              'actual_cmi_typing':checks,'actual_regression_checks':regression_checks,**measured,
              'helpers_sha256':{name:hashlib.sha256((directory/name).read_bytes()).hexdigest()
                                for name in ('replay.py','ports.ml','cases.ml')},
              'limits':['Exact baseline/candidate fleet base/full builders, complete full runtime builders, and complete Tools producer/cache-selection/decorating bodies execute.',
                        'All filesystem, clock, build, diagnostics, metadata, profile, metric, scheduler/cache and ledger leaf ports are deterministic fixtures; no actual durable ledger reader or real cache/scheduler ran.',
                        'The unchanged full-health ledger section is extracted and executed, not the complete full-health endpoint.',
                        'Six actual interfaces/complete module checks type against existing dependencies with fresh changed masc_server CMIs; no complete product link.',
                        'Two actual regression files parse. Their complete typing is blocked at both baseline and candidate by inconsistent prebuilt Workspace_utils_paths_backend assumptions; no regression executable ran.',
                        'Synthetic payload/allocation observations exclude real metadata/JSONL work and do not measure runtime CPU gain or refresh frequency.',
                        'No Dune/full build/CI, live runtime/provider/cursor/capture operations, install or restart.']}
    (out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'assertions':measured['native_assertions'],'typed':len(checks),'measurements':measured['measurements']}))


if __name__ == '__main__':
    main()
