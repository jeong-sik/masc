open Alcotest
open Masc

let temp_dir () = Filename.temp_dir "goal_approved_task_projector" ""

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "test"));
      f config)
;;

let create_goal config ~id ~target =
  match
    Goal_store.upsert_goal
      config
      ~id
      ~title:id
      ~metric:"verifier_approved_done_tasks"
      ~target_value:(string_of_int target)
      ~phase:Goal_phase.Executing
      ()
  with
  | Ok (goal, _) -> goal
  | Error detail -> fail detail
;;

let emit_task_event config ~kind ~task_id =
  ignore
    (Activity_graph.emit
       config
       ~kind:(Event_kind.Task.to_string kind)
       ~actor:(Activity_graph.entity ~kind:"agent" "verifier")
       ~subject:(Activity_graph.entity ~kind:"task" task_id)
       ~tags:[ "task" ]
       ~payload:(`Assoc [ "task_id", `String task_id ])
       ())
;;

let goal_phase config goal_id =
  match Goal_store.get_goal config ~goal_id with
  | Some goal -> goal.phase
  | None -> fail ("missing goal: " ^ goal_id)
;;

let goal_event_count config =
  let path = Goal_event.path config in
  if not (Sys.file_exists path)
  then 0
  else
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
    |> List.length
;;

let test_restart_replay_and_idempotence () =
  with_workspace
  @@ fun config ->
  let goal = create_goal config ~id:"goal-replay" ~target:1 in
  Workspace_goal_index.link_task_to_goal
    config
    ~goal_id:goal.id
    ~task_id:"task-1";
  emit_task_event config ~kind:Event_kind.Task.Approved ~task_id:"task-1";
  let projector = Goal_approved_task_projector.create () in
  (match Goal_approved_task_projector.run projector config with
   | Ok report ->
       check (list string) "completed goal" [ goal.id ] report.completed_goal_ids
   | Error error ->
       fail (Goal_approved_task_projector.error_to_string error));
  check string "goal completed" "completed"
    (Goal_phase.to_string (goal_phase config goal.id));
  let version = (Goal_store.read_state config).version in
  check int "one canonical event" 1 (goal_event_count config);
  (match Goal_approved_task_projector.run projector config with
   | Ok _ -> ()
   | Error error ->
       fail (Goal_approved_task_projector.error_to_string error));
  check int "idempotent version" version (Goal_store.read_state config).version;
  check int "idempotent event" 1 (goal_event_count config)
;;

let test_target_counts_distinct_approved_tasks () =
  with_workspace
  @@ fun config ->
  let goal = create_goal config ~id:"goal-two" ~target:2 in
  Workspace_goal_index.write_goal_task_links
    config
    [ goal.id, [ "task-1"; "task-1"; "task-2" ] ];
  let projector = Goal_approved_task_projector.create () in
  emit_task_event config ~kind:Event_kind.Task.Approved ~task_id:"task-1";
  emit_task_event config ~kind:Event_kind.Task.Approved ~task_id:"task-1";
  ignore (Goal_approved_task_projector.run projector config);
  check string "duplicate approval is one task" "executing"
    (Goal_phase.to_string (goal_phase config goal.id));
  emit_task_event config ~kind:Event_kind.Task.Approved ~task_id:"task-2";
  (match Goal_approved_task_projector.run projector config with
   | Ok _ -> ()
   | Error error ->
       fail (Goal_approved_task_projector.error_to_string error));
  check string "second distinct task completes" "completed"
    (Goal_phase.to_string (goal_phase config goal.id))
;;

