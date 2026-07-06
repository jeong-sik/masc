(** Test suite for metrics file rotation in keeper_types.ml *)
open Alcotest

module Keeper_types = Keeper_types
module Keeper_types_support = Masc.Keeper_types_support

let tmpdir () =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-rotation-test-%d" (Random.int 1_000_000)) in
  Unix.mkdir dir 0o755;
  dir

let cleanup dir =
  let entries = Sys.readdir dir in
  Array.iter (fun f -> Sys.remove (Filename.concat dir f)) entries;
  Unix.rmdir dir

let write_bytes path n =
  let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
  let buf = Bytes.make n 'x' in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    ignore (Unix.write fd buf 0 n))

let file_size path =
  try (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> -1

let test_no_rotation_under_threshold () =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) (fun () ->
    let path = Filename.concat dir "test.metrics.jsonl" in
    write_bytes path 100;
    Keeper_types_support.maybe_rotate_file path;
    check bool "original exists" true (Sys.file_exists path);
    check bool "no .1 file" false (Sys.file_exists (path ^ ".1")))

let test_rotation_at_threshold () =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) (fun () ->
    let path = Filename.concat dir "test.metrics.jsonl" in
    (* Write just at the default 10MB threshold *)
    write_bytes path 10_485_760;
    Keeper_types_support.maybe_rotate_file path;
    check bool "original removed (renamed)" false (Sys.file_exists path);
    check bool ".1 exists" true (Sys.file_exists (path ^ ".1"));
    check int ".1 has original size" 10_485_760 (file_size (path ^ ".1")))

let test_rotation_shifts_existing () =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) (fun () ->
    let path = Filename.concat dir "test.metrics.jsonl" in
    (* Create a .1 file first *)
    write_bytes (path ^ ".1") 50;
    (* Write large current file *)
    write_bytes path 10_485_760;
    Keeper_types_support.maybe_rotate_file path;
    check bool ".1 is the new rotation" true (Sys.file_exists (path ^ ".1"));
    check int ".1 is the big file" 10_485_760 (file_size (path ^ ".1")))

let test_nonexistent_file () =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) (fun () ->
    let path = Filename.concat dir "nonexistent.jsonl" in
    (* Should not raise *)
    Keeper_types_support.maybe_rotate_file path;
    check bool "no file created" false (Sys.file_exists path))

let test_append_with_rotation () =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) (fun () ->
    let path = Filename.concat dir "test.metrics.jsonl" in
    (* Write exactly at threshold so rotation triggers on append *)
    write_bytes path 10_485_760;
    (* Append should trigger rotation then write to fresh file *)
    Keeper_types_support.append_jsonl_line path (`Assoc [("test", `Bool true)]);
    check bool "new current file exists" true (Sys.file_exists path);
    check bool ".1 (rotated) exists" true (Sys.file_exists (path ^ ".1"));
    (* New file should be small (just the appended line) *)
    let new_size = file_size path in
    check bool "new file is small" true (new_size < 1000);
    (* Rotated file should have original size *)
    check int ".1 has original size" 10_485_760 (file_size (path ^ ".1")))

let test_append_result_success () =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) (fun () ->
    let path = Filename.concat dir "result.metrics.jsonl" in
    match
      Keeper_types_support.append_jsonl_line_result path
        (`Assoc [ ("test", `String "result") ])
    with
    | Ok () -> check bool "result append writes file" true (Sys.file_exists path)
    | Error msg -> fail ("append_jsonl_line_result failed: " ^ msg))

let test_append_result_error () =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) (fun () ->
    match Keeper_types_support.append_jsonl_line_result dir (`Assoc []) with
    | Ok () -> fail "append_jsonl_line_result must fail when path is a directory"
    | Error msg ->
      check bool "result append returns an explicit error" true (String.length msg > 0))

let () =
  run "Keeper metrics rotation" [
    "rotation", [
      test_case "no rotation under threshold" `Quick test_no_rotation_under_threshold;
      test_case "rotation at threshold" `Quick test_rotation_at_threshold;
      test_case "rotation shifts existing backups" `Quick test_rotation_shifts_existing;
      test_case "nonexistent file safe" `Quick test_nonexistent_file;
      test_case "append triggers rotation" `Quick test_append_with_rotation;
      test_case "append result succeeds" `Quick test_append_result_success;
      test_case "append result returns error" `Quick test_append_result_error;
    ];
  ]
