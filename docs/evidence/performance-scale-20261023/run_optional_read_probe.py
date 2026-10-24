#!/usr/bin/env python3
"""Run real Eio/file-read source fragments without building MASC.

Only fixture writes/removal are supplied locally. Reads, file-kind lookup,
exception conversion and Eio handoff use the actual source helpers. An explicit
after-length hook is inserted into the historical reader to reproduce its
post-open failure classification; benchmark runs leave that hook empty.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument('--before', default='0b4ebf61148ebc0f68844af9ed20ed3dd6f88400')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo, out = args.repo.resolve(), args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
relative = 'lib/fs_compat/fs_compat.ml'
before = subprocess.check_output(['git', 'show', f'{args.before}:{relative}'], cwd=repo, text=True)
after = (repo/relative).read_text()
test_source = (repo/'test/test_fs_compat.ml').read_text()
manifest = {'scope': __doc__, 'before': args.before,
    'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'source_sha256': {
    'before': hashlib.sha256(before.encode()).hexdigest(),
    relative: hashlib.sha256(after.encode()).hexdigest(),
    'test/test_fs_compat.ml': hashlib.sha256(test_source.encode()).hexdigest()}}


def ocaml_bytes_literal(value: bytes) -> str:
    """Encode exact bytes, including UTF-8 paths and controls, for OCaml."""
    return '"' + ''.join(f'\\{byte:03d}' for byte in value) + '"'


def function(source, start):
    offset = source.index(start)
    return source[offset:source.index('\n;;', offset)+3]


def module(label, source):
    code = f'module {label} = struct\n'
    start = source.index('let global_fs :')
    end = source.index('type execution_context =', start)
    code += source[start:end]
    code += function(source, 'let with_io ~path') + '\n'
    code += function(source, 'let with_fs_or_fallback ~path') + '\n'
    if label == 'Before':
        code += 'let before_read = ref (fun () -> ())\n'
        reader = function(source, 'let load_file_unix (path')
        needle = 'let len = Stdlib.in_channel_length ic in'
        assert reader.count(needle) == 1
        code += reader.replace(needle, needle+'\n       !before_read ();')+'\n'
    else:
        code += function(source, 'let read_channel_and_close ~before_read')+'\n'
        code += function(source, 'let load_file_unix (path')+'\n'
    code += next(line for line in source.splitlines() if line.startswith('let labelled operation path'))+'\n'
    code += function(source, 'let on_systhread ~label')+'\n'
    code += function(source, 'let load_file (path')+'\n'
    if label == 'Before':
        start = source.index('type exact_path_kind =')
        end = source.index('let path_kind ', start)
        code += source[start:end]
        code += function(source, 'let load_file_opt (path')+'\n'
    else:
        start = source.index('let load_file_opt_unix ~before_read')
        end = source.index('let file_size ', start)
        code += source[start:end]
    return code+'end;;\n'


code = '#use "topfind";;\n#require "eio_main,alcotest,mtime.clock.os";;\n'
code += module('Before', before)+module('After', after)
code += '''module Fs_compat = struct
 include After
 let save_file path content = Out_channel.with_open_bin path (fun out -> output_string out content)
 let remove_tree path = Array.iter (fun name -> Sys.remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
end;;
'''
start = test_source.index('open Alcotest')
end = test_source.index('(* [raise_with_backtrace]', start)
code += test_source[start:end]
code += '''
let () = Eio_main.run (fun env ->
 let fs = Eio.Stdenv.fs env in
 Before.set_fs fs; After.set_fs fs;
 run ~and_exit:false "optional-read-source" [
  "fallback", List.map (fun (name, test) -> test_case name `Quick (with_optional_read_fs None test)) optional_read_cases;
  "Eio", List.map (fun (name, test) -> test_case name `Quick (with_optional_read_fs (Some fs) test)) optional_read_cases;
  "cancellation", [test_case "joins the real reader" `Quick (test_optional_read_cancellation_joins_reader ~fs)]
 ];
 with_tmp_dir (fun base ->
  let path = Filename.concat base "baseline-short-read" in
  Fs_compat.save_file path "opened bytes";
  Before.before_read := (fun () -> Unix.truncate path 0; Unix.unlink path);
  Fun.protect ~finally:(fun () -> Before.before_read := (fun () -> ())) (fun () ->
   check (option string) "baseline reproduces hidden read failure" None (Before.load_file_opt path)));
 Printf.printf "Historical short-read misclassification reproduced; candidate rejects it.\\n%!"
);;
'''
with tempfile.TemporaryDirectory(prefix='masc-optional-read-probe-') as temporary:
    root = Path(temporary)
    content = (repo/'test/fixtures/item-http/keeper.json').read_bytes()
    manifest['fixture_sha256'] = hashlib.sha256(content).hexdigest()
    manifest['fixture_bytes'] = len(content)
    for n in range(350):
        (root/f'{n:04d}.json').write_bytes(content)
    code += f'let root = {ocaml_bytes_literal(os.fsencode(str(root)))};;\n'
    code += f'let fixture_content = {ocaml_bytes_literal(content)};;\n'
    code += '''
let () = Eio_main.run (fun env ->
 Before.set_fs (Eio.Stdenv.fs env); After.set_fs (Eio.Stdenv.fs env);
 let output = open_out "measurements.csv" in
 Fun.protect ~finally:(fun () -> close_out output) (fun () ->
 fprintf output "files,round,implementation,elapsed_ms,allocated_bytes\\n";
 List.iter (fun count ->
  let paths = List.init count (fun i -> Filename.concat root (Printf.sprintf "%04d.json" i)) in
  let expected = List.map (fun _ -> Some fixture_content) paths in
  assert (List.map Before.load_file_opt paths = expected);
  assert (List.map After.load_file_opt paths = expected);
  Printf.printf "Verified %d existing fixture files, %d bytes each, with both readers.\\n%!"
    count (String.length fixture_content);
  for round = 1 to 9 do
   let order = if round mod 2 = 1 then ["before",Before.load_file_opt; "after",After.load_file_opt]
     else ["after",After.load_file_opt; "before",Before.load_file_opt] in
   List.iter (fun (label, read) ->
    Gc.full_major ();
    let allocated = Gc.allocated_bytes () in
    let started = Mtime_clock.counter () in
    let observed = List.map read paths in
    let ms = Mtime.Span.to_float_ns (Mtime_clock.count started) /. 1_000_000. in
    let bytes = Gc.allocated_bytes () -. allocated in
    assert (observed = expected);
    fprintf output "%d,%d,%s,%.6f,%.0f\\n%!" count round label ms bytes) order
  done) [35;350]));;
'''.replace('fprintf output', 'Printf.fprintf output')
    (out/'probe.ml').write_text(code)
    (out/'sources.json').write_text(json.dumps(manifest, indent=2)+'\n')
    with (out/'checks.txt').open('w') as log:
        subprocess.run(['ocaml', '-noinit', str(out/'probe.ml')], cwd=out,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    if not (out/'measurements.csv').is_file():
        raise RuntimeError('interpreter exited before measurements completed')
print((out/'checks.txt').read_text())
