#!/usr/bin/env python3
"""Interpret the actual retained-reader helpers against private regular files.

Measures warm, durable, double-read capture including fsync, but excludes JSON
parsing, caller scheduling, complete modules and active Keeper behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument('--before', default='19eded8bc18c890e058dfc34123803431fcdb683')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo, out = args.repo.resolve(), args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
relative = 'lib/lane_addon/lane_addon_store.ml'
manifest = {'before': args.before, 'scope': __doc__, 'source_sha256': {}}
code = '#use "topfind";;\n#require "unix,mtime.clock.os";;\n'
for label in ('Before', 'After'):
    source = (subprocess.check_output(['git', 'show', f'{args.before}:{relative}'],
        cwd=repo, text=True) if label == 'Before' else (repo/relative).read_text())
    start, end = 'type record_verification =', 'let changed_during_verification ='
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError('retained reader source boundaries changed')
    selected = source[source.index(start):source.index(end)]
    (out/f'{label.lower()}_helpers.ml').write_text(selected)
    manifest['source_sha256'][label] = {
        'file': hashlib.sha256(source.encode()).hexdigest(),
        'selected_helpers': hashlib.sha256(selected.encode()).hexdigest()}
    code += f'module {label} = struct\nlet ( let* ) = Result.bind\n{selected}\nend;;\n'

def ocaml_path(path):
    return '"' + ''.join(f'\\{byte:03d}' for byte in os.fsencode(path)) + '"'

code += f'let root = {ocaml_path(out)};;\n'
code += r'''
let require condition detail = if not condition then failwith detail;;
let write path content = Out_channel.with_open_bin path (fun channel -> output_string channel content);;
let opened path f = let fd=Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> f fd);;
let payload size = String.init size (fun i -> Char.chr (i mod 256));;
let path = Filename.concat root "record.bin";;
let checks=ref 0;;
let checked detail condition = require condition detail; incr checks;;
let compare_read size content =
  write path content;
  let before=opened path (fun fd -> Before.record_bytes fd size) in
  let after=opened path (fun fd -> After.record_bytes fd size) in
  checked "before/after read results differ" (before=after);
  let expected = if String.length content<size then Error "retained file shrank during read"
    else if String.length content>size then Error "retained file grew during read" else Ok content in
  checked "read result does not match complete bytes / error" (after=expected);;
List.iter (fun size ->
  compare_read size (payload size);
  compare_read size (payload (size+1));
  if size>0 then compare_read size (payload (size-1))) [0;1;255;256;4096;65536];;
let read_after () = opened path (fun fd -> After.record_bytes fd (Unix.fstat fd).Unix.st_size);;
write path (payload 4096);;
let retained=read_after ();;
write path (String.make 4096 'Z');;
let subsequent=read_after ();;
checked "returned immutable bytes changed after another file/read" (retained=Ok (payload 4096));;
checked "subsequent capture sees current bytes" (subsequent=Ok (String.make 4096 'Z'));;
let before_capture mutate = opened path (fun fd ->
  let stat=Unix.fstat fd in
  Before.read_verified_record ~sync_file:(fun descriptor -> mutate ();Unix.fsync descriptor)
    ~sync_parent:Unix.fsync ~verification:Before.Durable path fd stat);;
let after_capture mutate = opened path (fun fd ->
  let stat=Unix.fstat fd in
  After.read_verified_record ~sync_file:(fun descriptor -> mutate ();Unix.fsync descriptor)
    ~sync_parent:Unix.fsync ~verification:After.Durable path fd stat);;
let before_result = function Ok (Before.Confirmed text) -> Ok (Some text)
  | Ok Before.Republished -> Ok None | Error error -> Error error;;
let after_result = function Ok (After.Confirmed text) -> Ok (Some text)
  | Ok After.Republished -> Ok None | Error error -> Error error;;
let compare_capture mutate expected =
  write path (payload 4096);let before=before_result (before_capture mutate) in
  write path (payload 4096);let after=after_result (after_capture mutate) in
  checked "verification result changed" (before=after);
  checked "verification failed to classify mutation" (after=expected);;
compare_capture (fun () -> ()) (Ok (Some (payload 4096)));;
compare_capture (fun () -> write path (String.make 4096 'Z')) (Error "retained file changed during sync");;
compare_capture (fun () -> write path "short") (Error "retained file shrank during read");;
compare_capture (fun () -> write path (payload 4097)) (Error "retained file grew during read");;
compare_capture (fun () -> let replacement=path^".replacement" in
  write replacement (payload 4096);Unix.rename replacement path) (Ok None);;
Printf.eprintf "PASS %d exact byte/ownership/verification checks\n%!" !checks;;
let before () = before_result (before_capture (fun () -> ()));;
let after () = after_result (after_capture (fun () -> ()));;
let measure label read size count round =
  let expected=Ok (Some (payload size)) in
  Gc.full_major ();
  let allocation=Gc.allocated_bytes () in
  let started=Mtime_clock.elapsed_ns () in
  for _=1 to count do require (read ()=expected) "measurement read differs" done;
  let ms=Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started)/.1e6 in
  let bytes=Gc.allocated_bytes ()-.allocation in
  Printf.printf "%s,%d,%d,%d,%.6f,%.0f\n%!" label size count round ms bytes;;
Printf.printf "phase,record_bytes,reads,round,elapsed_ms,allocated_bytes\n%!";;
List.iter (fun size ->
  write path (payload size);
  List.iter (fun count ->
    for round=0 to 8 do
      let phases=if round mod 2=0 then ["before",before;"after",after]
        else ["after",after;"before",before] in
      List.iter (fun (label,read) -> measure label read size count round) phases
    done) [35;350]) [65536;1048576];;
'''
(out/'probe.ml').write_text(code)
(out/'sources.json').write_text(json.dumps(manifest, indent=2)+'\n')
with (out/'measurements.csv').open('w') as output, (out/'checks.txt').open('w') as errors:
    subprocess.run(['ocaml', '-noinit', str(out/'probe.ml')], cwd=out,
                   stdout=output, stderr=errors, check=True)
print((out/'checks.txt').read_text(), end='')
