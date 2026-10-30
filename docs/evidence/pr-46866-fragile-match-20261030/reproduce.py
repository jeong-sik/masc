#!/usr/bin/env python3
"""Reproduce PR #46866's warning-4 regression with extracted source and stubs."""
import argparse
import hashlib
import json
import platform
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base-sha', required=True, help='full 40-digit baseline Git commit')
parser.add_argument('--expected-source-sha256', required=True, help='expected modified runtime file SHA-256')
parser.add_argument('--output', required=True, help='new receipt path, outside this evidence bundle')
args = parser.parse_args()
if not re.fullmatch(r'[0-9a-f]{40}', args.base_sha):
    parser.error('--base-sha must be a full lowercase 40-digit Git commit')
if not re.fullmatch(r'[0-9a-f]{64}', args.expected_source_sha256):
    parser.error('--expected-source-sha256 must be 64 lowercase hexadecimal digits')
root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()).resolve()
output = Path(args.output).resolve()
bundle = Path(__file__).resolve().parent
if output.is_relative_to(bundle):
    parser.error('new output must be outside the retained evidence bundle')
if output.exists():
    parser.error('output already exists; choose a new receipt path')
output.parent.mkdir(parents=True, exist_ok=True)
version = subprocess.check_output(['ocamlc', '-version'], text=True).strip()
if version != '5.5.1':
    raise RuntimeError('expected OCaml 5.5.1, got ' + version)
runtime_file = 'lib/keeper/keeper_turn_sandbox_runtime.ml'
cli_file = 'lib/keeper/keeper_microvm_cli_output.ml'
def git_file(filename):
    return subprocess.check_output(['git', 'show', args.base_sha + ':' + filename], cwd=root)
current_bytes = (root / runtime_file).read_bytes()
current_sha = hashlib.sha256(current_bytes).hexdigest()
if current_sha != args.expected_source_sha256:
    raise RuntimeError('modified runtime source hash differs from --expected-source-sha256')
previous_bytes = git_file(runtime_file)
cli_bytes = (root / cli_file).read_bytes()
if cli_bytes != git_file(cli_file):
    raise RuntimeError('baseline and working-tree CLI output types differ; extraction is not comparable')
current, previous, cli = (content.decode('utf-8') for content in (current_bytes, previous_bytes, cli_bytes))
def part(source, start, end):
    pos = source.index(start)
    return source[pos:source.index(end, pos)]
cli_types = part(cli, 'type unavailable_output =', 'let release_capture_directory')
cli_messages = cli[cli.index('let unavailable_message ='):]
header = '''module Keeper_microvm_backend = struct type t = Apple_container end
module Keeper_sandbox_microvm = struct
  type build_link_row = { plan : unit }
  let targets = ref []
  let actions = ref []
  let keeper_work_root ~keeper_name:_ = "/guest"
  let build_scan_argv_for _ ~container_name:_ ~keeper_work_root:_ ~uid:_ ~gid:_ = ["scan"]
  let build_scan_rows_of_output _ = Ok []
  let build_link_rows_of_scan _ = []
  let build_link_warning _ = None
  let build_link_actions _ = !actions
  let build_link_targets _ = !targets
  let build_target_mkdir_request ~container_name:_ ~targets:_ = (["mkdir"], "mkdir-input")
  let build_link_apply_request_for _ ~container_name:_ ~keeper_work_root:_ ~uid:_ ~gid:_ ~actions:_ =
    (["link"], "link-input")
end
module Keeper_microvm_cli_output = struct
''' + cli_types + '''
let observed : (Unix.process_status * string * string, error) result ref = ref (Ok (Unix.WEXITED 0, "", ""))
let read_with_environment ?timeout_sec:_ ~stdout_limit:_ ~stderr_limit:_ ~env:_ ~cwd:_ ~argv:_ () = !observed
''' + cli_messages + '''
end
module Fd_accountant = struct type kind = Docker_spawn let observe ~kind:_ f = f () end
module Common = struct let max_process_capture_head_bytes = 4096 let max_process_capture_tail_bytes = 4096 end
module Config_dir_resolver = struct let current_working_dir () = "/fixture" end
module Keeper_sandbox_exec_failure = struct
  let status_label = function Unix.WEXITED n -> string_of_int n | Unix.WSIGNALED _ -> "signal" | Unix.WSTOPPED _ -> "stopped"
end
module Log = struct
  module Keeper = struct
    let messages = ref []
    let warn ~keeper_name:_ format = Printf.ksprintf (fun message -> messages := message :: !messages) format
  end
end
let sandbox_environment () = [||]
type meta = {name:string}
type t = {meta:meta; uid:int; gid:int}
let effects = ref []
let effect_hook = ref (fun () -> ())
let effect_status = ref (Unix.WEXITED 0)
let run_build_link_effect ?timeout_sec:_ ~stdin_content:_ argv =
  effects := argv :: !effects; !effect_hook (); !effect_status
'''
checks = '''
let contains needle text = Astring.String.is_infix ~affix:needle text
let assert_state name expected =
  match microvm_work_root_entry name with
  | Some entry -> assert (entry.build_links_state = expected)
  | None -> failwith "missing guest state"
let () =
  let module C = Keeper_microvm_cli_output in
  let name = "fixture" and t = {meta={name="fixture"}; uid=1; gid=1} in
  assert (not (build_link_scan_prepared ~container_name:name));
  mark_microvm_work_root_ready name;
  let generation = match microvm_work_root_entry name with
    | Some entry -> entry.generation | None -> failwith "missing generation" in
  assert (not (build_link_scan_prepared ~container_name:name));
  let reasons = [ C.Capture_directory_unavailable; C.Capture_incomplete; C.Capture_failed;
    C.Capture_limit_exceeded; C.Capture_unreadable; C.Capture_permissions_invalid;
    C.Capture_length_mismatch; C.Capture_cleanup_failed ] in
  List.iter (fun reason ->
    Log.Keeper.messages := []; effects := [];
    C.observed := Error {reason; status=Some (Unix.WEXITED 2)};
    ensure_microvm_build_links t ~container_name:name ~generation;
    assert_state name Build_links_not_prepared;
    assert (!effects = []);
    match !(Log.Keeper.messages) with
    | [message] ->
      assert (contains (C.error_message {reason; status=None}) message);
      assert (contains "reduce scanned checkouts before retrying" message = (reason = C.Capture_limit_exceeded))
    | _ -> failwith "unexpected failure diagnostics") reasons;
  C.observed := Ok (Unix.WEXITED 0, "", "");
  Keeper_sandbox_microvm.targets := ["target"];
  Keeper_sandbox_microvm.actions := ["action"];
  effect_status := Unix.WEXITED 2; effects := [];
  ensure_microvm_build_links t ~container_name:name ~generation;
  assert_state name Build_links_effect_unverified;
  assert (not (build_link_scan_prepared ~container_name:name));
  assert (List.length !effects = 1);
  ignore (set_microvm_build_links_state name generation ~expected:Build_links_effect_unverified Build_links_prepared);
  assert (build_link_scan_prepared ~container_name:name);
  forget_microvm_work_root name;
  assert (not (build_link_scan_prepared ~container_name:name));
  print_endline "PASS: extracted real pattern paths; 8 capture reasons and 3 readiness states"
'''

