(** Test suite for metrics file rotation in keeper_types.ml *)
open Alcotest

module Keeper_types_support = Masc.Keeper_types_support

let tmpdir () = Filename.temp_dir "masc-rotation-test-" ""
let cleanup = Fs_compat.remove_tree

let with_setting name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () ->
    match previous with
    | Some value -> Unix.putenv name value
    | None -> Unix.unsetenv name) f

let with_rotation ~max_bytes ~retained f =
  with_setting "MASC_KEEPER_METRICS_MAX_BYTES" (string_of_int max_bytes) @@ fun () ->
  with_setting "MASC_KEEPER_METRICS_MAX_ROTATED" (string_of_int retained) f

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

let test_zero_retention_discards_backups () =
  with_rotation ~max_bytes:17 ~retained:0 @@ fun () ->
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) @@ fun () ->
  let path = Filename.concat dir "metrics.jsonl" in
  write_bytes path 17;
  List.iter (fun n -> write_bytes (path ^ "." ^ string_of_int n) n) [1; 2; 9];
  Keeper_types_support.append_jsonl_line path (`Assoc ["new", `Bool true]);
  check (list string) "only the new current file remains" ["metrics.jsonl"]
    (Fs_compat.read_dir dir);
  check string "new metric preserved" "{\"new\":true}\n" (Fs_compat.load_file path)

let test_reduced_retention_prunes_and_shifts () =
  with_rotation ~max_bytes:17 ~retained:2 @@ fun () ->
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) @@ fun () ->
  let path = Filename.concat dir "metrics.jsonl" in
  Fs_compat.save_file path (String.make 17 'x');
  Fs_compat.save_file (path ^ ".1") "newest prior backup";
  List.iter (fun n -> write_bytes (path ^ "." ^ string_of_int n) n) [2; 3; 9];
  Keeper_types_support.append_jsonl_line path (`Null);
  check (list string) "retention reduction drops excess backups"
    ["metrics.jsonl"; "metrics.jsonl.1"; "metrics.jsonl.2"] (Fs_compat.read_dir dir);
  check string "current rotates into newest backup" (String.make 17 'x')
    (Fs_compat.load_file (path ^ ".1"));
  check string "newest previous backup survives shift" "newest prior backup"
    (Fs_compat.load_file (path ^ ".2"));
  check string "new metric appended" "null\n" (Fs_compat.load_file path)

let test_retention_preserves_unrelated_names () =
  with_rotation ~max_bytes:17 ~retained:0 @@ fun () ->
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) @@ fun () ->
  let path = Filename.concat dir "metrics.jsonl" in
  let unrelated = ["metrics.jsonl.01"; "metrics.jsonl.0"; "metrics.jsonl.-1";
    "metrics.jsonl.0x1"; "metrics.jsonl.1.tmp"; "metrics.jsonl.1_0";
    "metrics.jsonl.99999999999999999999999999999999"; "other.jsonl.1"] in
  List.iter (fun name -> Fs_compat.save_file (Filename.concat dir name) name) unrelated;
  write_bytes path 17;
  write_bytes (path ^ ".1") 1;
  Keeper_types_support.append_jsonl_line path (`Null);
  List.iter (fun name -> check string "unrelated file is untouched" name
    (Fs_compat.load_file (Filename.concat dir name))) unrelated;
  check bool "owned backup removed" false (Sys.file_exists (path ^ ".1"))

let test_retention_unlinks_symlinks_without_following () =
  with_rotation ~max_bytes:17 ~retained:0 @@ fun () ->
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) @@ fun () ->
  let path = Filename.concat dir "metrics.jsonl" in
  let target = Filename.concat dir "unrelated" in
  Fs_compat.save_file target "keep target";
  Unix.symlink target (path ^ ".1");
  Unix.symlink (Filename.concat dir "absent") (path ^ ".2");
  write_bytes path 17;
  Keeper_types_support.append_jsonl_line path (`Null);
  check string "symlink target preserved" "keep target" (Fs_compat.load_file target);
  check (list string) "both live and dangling links removed" ["metrics.jsonl"; "unrelated"]
    (Fs_compat.read_dir dir)

let test_retention_refuses_directory_collision retained () =
  with_rotation ~max_bytes:17 ~retained @@ fun () ->
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) @@ fun () ->
  let path = Filename.concat dir "metrics.jsonl" in
  let collision = path ^ ".1" in
  Unix.mkdir collision 0o700;
  let child = Filename.concat collision "keep" in
  Fs_compat.save_file child "directory contents";
  write_bytes path 17;
  (match Keeper_types_support.append_jsonl_line path (`Null) with
   | () -> fail "a backup directory must not be silently removed"
   | exception Sys_error _ -> ());
  check string "directory contents survive refusal" "directory contents" (Fs_compat.load_file child);
  check int "failed rotation does not append or remove current log" 17 (file_size path)

let test_disabled_rotation_preserves_backups () =
  with_rotation ~max_bytes:0 ~retained:0 @@ fun () ->
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup dir) @@ fun () ->
  let path = Filename.concat dir "metrics.jsonl" in
  write_bytes path 17;
  Fs_compat.save_file (path ^ ".1") "retained";
  Keeper_types_support.append_jsonl_line path (`Null);
  check string "zero size disables retention cleanup" "retained" (Fs_compat.load_file (path ^ ".1"));
  check int "disabled rotation still appends" 22 (file_size path)

let with_fs_mode use_eio f () =
  let previous = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    match previous with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
    (fun () ->
      with_rotation ~max_bytes:10_485_760 ~retained:1 (fun () ->
        if use_eio then Eio_main.run (fun env -> Fs_compat.set_fs (Eio.Stdenv.fs env); f ())
        else (Fs_compat.clear_fs (); f ())))

let () =
  let cases =
    [ "no rotation under threshold", test_no_rotation_under_threshold
    ; "rotation at threshold", test_rotation_at_threshold
    ; "rotation shifts existing backups", test_rotation_shifts_existing
    ; "nonexistent file safe", test_nonexistent_file
    ; "append triggers rotation", test_append_with_rotation
    ; "zero retention removes backups", test_zero_retention_discards_backups
    ; "reduced retention prunes and shifts", test_reduced_retention_prunes_and_shifts
    ; "unrelated names survive cleanup", test_retention_preserves_unrelated_names
    ; "symlink targets survive cleanup", test_retention_unlinks_symlinks_without_following
    ; "directories refuse cleanup", test_retention_refuses_directory_collision 0
    ; "directories refuse shifting", test_retention_refuses_directory_collision 2
    ; "zero size disables cleanup", test_disabled_rotation_preserves_backups ] in
  run "Keeper metrics rotation"
    (List.map (fun (label, use_eio) -> label,
      List.map (fun (name, f) -> test_case name `Quick (with_fs_mode use_eio f)) cases)
      ["stdlib filesystem", false; "Eio filesystem", true])
