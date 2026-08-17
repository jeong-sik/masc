(** Regression: [keeper_task_create] must surface a task-creation failure as
    a typed failure, never as [ok:true].

    Before this fix, the handler called [Workspace_task.add_task], which
    folds [add_task_with_result]'s [Error] into a display string and drops
    it. This branch then unconditionally returned [ok:true,
    typed_outcome:Progress] -- a failed goal-link write (or backlog write)
    was invisible to the keeper. See [Workspace_task.add_task_with_result]
    for the typed error this now surfaces instead. *)

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

let meta_with_active_goals goal_ids =
  let name = "task-create-typed-failure-test" in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "agent_name", `String (Keeper_identity.keeper_agent_name name)
        ; "trace_id", `String "trace-task-create-typed-failure"
        ; ( "active_goal_ids"
          , `List (List.map (fun goal_id -> `String goal_id) goal_ids) )
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)
;;

let test_task_create_goal_link_write_failure_returns_typed_failure () =
  with_test_env (fun config ->
    (match Goal_store.upsert_goal config ~id:"goal-a" ~title:"Goal A" () with
     | Ok _ -> ()
     | Error msg -> fail ("upsert_goal failed: " ^ msg));
    make_path_unwritable (Workspace_goal_index.goal_task_links_path config);
    let meta = meta_with_active_goals [ "goal-a" ] in
    let payload =
      Task.handle_keeper_task_tool
        ~config
        ~meta
        ~name:"keeper_task_create"
        ~args:
          (`Assoc
            [ "title", `String "Blocked by goal-link write failure"
            ; "description", `String "must not silently report success"
            ; "priority", `Int 3
            ])
    in
    let json = Yojson.Safe.from_string payload in
    check bool "task create reports failure, not ok:true" false
      (json |> U.member "ok" |> U.to_bool);
    check string "typed_outcome is Error, not Progress" "Error"
      (json |> U.member "typed_outcome" |> U.member "kind" |> U.to_string);
    match Workspace.get_tasks_raw config with
    | [] -> ()
    | tasks -> failf "expected no persisted task, got %d" (List.length tasks))
;;

let () =
  run "keeper task create typed failure"
    [ ( "keeper_task_create"
      , [ test_case
            "goal-link write failure surfaces as typed failure, not ok:true"
            `Quick
            test_task_create_goal_link_write_failure_returns_typed_failure
        ] )
    ]
;;
