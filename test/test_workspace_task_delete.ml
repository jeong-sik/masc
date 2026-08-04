open Masc

let with_temp_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_file "workspace_task_delete_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  let config = Workspace.default_config dir in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () -> f config)
;;

let write_string path content =
  Out_channel.with_open_bin path (fun channel -> output_string channel content)
;;

let test_delete_uses_canonical_locked_store () =
  with_temp_config (fun config ->
    ignore (Workspace.init config ~agent_name:(Some "tester"));
    let _ =
      Workspace.add_task
        config
        ~title:"locked task"
        ~priority:3
        ~description:"workspace delete test"
    in
    let backlog = Workspace.read_backlog config in
    let task_id =
      match backlog.tasks with
      | [ task ] -> task.Masc_domain.id
      | tasks -> Alcotest.failf "expected one task, got %d" (List.length tasks)
    in
    (match Workspace.delete_task_r config ~task_id with
     | Ok () -> ()
     | Error error -> Alcotest.fail (Masc_domain.show_masc_error error));
    let deleted = Workspace.read_backlog config in
    Alcotest.(check int) "version bumped by delete" (backlog.version + 1) deleted.version;
    Alcotest.(check int) "task deleted" 0 (List.length deleted.tasks))
;;

let test_delete_returns_typed_error_when_backlog_unreadable () =
  with_temp_config (fun config ->
    ignore (Workspace.init config ~agent_name:(Some "tester"));
    let backlog_path = Filename.concat (Workspace.tasks_dir config) "backlog.json" in
    write_string backlog_path "{not-json";
    write_string (backlog_path ^ ".last-good") "{not-json";
    (match Workspace.delete_task_r config ~task_id:"missing" with
     | Error (Masc_domain.System (Masc_domain.System_error.IoError _)) -> ()
     | Ok () -> Alcotest.fail "delete unexpectedly succeeded"
     | Error error ->
       Alcotest.failf "unexpected error: %s" (Masc_domain.show_masc_error error));
    Alcotest.(check string)
      "primary backlog remains byte-identical"
      "{not-json"
      (Fs_compat.load_file backlog_path))
;;

let () =
  Alcotest.run
    "Workspace task delete"
    [ ( "delete"
      , [ Alcotest.test_case
            "uses canonical locked store"
            `Quick
            test_delete_uses_canonical_locked_store
        ; Alcotest.test_case
            "fails typed on unreadable backlog"
            `Quick
            test_delete_returns_typed_error_when_backlog_unreadable
        ] )
    ]
;;
