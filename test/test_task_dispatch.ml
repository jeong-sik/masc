module Types = Masc_domain

open Masc

let with_temp_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "task_dispatch_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  let config = Workspace.default_config dir in
  Fun.protect ~finally:(fun () ->
      let rec rm path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Sys.readdir path
            |> Array.iter (fun name -> rm (Filename.concat path name));
            Unix.rmdir path)
          else
            Unix.unlink path
      in
      rm dir) (fun () -> f config)

let test_default_backend_jsonl () =
  Task.Dispatch.reset_for_test ();
  match Task.Dispatch.backend () with
  | Task.Dispatch.Jsonl -> ()

let test_add_task_in_jsonl_mode () =
  with_temp_config (fun config ->
      ignore (Workspace.init config ~agent_name:(Some "tester"));
      Task.Dispatch.reset_for_test ();
      Task.Dispatch.init_jsonl ();
      match Task.Dispatch.add_task config ~title:"dispatch task" ~priority:3
              ~description:"from task dispatch test"
      with
      | Error e -> Alcotest.fail (Masc_domain.show_masc_error e)
      | Ok message ->
          Alcotest.(check bool) "returns success message" true
            (String.length message > 0))

(* update_status coverage was retired with the function (RFC-0323 G-7);
   delete_task keeps its locked-path pin. *)
let test_delete_uses_locked_jsonl_path () =
  with_temp_config (fun config ->
      ignore (Workspace.init config ~agent_name:(Some "tester"));
      Task.Dispatch.reset_for_test ();
      Task.Dispatch.init_jsonl ();
      let task_id =
        match
          Task.Dispatch.add_task config ~title:"locked dispatch task" ~priority:3
            ~description:"from task dispatch lock test"
        with
        | Error e -> Alcotest.fail (Masc_domain.show_masc_error e)
        | Ok _ ->
            let backlog = Workspace.read_backlog config in
            (match backlog.tasks with
             | [ task ] -> task.Masc_domain.id
             | tasks ->
                 Alcotest.failf "expected exactly one task, got %d"
                   (List.length tasks))
      in
      (match Task.Dispatch.delete_task config ~task_id with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Masc_domain.show_masc_error e));
      let deleted = Workspace.read_backlog config in
      Alcotest.(check int) "version bumped by delete" 3 deleted.version;
      Alcotest.(check int) "task deleted" 0 (List.length deleted.tasks))

let write_string path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let test_delete_returns_error_when_backlog_unreadable () =
  with_temp_config (fun config ->
      ignore (Workspace.init config ~agent_name:(Some "tester"));
      Task.Dispatch.reset_for_test ();
      Task.Dispatch.init_jsonl ();
      let backlog_path = Filename.concat (Workspace.tasks_dir config) "backlog.json" in
      write_string backlog_path "{not-json";
      write_string (backlog_path ^ ".last-good") "{not-json";
      let expect_io_error label = function
        | Error (Masc_domain.System (Masc_domain.System_error.IoError _)) -> ()
        | Ok () -> Alcotest.failf "%s unexpectedly succeeded" label
        | Error e ->
            Alcotest.failf "%s returned unexpected error: %s" label
              (Masc_domain.show_masc_error e)
      in
      expect_io_error "delete_task"
        (Task.Dispatch.delete_task config ~task_id:"missing");
      let ic = open_in backlog_path in
      let primary =
        Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () -> really_input_string ic (in_channel_length ic))
      in
      Alcotest.(check string)
        "primary backlog not rewritten via empty fallback" "{not-json" primary)

let test_task_dispatch_source_pins_backlog_lock () =
  let candidates =
    [
      "lib/task_dispatch.ml";
      "../lib/task_dispatch.ml";
      "../../lib/task_dispatch.ml";
    ]
  in
  let source =
    match List.find_opt Sys.file_exists candidates with
    | Some path ->
        let ic = open_in path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () -> really_input_string ic (in_channel_length ic))
    | None -> Alcotest.skip ()
  in
  let contains s sub =
    let n = String.length s and m = String.length sub in
    let rec loop i =
      if i + m > n then false
      else if String.sub s i m = sub then true
      else loop (i + 1)
    in
    if m = 0 then true else loop 0
  in
  Alcotest.(check bool)
    "Task.Dispatch mutations use Workspace backlog lock"
    true
    (contains source "Workspace.with_file_lock config (backlog_lock_path config)");
  Alcotest.(check bool)
    "Task.Dispatch mutations read backlog as result under lock"
    true
    (contains source "Workspace.read_backlog_r config")

let test_reset_clears_pg_state_shape () =
  Task.Dispatch.reset_for_test ();
  Task.Dispatch.init_jsonl ();
  Task.Dispatch.reset_for_test ();
  match Task.Dispatch.backend () with
  | Task.Dispatch.Jsonl -> ()

let () =
  Alcotest.run "Task.Dispatch"
    [
      ( "backend",
        [
          Alcotest.test_case "default jsonl" `Quick test_default_backend_jsonl;
          Alcotest.test_case "reset clears state" `Quick
            test_reset_clears_pg_state_shape;
        ] );
      ( "jsonl",
        [
          Alcotest.test_case "add task" `Quick test_add_task_in_jsonl_mode;
          Alcotest.test_case "delete uses locked path" `Quick
            test_delete_uses_locked_jsonl_path;
          Alcotest.test_case "delete fails on unreadable backlog" `Quick
            test_delete_returns_error_when_backlog_unreadable;
          Alcotest.test_case "source pins backlog lock" `Quick
            test_task_dispatch_source_pins_backlog_lock;
        ] );
    ]