compiler = ['ocamlfind', 'ocamlc', '-w', '-a+4+8', '-warn-error', '+4+8',
            '-package', 'unix,astring', '-linkpkg']
results = {}
with tempfile.TemporaryDirectory(prefix='fragile-match-', dir=output.parent) as directory:
    temporary = Path(directory)
    for label, source in [('before', previous), ('after', current)]:
        state = part(source, 'type microvm_build_links_state =', '(* Backends without authoritative')
        readiness = part(source, '  let build_link_scan_prepared ~container_name =', '  let microvm_container_name =')
        scan = part(source, 'let ensure_microvm_build_links ?', '(* Which side of a guest start')
        (temporary / (label + '.ml')).write_text(header + state + readiness + scan + checks)
    modified = (temporary / 'after.ml').read_text()
    variants = [
        ('future_state', '  | Build_links_prepared\n\ntype microvm_work_root_ready',
         '  | Build_links_prepared\n  | Synthetic_future_state\n\ntype microvm_work_root_ready'),
        ('future_capture', '  | Capture_cleanup_failed\n\ntype error',
         '  | Capture_cleanup_failed\n  | Synthetic_future_capture\n\ntype error')]
    for label, old, new in variants:
        if modified.count(old) != 1:
            raise RuntimeError('mutation anchor is absent or ambiguous: ' + label)
        (temporary / (label + '.ml')).write_text(modified.replace(old, new, 1))
    for label in ('before', 'after', 'future_state', 'future_capture'):
        command = compiler + ['-o', label, label + '.ml']
        result = subprocess.run(command, cwd=temporary, capture_output=True, text=True, check=False)
        results[label] = {'argv':command, 'exit':result.returncode,
                          'stdout':result.stdout, 'stderr':result.stderr}
    if results['before']['exit'] == 0 or results['before']['stderr'].count('Error (warning 4 [fragile-match])') != 2:
        raise RuntimeError('baseline did not reproduce exactly two warning-4 errors')
    if results['after']['exit'] != 0:
        raise RuntimeError('modified source did not compile: ' + results['after']['stderr'])
    for label, example in [('future_state', 'Some {build_links_state=Synthetic_future_state; _ }'),
                           ('future_capture', 'Error {reason=Synthetic_future_capture; _ }')]:
        outcome = results[label]
        if outcome['exit'] == 0 or 'Error (warning 8 [partial-match])' not in outcome['stderr'] or example not in outcome['stderr']:
            raise RuntimeError(label + ' did not produce the expected warning-8 failure')
    actual = subprocess.run(['./after'], cwd=temporary, capture_output=True, text=True, check=False)
    if actual.returncode != 0:
        raise RuntimeError('extracted checks failed: ' + actual.stderr)
    results['after_execution'] = {'argv':['./after'], 'exit':actual.returncode,
                                  'stdout':actual.stdout, 'stderr':actual.stderr}
    harness_sha = {label:hashlib.sha256((temporary/(label+'.ml')).read_bytes()).hexdigest()
                   for label in ('before','after','future_state','future_capture')}
receipt = {
    'scope':'Exact extracted runtime branches and CLI error definitions with stubbed external effects; not a MASC build, fake-provider test, CI or guest measurement.',
    'created_utc':datetime.now(timezone.utc).isoformat(),
    'base_sha':args.base_sha,
    'working_tree_head':subprocess.check_output(['git','rev-parse','HEAD'], cwd=root, text=True).strip(),
    'baseline_runtime_sha256':hashlib.sha256(previous_bytes).hexdigest(),
    'runtime_source_sha256':current_sha,
    'cli_source_sha256':hashlib.sha256(cli_bytes).hexdigest(),
    'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'ocaml':version, 'platform':platform.system(), 'architecture':platform.machine(),
    'harness_sha256':harness_sha, 'results':results,
}
with output.open('x', encoding='utf-8') as file:
    json.dump(receipt, file, indent=2, ensure_ascii=False)
    file.write('\n')
print('PASS: two baseline warning-4 failures, corrected extraction, and two warning-8 mutations')
print(actual.stdout.strip())
print('receipt written:', output)
