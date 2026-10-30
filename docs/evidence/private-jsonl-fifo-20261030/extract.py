#!/usr/bin/env python3
"""Run selected source-extracted FIFO tests with stubbed MASC dependencies."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

source_path, test_path, output_path = map(lambda p: Path(p).resolve(), sys.argv[1:4])
output_path.mkdir(parents=True, exist_ok=True)
source = source_path.read_text()
tests = test_path.read_text()
def section(text, start, end):
    at = text.index(start)
    return text[at:text.index(end, at)]
stable = section(source, 'type private_jsonl_stable_lock_creation =', '\nlet rec private_jsonl_write_substring_all')
helper = section(source, 'let private_jsonl_open_existing ~close_fd path flags =', '\nlet purge_private_jsonl_durable_locked_with_io')
slice_part = section(source, 'module Private_jsonl_slice = struct', '\nlet read_private_jsonl_slice_locked_with_io_for_testing')
instrumented_variant = '    | Non_regular_file of Unix.file_kind' not in slice_part
if instrumented_variant:
    slice_part = slice_part.replace('    | Io_failed of exn\n', '    | Non_regular_file of Unix.file_kind\n    | Io_failed of exn\n', 1)
    slice_part = slice_part.replace('    | Io_failed exn -> Printexc.to_string exn', '    | Non_regular_file _ -> "non-regular file"\n    | Io_failed exn -> Printexc.to_string exn', 1)
test = section(tests, 'let remove_if_present path =', 'let transaction_snapshot_with_io')
stub = '''open Alcotest
module Fs_compat = struct
  module Eio = struct module Cancel = struct exception Cancelled of exn end end
  type operation = Close_transaction_data | Open_transaction_data | Inspect_transaction_path
    | Open_stable_lock | Inspect_stable_lock
  type failure = { exception_ : exn }
  type error = Unexpected_transaction_file_kind of Unix.file_kind | Private_jsonl_operation_failed of failure
  type cursor = unit
  type snapshot = { cursor : cursor }
  type ('a,'b) outcome = Private_file_succeeded of 'a
    | Private_file_succeeded_with_cleanup_failure of {value:'a; cleanup_failure:failure}
    | Private_file_failed of 'b
    | Private_file_failed_with_cleanup_failure of {error:'b; cleanup_failure:failure}
  type io = {close_fd:Unix.file_descr -> unit}
  let private_jsonl_transaction_unix_io = {close_fd=Unix.close}
  let private_jsonl_failure _ exception_ = {exception_}
  let private_jsonl_capture _ f = try Ok (f ()) with exception_ -> Error {exception_}
  let private_jsonl_add_cleanup_failure error _ = error
  let private_jsonl_validate_open_binding ~operation:_ ~path fd =
    let path_kind = (Unix.lstat path).Unix.st_kind in
    let fd_kind = (Unix.fstat fd).Unix.st_kind in
    if path_kind <> Unix.S_REG then Error (Unexpected_transaction_file_kind path_kind)
    else if fd_kind <> Unix.S_REG then Error (Unexpected_transaction_file_kind fd_kind)
    else Ok ()
  let private_jsonl_lock_path path = path ^ ".lock"
  let private_jsonl_transaction_error_to_string _ = "fixture error"
  let file_kind_to_string _ = "fixture file kind"
  let test_exec_home_guard ~op:_ _ = ()
  let get_append_path_mutex _ = Mutex.create ()
  let run_blocking_private_file_transaction ~label:_ ~path:_ f = f ()
  let lock_whole_file_shared fd = Unix.lockf fd Unix.F_RLOCK 0
  let private_jsonl_with_fd_outcome ~close_operation:_ ~close_fd fd f =
    let result = f () in
    let close_result = try close_fd fd; None with exception_ -> Some {exception_} in
    match result, close_result with
    | Ok value, None -> Private_file_succeeded value
    | Ok value, Some cleanup_failure -> Private_file_succeeded_with_cleanup_failure {value; cleanup_failure}
    | Error error, None -> Private_file_failed error
    | Error error, Some cleanup_failure -> Private_file_failed_with_cleanup_failure {error; cleanup_failure}
'''
calls = '''
  let inspect path flags =
    match private_jsonl_open_stable_lock (private_jsonl_lock_path path) with
    | Error _ as error -> error
    | Ok lock ->
      let binding = private_jsonl_validate_open_binding ~operation:Inspect_stable_lock
          ~path:(private_jsonl_lock_path path) lock.fd in
      Unix.close lock.fd;
      (match binding with
       | Error _ as error -> error
       | Ok () ->
         match private_jsonl_open_existing ~close_fd:Unix.close path flags with
         | Ok None -> Ok ()
         | Ok (Some fd) -> Unix.close fd; Ok ()
         | Error _ as error -> error)
  let read_private_jsonl_durable_locked_result path ~after:_ =
    Result.map (fun () -> {cursor=()}) (inspect path [Unix.O_RDONLY])
  let recover_private_jsonl_durable_locked_result path =
    Result.map (fun () -> {cursor=()}) (inspect path [Unix.O_RDWR])
  let append_private_jsonl_durable_locked_at_cursor_result path ~expected:_ _ =
    inspect path [Unix.O_RDWR;Unix.O_APPEND]
  let rewrite_private_jsonl_durable_locked_at_cursor_result path ~expected:_ _ =
    inspect path [Unix.O_RDONLY]
'''
regular_test = '''
let test_slice_regular_and_symlink () =
  with_transaction_jsonl (Some "one\\ntwo\\n") @@ fun path ->
  let expect path =
    match Fs_compat.read_private_jsonl_slice_locked_result path ~from:4 with
    | Fs_compat.Private_file_succeeded {bytes; end_offset} ->
      check string "slice bytes" "two\\n" bytes;
      check int "end" 8 end_offset
    | _ -> fail "regular slice failed"
  in
  expect path;
  let link = path ^ ".link" in
  Unix.symlink path link;
  Fun.protect ~finally:(fun () -> Unix.unlink link) (fun () -> expect link)
;;
let () =
  Sys.set_signal Sys.sigchld (Sys.Signal_handle (fun _ -> ()));
  Alcotest.run "extracted FIFO tests" ["fifo", [
    Alcotest.test_case "transaction FIFO" `Quick test_private_jsonl_transactions_reject_fifo_without_writer;
    Alcotest.test_case "lock FIFO" `Quick test_private_jsonl_stable_lock_rejects_fifo_without_writer;
    Alcotest.test_case "slice FIFO" `Quick test_private_jsonl_slice_rejects_fifo_without_writer;
    Alcotest.test_case "regular and symlink slice" `Quick test_slice_regular_and_symlink ]]
'''
(output_path / 'test.ml').write_text(stub + stable + helper + slice_part + calls + '\nend\n' + test + regular_test)
compiled = subprocess.run(['ocamlfind','ocamlc','-package','unix,threads,alcotest,mtime.clock.os','-linkpkg','-o','test','test.ml'], cwd=output_path, text=True, capture_output=True)
started = time.monotonic()
executed = None
if compiled.returncode == 0:
    executed = subprocess.run(['./test','--color=never'], cwd=output_path, text=True, capture_output=True, timeout=40)
receipt = {'scope':'actual extracted open helpers, slice reader and FIFO test functions; transaction coordination, validation, settlement and Eio are stubs; not full MASC', 'source_sha256':hashlib.sha256(source.encode()).hexdigest(), 'test_sha256':hashlib.sha256(tests.encode()).hexdigest(), 'baseline_variant_instrumented_for_test_typecheck':instrumented_variant, 'compile_exit':compiled.returncode, 'compile_stderr':compiled.stderr, 'test_exit':None if executed is None else executed.returncode, 'test_stdout':None if executed is None else executed.stdout, 'test_stderr':None if executed is None else executed.stderr, 'test_wall_seconds':round(time.monotonic()-started,3)}
print(json.dumps(receipt, ensure_ascii=False, indent=2))
sys.exit(0 if executed is not None and executed.returncode == 0 else 1)