let test_direct_done_is_not_approval () =
  with_workspace
  @@ fun config ->
  let goal = create_goal config ~id:"goal-direct" ~target:1 in
  Workspace_goal_index.link_task_to_goal
    config
    ~goal_id:goal.id
    ~task_id:"task-direct";
  emit_task_event config ~kind:Event_kind.Task.Done ~task_id:"task-direct";
  let projector = Goal_approved_task_projector.create () in
  (match Goal_approved_task_projector.run projector config with
   | Ok _ -> ()
   | Error error ->
       fail (Goal_approved_task_projector.error_to_string error));
  check string "direct done ignored" "executing"
    (Goal_phase.to_string (goal_phase config goal.id))
;;

let test_link_failure_holds_cursor_for_retry () =
  with_workspace
  @@ fun config ->
  let goal = create_goal config ~id:"goal-retry" ~target:1 in
  emit_task_event config ~kind:Event_kind.Task.Approved ~task_id:"task-retry";
  let links_path = Workspace_goal_index.goal_task_links_path config in
  let recovery_path = links_path ^ ".last-good" in
  Unix.mkdir links_path 0o755;
  Unix.mkdir recovery_path 0o755;
  let projector = Goal_approved_task_projector.create () in
  (match Goal_approved_task_projector.run projector config with
   | Error (Goal_approved_task_projector.Link_read_failed _) -> ()
   | Error error ->
       fail (Goal_approved_task_projector.error_to_string error)
   | Ok _ -> fail "expected link read failure");
  check int "cursor held" 0 (Goal_approved_task_projector.last_seq projector);
  Unix.rmdir links_path;
  Unix.rmdir recovery_path;
  Workspace_goal_index.link_task_to_goal
    config
    ~goal_id:goal.id
    ~task_id:"task-retry";
  (match Goal_approved_task_projector.run projector config with
   | Ok _ -> ()
   | Error error ->
       fail (Goal_approved_task_projector.error_to_string error));
  check string "retry completes" "completed"
    (Goal_phase.to_string (goal_phase config goal.id))
;;

let test_goal_event_failure_is_repaired () =
  with_workspace
  @@ fun config ->
  let goal = create_goal config ~id:"goal-event-repair" ~target:1 in
  Workspace_goal_index.link_task_to_goal
    config
    ~goal_id:goal.id
    ~task_id:"task-event-repair";
  emit_task_event
    config
    ~kind:Event_kind.Task.Approved
    ~task_id:"task-event-repair";
  let event_path = Goal_event.path config in
  Unix.mkdir event_path 0o755;
  let projector = Goal_approved_task_projector.create () in
  (match Goal_approved_task_projector.run projector config with
   | Error (Goal_approved_task_projector.Goal_event_failed _) -> ()
   | Error error ->
       fail (Goal_approved_task_projector.error_to_string error)
   | Ok _ -> fail "expected Goal event failure");
  check string "Goal update committed" "completed"
    (Goal_phase.to_string (goal_phase config goal.id));
  check int "cursor held for repair" 0
    (Goal_approved_task_projector.last_seq projector);
  Unix.rmdir event_path;
  (match Goal_approved_task_projector.run projector config with
   | Ok _ -> ()
   | Error error ->
       fail (Goal_approved_task_projector.error_to_string error));
  check int "canonical event repaired once" 1 (goal_event_count config);
  (match Goal_approved_task_projector.run projector config with
   | Ok _ -> ()
   | Error error ->
       fail (Goal_approved_task_projector.error_to_string error));
  check int "repair is idempotent" 1 (goal_event_count config)
;;

let () =
  run
    "goal-approved-task-projector"
    [ ( "projection"
      , [ test_case
            "restart replay and idempotence"
            `Quick
            test_restart_replay_and_idempotence
        ; test_case
            "target counts distinct approvals"
            `Quick
            test_target_counts_distinct_approved_tasks
        ; test_case
            "direct done is ignored"
            `Quick
            test_direct_done_is_not_approval
        ; test_case
            "link failure holds cursor"
            `Quick
            test_link_failure_holds_cursor_for_retry
        ; test_case
            "Goal event failure is repaired"
            `Quick
            test_goal_event_failure_is_repaired
        ] )
    ]
;;
