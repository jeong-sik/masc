open Masc

let with_temp_config f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_eio_clock env;
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
     | Ok Workspace.Task_deleted -> ()
     | Error error -> Alcotest.fail (Masc_domain.show_masc_error error)
     | Ok _ -> Alcotest.fail "unexpected deletion outcome");
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
     | Ok _ -> Alcotest.fail "delete unexpectedly succeeded"
     | Error error ->
       Alcotest.failf "unexpected error: %s" (Masc_domain.show_masc_error error));
    Alcotest.(check string)
      "primary backlog remains byte-identical"
      "{not-json"
      (Fs_compat.load_file backlog_path))
;;

let make_task config title =
  match Workspace.add_task_with_result config ~title ~priority:3 ~description:"" with
  | Ok task -> task.task_id
  | Error error -> Alcotest.fail (Workspace.add_task_error_to_string error)
;;

let link config goal_id task_id =
  match Workspace_goal_index.link_task_to_goal_result config ~goal_id ~task_id with
  | Ok () -> () | Error message -> Alcotest.fail message
;;

let test_deletion_prunes_only_its_references () =
  with_temp_config (fun config ->
    ignore (Workspace.init config ~agent_name:(Some "tester"));
    let target = make_task config "target" in
    let other = make_task config "other" in
    link config "goal-a" target; link config "goal-a" other;
    link config "goal-b" target; link config "goal-c" other;
    (match Workspace.delete_task_r config ~task_id:target with
     | Ok Workspace.Task_deleted -> () | _ -> Alcotest.fail "delete failed");
    Alcotest.(check (list (pair string (list string)))) "other links preserved"
      ["goal-a",[other]; "goal-c",[other]]
      (Workspace_goal_index.read_goal_task_links config))
;;

let test_cleanup_failure_and_idempotent_retry () =
  with_temp_config (fun config ->
    ignore (Workspace.init config ~agent_name:(Some "tester"));
    let target = make_task config "target" in
    link config "goal-a" target;
    let path = Workspace_goal_index.goal_task_links_path config in
    let original = Fs_compat.load_file path in
    write_string path "{broken";
    (match Workspace.delete_task_r config ~task_id:target with
     | Ok (Workspace.Task_delete_cleanup_failed (_::_)) -> ()
     | _ -> Alcotest.fail "must report committed Task deletion with failed cleanup");
    let backlog = Workspace.read_backlog config in
    Alcotest.(check int) "Task is absent despite cleanup failure" 0 (List.length backlog.tasks);
    Alcotest.(check string) "bad primary not rewritten from mirror" "{broken" (Fs_compat.load_file path);
    write_string path original;
    (match Workspace.delete_task_r config ~task_id:target with
     | Ok Workspace.Task_already_absent -> () | _ -> Alcotest.fail "retry did not settle");
    Alcotest.(check int) "retry does not bump backlog revision" backlog.version (Workspace.read_backlog config).version;
    Alcotest.(check (list (pair string (list string)))) "retry removed remaining links" []
      (Workspace_goal_index.read_goal_task_links config))
;;

let test_backlog_failure_does_not_touch_links () =
  with_temp_config (fun config ->
    ignore (Workspace.init config ~agent_name:(Some "tester"));
    let target = make_task config "target" in
    link config "goal-a" target;
    let links = Workspace_goal_index.goal_task_links_path config in
    let original = Fs_compat.load_file links in
    let backlog = Workspace.read_backlog config in
    (* Revision exhaustion is a deterministic precommit write failure. *)
    Workspace.write_backlog config {backlog with version=max_int-1};
    (match Workspace.delete_task_r config ~task_id:target with
     | Error (Masc_domain.System (Masc_domain.System_error.IoError _)) -> ()
     | _ -> Alcotest.fail "write failure must not claim deletion");
    Alcotest.(check int) "Task remains" 1 (List.length (Workspace.read_backlog config).tasks);
    Alcotest.(check string) "links untouched" original (Fs_compat.load_file links))
;;

let test_retry_repairs_failed_recovery_copy () =
  List.iter (fun damage_links -> with_temp_config (fun config ->
    ignore (Workspace.init config ~agent_name:(Some "tester"));
    let target = make_task config "target" in
    link config "goal-a" target;
    let primary = if damage_links then Workspace_goal_index.goal_task_links_path config
      else Workspace.backlog_path config in
    let recovery = primary ^ ".last-good" in
    Sys.remove recovery;
    Unix.mkdir recovery 0o755;
    (match Workspace.delete_task_r config ~task_id:target with
     | Ok (Workspace.Task_delete_cleanup_failed (_::_)) -> ()
     | _ -> Alcotest.fail "failed postcommit recovery write must be visible");
    let revision = (Workspace.read_backlog config).version in
    Unix.rmdir recovery;
    (match Workspace.delete_task_r config ~task_id:target with
     | Ok Workspace.Task_already_absent -> ()
     | _ -> Alcotest.fail "restored recovery target must settle on retry");
    Alcotest.(check string) "recovery matches committed primary after retry"
      (Fs_compat.load_file primary) (Fs_compat.load_file recovery);
    Alcotest.(check int) "repair does not create revision" revision (Workspace.read_backlog config).version))
    [false; true]
;;

let () =
  Alcotest.run
    "Workspace task delete"
    [ ( "delete"
      , [ Alcotest.test_case "retry repairs both stores' failed recovery writes" `Quick test_retry_repairs_failed_recovery_copy
        ; Alcotest.test_case "only deleted Task references removed" `Quick test_deletion_prunes_only_its_references
        ; Alcotest.test_case "failed cleanup remains retryable after deletion" `Quick test_cleanup_failure_and_idempotent_retry
        ; Alcotest.test_case "uncommitted backlog failure preserves links" `Quick test_backlog_failure_does_not_touch_links
        ; Alcotest.test_case
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
