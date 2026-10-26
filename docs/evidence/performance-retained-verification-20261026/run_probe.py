#!/usr/bin/env python3
"""Interpret exact retained-read helpers; no Dune or native compilation.

The batch size counts reads of one controlled file, not Keeper owners. Every
row includes both real file/directory fsync calls. Fixed ABBA order, no warmup
or discarded outliers. This does not measure a server, TUI, or active fleet.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-repo', type=Path, required=True)
    parser.add_argument('--baseline-ref', required=True)
    parser.add_argument('--candidate-repo', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    relative = 'lib/lane_addon/lane_addon_store.ml'
    baseline = subprocess.check_output(['git', '-C', str(args.baseline_repo), 'show', args.baseline_ref + ':' + relative])
    candidate = (args.candidate_repo / relative).read_bytes()
    modules = ['''module Injected_unix = struct
include Unix
let interrupts=ref 0
let read fd buffer offset length =
  if !interrupts>0 then (decr interrupts;raise (Unix_error (EINTR,"read","injected")))
  else Unix.read fd buffer offset (min 97 length)
end
''']
    manifest = {'baseline_ref': args.baseline_ref, 'sources': {},
                'scope': 'exact helper OCaml 5.5 interpreter; real local fsync; no native/server/fleet result',
                'order': ['baseline', 'candidate', 'candidate', 'baseline']}
    for name, raw in [('Baseline', baseline), ('Candidate', candidate)]:
        (args.output / (name.lower() + '-store.ml')).write_bytes(raw)
        source = raw.decode()
        code = source[source.index('type record_verification ='):source.index('let bounded_file_with')]
        manifest['sources'][name.lower()] = {'full_file_sha256': digest(raw), 'extracted_sha256': digest(code.encode())}
        for suffix in ['', '_faults']:
            modules.append('module ' + name + suffix + ' = struct\n'
                           + ('module Unix = Injected_unix\n' if suffix else '')
                           + 'let ( let* ) = Result.bind\n' + code + '''
let observe ~sync_file ~sync_parent path =
  with_record_fd path (fun fd ->
    let stat=Unix.fstat fd in
    Result.bind (read_verified_record ~sync_file ~sync_parent ~verification:Durable path fd stat)
      changed_during_verification)
end
''')
    harness = r'''
let path=Sys.argv.(1)
let save path bytes=Out_channel.with_open_bin path (fun output -> output_string output bytes)
let payload size=String.init size (fun offset -> Char.chr ((offset * 13 + offset / 65536) mod 256))
let readers=["baseline",Baseline.observe;"candidate",Candidate.observe]
let fault_readers=["baseline",Baseline_faults.observe;"candidate",Candidate_faults.observe]
let observe reader ?(mutate=fun () -> ()) path =
  reader ~sync_file:(fun fd -> Unix.fsync fd;mutate ()) ~sync_parent:Unix.fsync path
let check label expected actual =
  if expected<>actual then failwith (label ^ ": baseline/candidate or required outcome differs");
  Printf.printf "CHECK\t%s\n%!" label
let () =
  List.iter (fun size ->
    let bytes=payload size in
    save path bytes;
    List.iter (fun (name,reader) ->
      check (name ^ " stable " ^ string_of_int size) (Ok bytes) (observe reader path)) readers)
    [0;1;65535;65536;131071;131072;131073;1048576;1048593];
  List.iter (fun size ->
    let bytes=payload size in save path bytes;
    List.iter (fun (name,reader) ->
      Injected_unix.interrupts:=3;
      check (name ^ " real short reads after EINTR " ^ string_of_int size)
        (Ok bytes) (observe reader path)) fault_readers) [0;64;131073;1048593];
  let bytes=payload 1048593 in
  List.iter (fun offset ->
    let results=List.map (fun (_,reader) ->
      save path bytes;
      observe reader ~mutate:(fun () ->
        let fd=Unix.openfile path [Unix.O_WRONLY] 0 in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
          ignore (Unix.lseek fd offset Unix.SEEK_SET);
          let replacement=String.make 1 (Char.chr ((Char.code bytes.[offset]+1) mod 256)) in
          if Unix.write_substring fd replacement 0 1<>1 then failwith "short mutation")) path) readers in
    List.iter (check ("mutation " ^ string_of_int offset) (Error "retained file changed during sync")) results)
    [0;65535;65536;131071;131072;1048575;1048576;1048592];
  List.iter (fun (name,reader) ->
    save path bytes;
    check (name ^ " shrink") (Error "retained file shrank during read")
      (observe reader ~mutate:(fun () -> Unix.truncate path (String.length bytes-1)) path);
    save path bytes;
    check (name ^ " grow") (Error "retained file grew during read")
      (observe reader ~mutate:(fun () ->
        Out_channel.with_open_gen [Open_wronly;Open_append;Open_binary] 0o600 path
          (fun output -> output_char output '\000')) path);
    save path bytes;
    let held=path ^ ".held" in
    let result=observe reader ~mutate:(fun () -> Unix.rename path held;save path bytes) path in
    Unix.unlink path;Unix.rename held path;
    check (name ^ " identical replacement") (Error "retained file changed during verification") result;
    let calls=ref 0 in
    let result=reader ~sync_file:(fun fd -> incr calls;Unix.fsync fd)
      ~sync_parent:(fun fd -> incr calls;Unix.fsync fd) path in
    check (name ^ " real fsync calls") 2 !calls;
    check (name ^ " real fsync bytes") (Ok bytes) result) readers;
  Printf.printf "role,size,reads,block,elapsed_ms,allocated_bytes\n%!";
  List.iter (fun (size,count) ->
    let bytes=payload size in save path bytes;
    List.iteri (fun block name ->
      let reader=List.assoc name readers in
      let allocation=Gc.allocated_bytes () in
      let started=Mtime_clock.elapsed_ns () in
      for _=1 to count do
        match observe reader path with
        | Ok actual when String.equal actual bytes -> ()
        | Ok _ -> failwith "benchmark changed bytes"
        | Error detail -> failwith detail
      done;
      let elapsed=Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started)/.1e6 in
      let allocated=Gc.allocated_bytes ()-.allocation in
      Printf.printf "%s,%d,%d,%d,%.6f,%.0f\n%!" name size count block elapsed allocated)
      ["baseline";"candidate";"candidate";"baseline"])
    [64,300;65536,300;131072,300;1048576,30;1048576,300;4194321,30];
  Sys.remove path
'''
    generated = ('\n'.join(modules) + harness).encode()
    probe = args.output / 'probe.ml'
    probe.write_bytes(generated)
    manifest['generated_probe_sha256'] = digest(generated)
    mtime = Path(subprocess.check_output(['ocamlfind', 'query', 'mtime'], text=True).strip())
    clock = Path(subprocess.check_output(['ocamlfind', 'query', 'mtime.clock.os'], text=True).strip())
    command = ['ocaml', '-noinit', '-noprompt', '-I', '+unix', '-I', str(mtime), '-I', str(clock),
               'unix.cma', 'mtime.cma', 'mtime_clock.cma', str(probe.resolve()), str((args.output / 'input.bin').resolve())]
    manifest['command'] = command
    with (args.output / 'stdout.txt').open('xb') as out, (args.output / 'stderr.txt').open('xb') as err:
        result = subprocess.run(command, stdout=out, stderr=err)
    manifest['returncode'] = result.returncode
    manifest['interpreter'] = subprocess.check_output(['ocamlc', '-version'], text=True).strip()
    manifest['clock'] = 'Mtime_clock.elapsed_ns; monotonic elapsed time, not exclusive CPU'
    runner = Path(__file__).read_bytes()
    (args.output / 'run_probe.py').write_bytes(runner)
    manifest['runner_sha256'] = digest(runner)
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    lines = (args.output / 'stdout.txt').read_text().splitlines()
    checks = [line for line in lines if line.startswith('CHECK\t')]
    rows = [line for line in lines if line.startswith(('baseline,', 'candidate,', 'role,'))]
    (args.output / 'measurements.csv').write_text('\n'.join(rows) + '\n')
    print(json.dumps({'returncode': result.returncode, 'checks': len(checks), 'measurement_rows': len(rows)-1, 'output': str(args.output)}))
    if result.returncode:
        print((args.output / 'stderr.txt').read_text()[-3000:])
        raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
