#!/usr/bin/env python3
"""Exercise production upload chunking with real od and Process_eio's capture buffer.

Interprets source, with only the sandbox transport replaced by local argv execution.
This tests byte transfer/resource bounds, not container or remote file authorization.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', required=True, type=pathlib.Path)
args = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parents[1]
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
sources = ['lib/keeper/keeper_browser_upload.ml', 'lib/browser_lane/browser_upload_lease.ml',
           'lib/core/exec_buffer.ml', 'lib/core/common.ml', 'lib/process/process_eio.ml']
(out / 'sources.json').write_text(json.dumps({name: hashlib.sha256((repo / name).read_bytes()).hexdigest()
                                             for name in sources}, indent=2) + '\n')
common = (repo / 'lib/core/common.ml').read_text()
caps = '\n'.join(line for line in common.splitlines()
                 if line.startswith(('let max_process_capture_head_bytes =',
                                     'let max_process_capture_tail_bytes =')))
source = '#use "topfind";;\n#require "eio_main";;\nmodule Common = struct\n' + caps + '\nend;;\n'
for module, path in [('Exec_buffer', 'lib/core/exec_buffer.ml'),
                     ('Browser_upload_lease', 'lib/browser_lane/browser_upload_lease.ml')]:
    source += f'module {module} = struct\n' + (repo / path).read_text() + '\nend;;\n'
source += r'''
module Browser_lane = struct module Upload_lease = Browser_upload_lease end
module Env_config_sandbox = struct module Shell_timeout = struct
  type bucket = Read
  let timeout_sec ~(bucket : bucket) () = let _ = bucket in 20.
end end
module Keeper_tool_shared_runtime = struct
  let resolve_keeper_read_path ~config ~meta:_ ~raw_path =
    Ok (Filename.concat config raw_path)
end
module Keeper_sandbox_read_runner = struct
  let dropped = ref []
  let container_path_of_host ~config:_ ~meta:_ ~host_path = Ok host_path
  let run_command ?turn_sandbox_factory:_ ~config:_ ~meta:_ ~command_argv ~max_bytes ~timeout_sec:_ () =
    let capture = Exec_buffer.create ~head_cap:Common.max_process_capture_head_bytes
        ~tail_cap:Common.max_process_capture_tail_bytes in
    let ic = Unix.open_process_args_in (List.hd command_argv) (Array.of_list command_argv) in
    let buf = Bytes.create 65536 in
    let rec drain () = match input ic buf 0 (Bytes.length buf) with
      | 0 -> () | count -> Exec_buffer.add_bytes capture buf 0 count; drain () in
    drain ();
    dropped := Exec_buffer.bytes_dropped capture :: !dropped;
    match Unix.close_process_in ic with
    | Unix.WEXITED 0 -> let text = Exec_buffer.render capture in
      Ok (if String.length text > max_bytes then String.sub text 0 max_bytes else text)
    | _ -> Error "source command failed"
end
'''
source += 'module Upload = struct\n' + (repo / 'lib/keeper/keeper_browser_upload.ml').read_text() + '\nend;;\n'
source += r'''
let check label ok = if not ok then failwith label else Printf.printf "PASS %s\n%!" label
let () =
  let root = Filename.temp_dir "masc-upload-byte-probe-" "" in
  let path = Filename.concat root "payload.bin" in
  Fun.protect ~finally:(fun () -> if Sys.file_exists path then Unix.unlink path; Unix.rmdir root) (fun () ->
    let write bytes = let oc = open_out_bin path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc bytes) in
    let payload n = String.init n (fun i -> Char.chr ((i * 31 + 17) mod 256)) in
    write (payload (3*1024*1024+17));
    let old = Keeper_sandbox_read_runner.run_command ~config:root ~meta:()
      ~command_argv:["od";"-An";"-v";"-tx1";path] ~max_bytes:(64*1024*1024) ~timeout_sec:20. () in
    check "single-shot hex transfer exceeds real capture retention"
      (List.exists (fun n -> n>0) !(Keeper_sandbox_read_runner.dropped));
    check "old transport fails explicitly instead of corrupting bytes"
      (match old with Ok text -> Result.is_error (Upload.decode_hex text) | Error _ -> false);
    List.iter (fun size ->
      let expected = payload size in write expected;
      Keeper_sandbox_read_runner.dropped := [];
      let staged_path = ref None in
      let result = Upload.with_staged_paths ~config:root ~meta:() ~paths:["payload.bin"] (fun paths ->
        let staged = List.hd paths in staged_path := Some staged;
        let ic = open_in_bin staged in
        let actual = Fun.protect ~finally:(fun () -> close_in ic)
          (fun () -> really_input_string ic (in_channel_length ic)) in
        check (Printf.sprintf "exact staged bytes at size %d" size) (actual=expected)) in
      check (Printf.sprintf "authorized transfer accepted at size %d" size) (result=Ok ());
      check "every subprocess chunk fits capture head"
        (List.for_all ((=) 0) !(Keeper_sandbox_read_runner.dropped));
      check "unclaimed probe snapshot is removed"
        (match !staged_path with Some p -> not (Sys.file_exists p) | None -> false))
      [0;3*1024*1024+17;Upload.max_file_bytes];
    write (payload (Upload.max_file_bytes+1));
    let invoked = ref false in
    let result = Upload.with_staged_paths ~config:root ~meta:() ~paths:["payload.bin"]
      (fun _ -> invoked := true) in
    check "16 MiB plus one byte is refused without browser continuation" (Result.is_error result && not !invoked);
    write "short";
    let skip = Keeper_sandbox_read_runner.run_command ~config:root ~meta:()
      ~command_argv:["od";"-An";"-v";"-tx1";"-j";"99";"-N";"1";path]
      ~max_bytes:4 ~timeout_sec:20. () in
    check "skip past EOF remains a source error" (Result.is_error skip);
    Unix.unlink path;
    let missing = Upload.with_staged_paths ~config:root ~meta:() ~paths:["payload.bin"]
      (fun _ -> invoked := true) in
    check "missing source is refused" (Result.is_error missing))
'''
probe = out / 'probe.ml'
probe.write_text(source)
result = subprocess.run(['ocaml', '-noinit', str(probe)], stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, text=True, check=False)
(out / 'probe.log').write_text(result.stdout)
print(result.stdout, end='')
raise SystemExit(result.returncode)
