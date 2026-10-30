(** test_planning_eio.ml - Tests for Planning_eio module (OCaml 5.x Pure Sync) *)

open Alcotest
open Masc
module Planning_eio = Masc.Task.Planning_eio

let temp_dir = ref ""

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

let setup () =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "planning_eio_test_%d" (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir dir 0o755;
  temp_dir := dir

let teardown () =
  (* Clean up temp directory *)
  if !temp_dir <> "" then begin
    (try rm_rf !temp_dir with _ -> ())
  end

let make_config () : Workspace.config =
  Workspace.default_config !temp_dir

let current_task_path config =
  Filename.concat (Workspace_utils.masc_dir config) "current_task"

let ensure_masc_dir config =
  let dir = Workspace_utils.masc_dir config in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755

let trash_dir config =
  Filename.concat (Workspace_utils.masc_dir config) "_trash"

let has_current_task_quarantine config =
  if not (Sys.file_exists (trash_dir config)) then false
  else
    Sys.readdir (trash_dir config)
    |> Array.exists (fun name -> String.starts_with ~prefix:"current_task." name)

let set_current_task_ok config ~task_id =
  match Planning_eio.set_current_task config ~task_id with
  | Ok () -> ()
  | Error msg -> fail msg

(* ===== Type Tests ===== *)

let test_session_context () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = make_config () in
  (* Initially no current task *)
  check (option string) "no current task" None (Planning_eio.get_current_task config);
  (* Set current task *)
  set_current_task_ok config ~task_id:"session-test-task";
  check (option string) "current task set" (Some "session-test-task") (Planning_eio.get_current_task config);
  (* Clear current task *)
  Planning_eio.clear_current_task config;
  check (option string) "current task cleared" None (Planning_eio.get_current_task config)

let test_current_task_dir_read_is_cleared () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = make_config () in
  let path = current_task_path config in
  ensure_masc_dir config;
  Unix.mkdir path 0o755;
  check (option string) "directory current_task reads as none" None
    (Planning_eio.get_current_task config);
  check bool "directory remains for write-path quarantine" true
    (Sys.file_exists path && Sys.is_directory path);
  rm_rf path

let test_set_current_task_quarantines_dir () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = make_config () in
  let path = current_task_path config in
  ensure_masc_dir config;
  Unix.mkdir path 0o755;
  Fs_compat.save_file (Filename.concat path "forensics.txt") "kept";
  set_current_task_ok config ~task_id:"recovered-task";
  check (option string) "recovered current task" (Some "recovered-task")
    (Planning_eio.get_current_task config);
  check bool "old directory quarantined" true
    (has_current_task_quarantine config);
  Planning_eio.clear_current_task config

let test_set_current_task_stops_when_quarantine_fails () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = make_config () in
  let path = current_task_path config in
  let trash = trash_dir config in
  if Sys.file_exists trash then rm_rf trash;
  Unix.mkdir path 0o755;
  Fs_compat.save_file (Filename.concat path "forensics.txt") "kept";
  if not (Sys.file_exists trash) then Unix.mkdir trash 0o755;
  Unix.chmod trash 0o555;
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists trash && Sys.is_directory trash then
        Unix.chmod trash 0o755;
      if Sys.file_exists path then rm_rf path;
      if Sys.file_exists trash then rm_rf trash)
    (fun () ->
      (match Planning_eio.set_current_task config ~task_id:"blocked-task" with
       | Ok () -> fail "expected set_current_task to fail"
       | Error msg ->
         check bool "error mentions quarantine failure" true
           (String.starts_with
              ~prefix:"failed to quarantine existing current_task directory"
              msg));
      check bool "current_task remains a directory" true
        (Sys.file_exists path && Sys.is_directory path);
      check (option string) "failed quarantine does not write over directory" None
        (Planning_eio.get_current_task config))

let test_clear_current_task_removes_empty_dir () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = make_config () in
  let path = current_task_path config in
  ensure_masc_dir config;
  Unix.mkdir path 0o755;
  Planning_eio.clear_current_task config;
  check bool "empty directory removed" false (Sys.file_exists path)

let () =
  setup ();
  at_exit teardown;
  Alcotest.run "planning_eio"
    [
      ( "current_task",
        [
          test_case "session_context" `Quick test_session_context;
          test_case "current_task dir read is cleared" `Quick
            test_current_task_dir_read_is_cleared;
          test_case "set_current_task quarantines dir" `Quick
            test_set_current_task_quarantines_dir;
          test_case "set_current_task stops when quarantine fails" `Quick
            test_set_current_task_stops_when_quarantine_fails;
          test_case "clear_current_task removes empty dir" `Quick
            test_clear_current_task_removes_empty_dir;
        ] );
    ]
