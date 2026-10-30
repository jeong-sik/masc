(** Tests for Fs_result — result-based filesystem operations. *)

open Agent_core

let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

(* ── read_file ────────────────────────────────────────── *)

let test_read_file_success () =
  let path = Filename.temp_file "fs_test_" ".txt" in
  let oc = open_out path in
  output_string oc "hello world";
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () ->
       match Fs_result.read_file path with
       | Ok content -> check_string "content" "hello world" content
       | Error _ -> Alcotest.fail "should succeed")
;;

let test_read_file_nonexistent () =
  match Fs_result.read_file "/nonexistent/path/file.txt" with
  | Error (Error.Io (FileOpFailed { op; _ })) -> check_string "op" "read" op
  | Error _ -> Alcotest.fail "wrong error type"
  | Ok _ -> Alcotest.fail "should fail"
;;

(* ── write_file ───────────────────────────────────────── *)

let test_write_file_success () =
  let dir = Filename.get_temp_dir_name () in
  let path =
    Filename.concat
      dir
      (Printf.sprintf
         "fs_write_test_%d.txt"
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () ->
       match Fs_result.write_file path "test content" with
       | Ok () ->
         (match Fs_result.read_file path with
          | Ok content -> check_string "written content" "test content" content
          | Error _ -> Alcotest.fail "read back failed")
       | Error _ -> Alcotest.fail "write should succeed")
;;

let test_write_file_creates_dirs () =
  let base = Filename.get_temp_dir_name () in
  let nested =
    Filename.concat
      base
      (Printf.sprintf
         "fs_test_nested_%d/sub"
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  let path = Filename.concat nested "file.txt" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with
       | _ -> ());
      (try Sys.rmdir nested with
       | _ -> ());
      try Sys.rmdir (Filename.dirname nested) with
      | _ -> ())
    (fun () ->
       match Fs_result.write_file path "nested content" with
       | Ok () -> check_bool "file exists" true (Fs_result.file_exists path)
       | Error _ -> Alcotest.fail "write should create dirs")
;;

let test_write_file_parent_is_file () =
  let parent = Filename.temp_file "fs_parent_file_" ".txt" in
  let path = Filename.concat parent "child.txt" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove parent with
      | _ -> ())
    (fun () ->
       match Fs_result.write_file path "content" with
       | Error (Error.Io (FileOpFailed { op; path = err_path; detail })) ->
         check_string "op" "mkdir_p" op;
         check_string "path" parent err_path;
         check_string "detail" "path exists and is not a directory" detail
       | Error _ -> Alcotest.fail "wrong error type"
       | Ok () -> Alcotest.fail "write should reject file parent")
;;

(* ── append_file ──────────────────────────────────────── *)

let test_append_file () =
  let path = Filename.temp_file "fs_append_" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () ->
       ignore (Fs_result.write_file path "line1\n");
       ignore (Fs_result.append_file path "line2\n");
       match Fs_result.read_file path with
       | Ok content -> check_string "appended" "line1\nline2\n" content
       | Error _ -> Alcotest.fail "read failed")
;;

(* ── ensure_dir ───────────────────────────────────────── *)

let test_ensure_dir_existing () =
  match Fs_result.ensure_dir (Filename.get_temp_dir_name ()) with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "should succeed for existing dir"
;;

let test_ensure_dir_new () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "fs_ensure_%d" (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  Fun.protect
    ~finally:(fun () ->
      try Sys.rmdir path with
      | _ -> ())
    (fun () ->
       match Fs_result.ensure_dir path with
       | Ok () -> check_bool "dir exists" true (Sys.file_exists path)
       | Error _ -> Alcotest.fail "should succeed")
;;

let test_ensure_dir_existing_file () =
  let path = Filename.temp_file "fs_ensure_file_" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () ->
       match Fs_result.ensure_dir path with
       | Error (Error.Io (FileOpFailed { op; path = err_path; detail })) ->
         check_string "op" "mkdir_p" op;
         check_string "path" path err_path;
         check_string "detail" "path exists and is not a directory" detail
       | Error _ -> Alcotest.fail "wrong error type"
       | Ok () -> Alcotest.fail "file path should not be accepted as a directory")
;;

let test_ensure_dir_empty_path () =
  match Fs_result.ensure_dir "" with
  | Error (Error.Io (FileOpFailed { op; path; detail })) ->
    check_string "op" "mkdir_p" op;
    check_string "path" "" path;
    check_string "detail" "empty directory path" detail
  | Error _ -> Alcotest.fail "wrong error type"
  | Ok () -> Alcotest.fail "empty path should fail"
