(** Regression: [keeper_task_create] must surface a task-creation failure as
    a typed failure, never as [ok:true].

    Before this fix, the handler called [Workspace_task.add_task], which
    folds [add_task_with_result]'s [Error] into a display string and drops
    it. This branch then unconditionally returned [ok:true,
    typed_outcome:Progress] -- a failed explicit goal-link write (or backlog
    write) was invisible to the keeper. See
    [Workspace_task.add_task_with_result] for the typed error this now
    surfaces instead. *)

open Alcotest
open Masc

module Task = Masc.Keeper_tool_task_runtime
module U = Yojson.Safe.Util

let with_test_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.temp_dir "masc_keeper_task_create_typed_failure_" "" in
  let config = Workspace.default_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "operator") in
  try
    f config;
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir
  with
  | e ->
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir;
    raise e
;;

(* Swaps a config file path for a directory: the read/write that would
   touch it fails immediately. Same fault-injection shape as
   [make_primary_goal_task_links_path_unwritable] in
   test_workspace_goal_index.ml. *)
let make_path_unwritable path =
  if Sys.file_exists path && not (Sys.is_directory path) then Sys.remove path;
  if not (Sys.file_exists path) then Unix.mkdir path 0o755
;;

let keeper_meta () =
  let name = "task-create-typed-failure-test" in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String "trace-task-create-typed-failure"
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)
;;

let test_task_create_goal_link_write_failure_returns_typed_failure () =
  with_test_env (fun config ->
    (match Goal_store.upsert_goal config ~id:"goal-a" ~title:"Goal A"
             ~metric:"m" ~target_value:"1" () with
     | Ok _ -> ()
     | Error msg -> fail ("upsert_goal failed: " ^ msg));
    make_path_unwritable (Workspace_goal_index.goal_task_links_path config);
    let meta = keeper_meta () in
    let execution =
      Task.handle_keeper_task_tool_with_outcome
        ~config
        ~meta
        ~name:"keeper_task_create"
        ~args:
          (`Assoc
            [ "title", `String "Blocked by goal-link write failure"
            ; "description", `String "must not silently report success"
            ; "priority", `Int 3
            ; "goal_id", `String "goal-a"
            ])
    in
    (* An IO/write failure is [Runtime_failure], not [Workflow_rejection]:
       only [Runtime_failure] logs at ERROR
       ({!Tool_result.log_level_of_failure_class}), and it feeds the
       terminal-effect routing in {!Keeper_runtime_failure_route}. Asserted
       against the typed disposition, not the JSON body, since that is what
       those two consumers read. *)
    (match execution.disposition with
     | Tool_result.Failed Tool_result.Runtime_failure -> ()
     | Tool_result.Failed other ->
       failf
         "expected Runtime_failure, got %s"
         (Tool_result.tool_failure_class_to_string other)
     | Tool_result.Completed () -> fail "expected failure, task create reported ok:true"
     | Tool_result.Deferred () -> fail "expected failure, task create was deferred");
    let json = Yojson.Safe.from_string execution.raw_output in
    check bool "task create reports failure, not ok:true" false
      (json |> U.member "ok" |> U.to_bool);
    check string "typed_outcome is Error, not Progress" "Error"
      (json |> U.member "typed_outcome" |> U.member "kind" |> U.to_string);
    match Workspace.get_tasks_raw config with
    | [] -> ()
    | tasks -> failf "expected no persisted task, got %d" (List.length tasks))
;;

(* Pure classifier coverage over all six [Workspace_task.add_task_error]
   variants, constructed directly rather than reproduced end-to-end:
   [keeper_task_create]'s live tool args never set [predecessor_task_id]
   (RFC-0323 W2 scopes that arg to [masc_add_task]), so [Unknown_predecessor]
   / [Predecessor_not_terminal] cannot be produced through this tool's
   argument surface today. This proves the two routing buckets stay
   separated regardless. *)
let test_task_create_failure_route_splits_workflow_from_runtime () =
  let workflow_rejection_cases =
    [ "Unknown_predecessor", Workspace_task.Unknown_predecessor "task-999"
    ; ( "Predecessor_not_terminal"
      , Workspace_task.Predecessor_not_terminal
          { predecessor_task_id = "task-001"; status = "todo" } )
    ]
  in
  let runtime_failure_cases =
    [ "Backlog_read_failed", Workspace_task.Backlog_read_failed "disk error"
    ; "Goal_link_write_failed", Workspace_task.Goal_link_write_failed "disk error"
    ; "Backlog_write_failed", Workspace_task.Backlog_write_failed "disk error"
    ; "Unexpected_error", Workspace_task.Unexpected_error "Failure(\"boom\")"
    ]
  in
  List.iter
    (fun (label, err) ->
       match Task.task_create_failure_route err with
       | Task.Task_create_workflow_rejection -> ()
       | Task.Task_create_runtime_failure ->
         failf "%s: expected Task_create_workflow_rejection, got runtime_failure" label)
    workflow_rejection_cases;
  List.iter
    (fun (label, err) ->
       match Task.task_create_failure_route err with
       | Task.Task_create_runtime_failure -> ()
       | Task.Task_create_workflow_rejection ->
         failf "%s: expected Task_create_runtime_failure, got workflow_rejection" label)
    runtime_failure_cases
;;

let () =
  run "keeper task create typed failure"
    [ ( "keeper_task_create"
      , [ test_case
            "goal-link write failure surfaces as Runtime_failure, not ok:true"
            `Quick
            test_task_create_goal_link_write_failure_returns_typed_failure
        ; test_case
            "add_task_error route splits Workflow_rejection from Runtime_failure"
            `Quick
            test_task_create_failure_route_splits_workflow_from_runtime
        ] )
    ]
;;
