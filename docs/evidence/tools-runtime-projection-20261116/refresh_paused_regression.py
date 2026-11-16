#!/usr/bin/env python3
"""Refresh only the changed actual pause-detail predicate and its validation receipt."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('repo', 'out', 'opam-prefix', 'cmi-prefix', 'prior-typing', 'prior-result'):
        parser.add_argument('--'+key, type=Path, required=True)
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    if repo not in out.parents or out.relative_to(repo).parts[0] != 'artifacts':
        parser.error('use a fresh artifacts output directory')
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, PATH=str(args.opam_prefix/'bin')+os.pathsep+os.environ['PATH'])
    prior_raw = args.prior_result.read_bytes()
    receipt = json.loads(prior_raw)
    path = 'test/test_server_runtime_bootstrap.ml'
    raw = (repo/path).read_bytes()
    text = raw.decode()
    for key, digest in receipt['source_sha256'].items():
        if key.startswith('candidate:') and key != 'candidate:'+path:
            current = repo/key.split(':', 1)[1]
            if hashlib.sha256(current.read_bytes()).hexdigest() != digest:
                raise RuntimeError('unrelated source changed: '+str(current.relative_to(repo)))
    for name, digest in receipt['helpers_sha256'].items():
        if name != Path(__file__).name and hashlib.sha256((Path(__file__).parent/name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('original native helper changed: '+name)
    start = '        let static_paused_health projection ='
    block = start+text.split(start, 1)[1].split('        Alcotest.(check string) "Tools retains all static', 1)[0]
    predicate = 'let normalize projection=\nlet open Yojson.Safe.Util in\n'+block+'static_paused_health projection\n'
    fixture = '''
let detail elapsed=`Assoc["name",`String "held";"activation_mode",`String "autonomous";
 "pause_kind",`String "operator_paused";"missing_pause_root_cause",`Bool false;
 "paused_elapsed_sec",elapsed]
let observation details=`Assoc["paused_keepers_health",`Assoc[
 "count",`Int 1;"names",`List[`String "held"];"details",`List details;"read_errors",`List[]]]
let checks=ref 0
let expect label yes=incr checks;if not yes then failwith label
(* Malformed/invalid fixtures must reject; the exact validation exception is not a contract. *)
let rejects f=try ignore(f ());false with _->true
let ()=
 let before=normalize(observation[detail(`Float 12.25)]) in
 let after=normalize(observation[detail(`Float 12.75)]) in
 expect "distinct valid elapsed readings preserve static equality" (before=after);
 expect "zero elapsed is valid" (before=normalize(observation[detail(`Float 0.)]));
 List.iter(fun elapsed->expect "invalid elapsed rejects" (rejects(fun()->normalize(observation[detail elapsed]))))
   [`Float nan;`Float infinity;`Float neg_infinity;`Float (-0.01);`Null];
 expect "empty full details reject" (rejects(fun()->normalize(observation[])));
 let changed=`Assoc(List.map(fun(key,value)->key,if key="activation_mode" then `String "manual" else value)
   (Yojson.Safe.Util.to_assoc(detail(`Float 12.75)))) in
 expect "static detail differences remain visible" (before<>normalize(observation[changed]));
 let extra=`Assoc(("other_static_field",`String "retained")::Yojson.Safe.Util.to_assoc(detail(`Float 12.75))) in
 expect "additional static fields remain visible" (before<>normalize(observation[extra]));
 Printf.printf "{\\"checks\\":%d}\\n" !checks
'''
    (out/'predicate.ml').write_text(predicate+fixture)
    def execute(argv, label):
        result = subprocess.run(list(map(str, argv)), env=env, cwd=out, text=True, capture_output=True)
        (out/(label+'.stderr.txt')).write_text(result.stderr)
        (out/(label+'.stdout.txt')).write_text(result.stdout)
        return result
    version = execute(['ocamlopt','-version'], 'compiler').stdout.strip()
    if version != receipt['compiler']:
        raise RuntimeError('compiler differs from retained suite')
    result = execute(['ocamlfind','ocamlopt','-package','yojson,alcotest','-linkpkg',
                      '-w','+4+8+32+69','-warn-error','+4+8+32+69','predicate.ml','-o','predicate'], 'compile-predicate')
    if result.returncode:
        raise RuntimeError(result.stderr[-3000:])
    result = execute([out/'predicate'], 'predicate')
    if result.returncode:
        raise RuntimeError(result.stderr[-3000:])
    measured = json.loads(result.stdout.strip().splitlines()[-1])
    prefix = json.loads(args.cmi_prefix.read_bytes())
    prefix[0] = str(args.opam_prefix/'bin/ocamlc')
    prefix[prefix.index('-I')+1] = str(args.prior_typing.resolve())
    local = out/Path(path).name
    local.write_bytes(raw)
    parsed = execute(prefix+['-stop-after','parsing','-c',local.name], 'parse-regression')
    if parsed.returncode:
        raise RuntimeError(parsed.stderr[-3000:])
    typed = execute(prefix+['-thread','-c',local.name], 'type-regression')
    if typed.returncode and not ('make inconsistent assumptions' in typed.stderr
                                and 'Workspace_utils_paths_backend' in typed.stderr):
        raise RuntimeError(typed.stderr[-3000:])
    digest = hashlib.sha256(raw).hexdigest()
    receipt['source_sha256']['candidate:'+path] = digest
    record = next(x for x in receipt['actual_regression_checks'] if x['source']==path)
    record['sha256'] = digest
    attempt = next(x for x in record['typing_attempts'] if not x['baseline'])
    attempt.update(exit_code=typed.returncode, stderr_sha256=hashlib.sha256(typed.stderr.encode()).hexdigest())
    helper = Path(__file__)
    receipt['helpers_sha256'][helper.name] = hashlib.sha256(helper.read_bytes()).hexdigest()
    receipt['paused_regression_refresh'] = {'prior_result_sha256':hashlib.sha256(prior_raw).hexdigest(),
      'source_sha256':digest,'extracted_predicate_sha256':hashlib.sha256(predicate.encode()).hexdigest(),
      'native_checks':measured['checks'],'parse_exit_code':parsed.returncode,'typing_exit_code':typed.returncode,
      'limit':'Only the exact changed local test predicate ran with synthetic distinct elapsed observations. The full actual regression remains blocked by prebuilt dependency assumptions. The original 758 suite and six production checks were not rerun; their source bytes are unchanged.'}
    (out/'result.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt['paused_regression_refresh']))


if __name__ == '__main__':
    main()