;;

(* ── file_exists ──────────────────────────────────────── *)

let test_file_exists_true () =
  let path = Filename.temp_file "fs_exists_" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () -> check_bool "exists" true (Fs_result.file_exists path))
;;

let test_file_exists_false () =
  check_bool "not exists" false (Fs_result.file_exists "/nonexistent/path/file.xyz")
;;

let test_file_exists_directory () =
  check_bool
    "directory is not file"
    false
    (Fs_result.file_exists (Filename.get_temp_dir_name ()))
;;

(* ── remove_file ──────────────────────────────────────── *)

let test_remove_file_success () =
  let path = Filename.temp_file "fs_remove_" ".txt" in
  match Fs_result.remove_file path with
  | Ok () -> check_bool "removed" false (Fs_result.file_exists path)
  | Error _ -> Alcotest.fail "should succeed"
;;

let test_remove_file_nonexistent () =
  match Fs_result.remove_file "/nonexistent/file.txt" with
  | Ok () -> () (* remove_file succeeds if file doesn't exist *)
  | Error _ -> Alcotest.fail "should succeed for nonexistent"
;;

(* ── read_dir ─────────────────────────────────────────── *)

let test_read_dir_success () =
  let dir = Filename.get_temp_dir_name () in
  match Fs_result.read_dir dir with
  | Ok entries -> check_bool "has entries" true (List.length entries >= 0)
  | Error _ -> Alcotest.fail "should succeed"
;;

let test_read_dir_nonexistent () =
  match Fs_result.read_dir "/nonexistent/dir" with
  | Error (Error.Io (FileOpFailed { op; _ })) -> check_string "op" "read_dir" op
  | Error _ -> Alcotest.fail "wrong error type"
  | Ok _ -> Alcotest.fail "should fail"
;;

(* ── io_error_of_exn ──────────────────────────────────── *)

let test_io_error_of_exn_sys_error () =
  match Fs_result.io_error_of_exn ~op:"test" ~path:"/x" (Sys_error "boom") with
  | Error (Error.Io (FileOpFailed { op; path; detail })) ->
    check_string "op" "test" op;
    check_string "path" "/x" path;
    check_string "detail" "boom" detail
  | _ -> Alcotest.fail "expected FileOpFailed"
;;

let test_io_error_of_exn_failure () =
  match Fs_result.io_error_of_exn ~op:"w" ~path:"/y" (Failure "bad") with
  | Error (Error.Io (FileOpFailed { detail; _ })) -> check_string "detail" "bad" detail
  | _ -> Alcotest.fail "expected FileOpFailed"
;;

(* ── Suite ────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "fs_result"
    [ ( "read_file"
      , [ Alcotest.test_case "success" `Quick test_read_file_success
        ; Alcotest.test_case "nonexistent" `Quick test_read_file_nonexistent
        ] )
    ; ( "write_file"
      , [ Alcotest.test_case "success" `Quick test_write_file_success
        ; Alcotest.test_case "creates dirs" `Quick test_write_file_creates_dirs
        ; Alcotest.test_case "parent is file" `Quick test_write_file_parent_is_file
        ] )
    ; "append_file", [ Alcotest.test_case "append" `Quick test_append_file ]
    ; ( "ensure_dir"
      , [ Alcotest.test_case "existing" `Quick test_ensure_dir_existing
        ; Alcotest.test_case "new" `Quick test_ensure_dir_new
        ; Alcotest.test_case "existing file" `Quick test_ensure_dir_existing_file
        ; Alcotest.test_case "empty path" `Quick test_ensure_dir_empty_path
        ] )
    ; ( "file_exists"
      , [ Alcotest.test_case "true" `Quick test_file_exists_true
        ; Alcotest.test_case "false" `Quick test_file_exists_false
        ; Alcotest.test_case "directory" `Quick test_file_exists_directory
        ] )
    ; ( "remove_file"
      , [ Alcotest.test_case "success" `Quick test_remove_file_success
        ; Alcotest.test_case "nonexistent" `Quick test_remove_file_nonexistent
        ] )
    ; ( "read_dir"
      , [ Alcotest.test_case "success" `Quick test_read_dir_success
        ; Alcotest.test_case "nonexistent" `Quick test_read_dir_nonexistent
        ] )
    ; ( "io_error_of_exn"
      , [ Alcotest.test_case "sys_error" `Quick test_io_error_of_exn_sys_error
        ; Alcotest.test_case "failure" `Quick test_io_error_of_exn_failure
        ] )
    ]
;;
