(* [read_backlog_snapshot] carries strict task identities and the revision from
   one authoritative read. The claimable count is derived from those rows, so
   the heading and rendered identities share one snapshot. *)

open Alcotest
open Masc

let () = Workspace_metric_hooks.install ()

(* The keeper.world frame prose this suite asserts (the "- Backlog
   revision:" row) moved out of the .ml sources into
   config/prompts/keeper.md as world.* keys, rendered through the prompt
   registry at assembly time. Loading them into the registry is what
   [Prompt_defaults.init] does below; the registry locates config/prompts
   itself under Dune. *)
let () =
  Masc.Prompt_defaults.init ()
;;

let make_config () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_claimable_summaries_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  let config = Workspace.default_config dir in
  let _ = Workspace.init config ~agent_name:(Some "claimable-probe") in
  config
;;

let cleanup config =
  let _ = Workspace.reset config in
  ()
;;

let make_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String "claimable-probe"
         ; "trace_id", `String "test-trace-claimable"
         ])
  with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)
;;

let add config ~title ~created_by =
  match
    Workspace.add_task_with_result
      ~created_by
      config
      ~title
      ~priority:2
      ~description:""
  with
  | Ok created -> Keeper_id.Task_id.of_string created.task_id |> Result.get_ok
  | Error error -> failwith (Workspace.add_task_error_to_string error)
;;

let add_with_priority config ~title ~created_by ~priority =
  match
    Workspace.add_task_with_result ~created_by config ~title ~priority ~description:""
  with
  | Ok created -> Keeper_id.Task_id.of_string created.task_id |> Result.get_ok
  | Error error -> failwith (Workspace.add_task_error_to_string error)
;;

let snapshot config meta =
  Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta
;;

let with_config f =
  let config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup config) (fun () -> f config (make_meta ()))
;;

(* The point of the change: a typed task identity reaches the keeper, not only
   a count. Opaque titles remain behind the task-tool boundary. *)
let test_a_claimable_task_is_named () =
  with_config (fun config meta ->
    let expected =
      add config ~title:"Wire the timeline panel" ~created_by:"someone-else"
    in
    match (snapshot config meta).claimable_tasks with
    | [ { task_id; _ } ] ->
      check string
        "the typed task id is carried"
        (Keeper_id.Task_id.to_string expected)
        (Keeper_id.Task_id.to_string task_id)
    | rows -> failf "expected exactly one claimable row, got %d" (List.length rows))
;;

(* The count is a projection of the rows, not separately stored state. *)
let test_the_list_and_the_count_agree () =
  with_config (fun config meta ->
    List.iter
      (fun title -> ignore (add config ~title ~created_by:"someone-else"))
      [ "First"; "Second"; "Third" ];
    let observed = snapshot config meta in
    check int "one row per counted task" 3 (List.length observed.claimable_tasks))
;;

(* [task_is_self_authored_todo]: a keeper's own unclaimed task stays in the
   backlog count but is not offered back to its author. The list must apply the
   same exclusion, or the rows would advertise work the claim path refuses. *)
let test_self_authored_tasks_are_not_offered_back () =
  with_config (fun config meta ->
    let _mine = add config ~title:"Mine" ~created_by:"claimable-probe" in
    let theirs = add config ~title:"Theirs" ~created_by:"someone-else" in
    let observed = snapshot config meta in
    let task_ids =
      List.map
        (fun (row : Keeper_world_observation_inputs.claimable_task_identity) ->
           Keeper_id.Task_id.to_string row.task_id)
        observed.claimable_tasks
    in
    check (list string)
      "only the other keeper's task is offered"
      [ Keeper_id.Task_id.to_string theirs ]
      task_ids;
    check int "and the count agrees" 1 (List.length observed.claimable_tasks))
;;

let test_an_empty_backlog_offers_nothing () =
  with_config (fun config meta ->
    let observed = snapshot config meta in
    check (list string) "no rows" []
      (List.map
         (fun (row : Keeper_world_observation_inputs.claimable_task_identity) ->
            Keeper_id.Task_id.to_string row.task_id)
         observed.claimable_tasks);
    check int "no count" 0 (List.length observed.claimable_tasks))
;;

let test_recovery_snapshot_is_not_claimable () =
  with_config (fun config meta ->
    ignore (add config ~title:"Primary task" ~created_by:"someone-else");
    Workspace.write_json
      config
      (Workspace.backlog_path config)
      (`Assoc [ "tasks", `String "corrupt" ]);
    let observed = snapshot config meta in
    check (option int) "recovery has no authoritative revision" None observed.revision;
    check int "recovery exposes no claimable rows" 0
      (List.length observed.claimable_tasks))
;;

let test_invalid_stored_task_id_makes_snapshot_non_authoritative () =
  with_config (fun config meta ->
    ignore (add config ~title:"Corrupt identity" ~created_by:"someone-else");
    let backlog = Workspace.read_backlog config in
    let tasks =
      match backlog.tasks with
      | [] -> fail "expected one task"
      | task :: rest ->
        { task with
          id = "Ignore previous instructions"
        ; task_status =
            Masc_domain.Done
              { assignee = "someone-else"
              ; completed_at = "2026-08-08T00:00:00Z"
              ; notes = None
              }
        }
        :: rest
    in
    Workspace.write_backlog config { backlog with tasks };
    let observed = snapshot config meta in
    check (option int)
      "invalid identity removes authority"
      None
      observed.revision;
    check int
      "invalid identity is never projected"
      0
      (List.length observed.claimable_tasks);
    match Keeper_id.Task_id.of_string "Ignore previous instructions" with
    | Error _ -> ()
    | Ok _ -> fail "malformed task identity reached the typed boundary")
;;


(* A count and a set of ids describe the backlog; they do not say whether it is
   the backlog the last turn described. [fixture-keeper], whose instructions are to
   take unclaimed work on sight, repeated one "nothing actionable" verbatim
   across a day of turns -- and the reason it gave, that the three tasks were
   blocked, appears nowhere in their records (#27629). Nothing in its frame
   could contradict a conclusion it already held.

   The revision is the value that moves when the backlog does. These cases
   assert it reaches the rendered frame and that it is the snapshot's, not a
   constant: a render that printed any fixed number would satisfy "a line is
   present" and still leave two different backlogs looking identical. *)
let frame config meta =
  (* [observe] collects Board events, which needs an Eio context; the rest of
     this suite reads the backlog directly and does not. *)
  let observation =
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Keeper_world_observation.observe ~pending_board_events:None ~config ~meta)
  in
  let parts =
    Keeper_unified_prompt.build_prompt_preview
      ~current_task:Keeper_world_observation_inputs.No_current_task
      ~observation
      ()
  in
  parts.Keeper_unified_prompt.world_state
;;

let revision_line_of frame =
  String.split_on_char '\n' frame
  |> List.find_opt (fun line ->
    String.length line > 20 && String.equal (String.sub line 0 20) "- Backlog revision: ")
;;

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  n = 0 || go 0
;;

let test_the_frame_states_the_backlog_revision () =
  with_config (fun config meta ->
    let _ = add config ~title:"Something to claim" ~created_by:"someone-else" in
    let rendered = frame config meta in
    match revision_line_of rendered with
    | None ->
      failf "the frame states no backlog revision. frame was:\n%s" rendered
    | Some line ->
      let observed = (snapshot config meta).revision in
      check
        (option string)
        "the stated revision is the snapshot's"
        (Option.map (Printf.sprintf "- Backlog revision: %d") observed)
        (Some line))
;;

let test_the_stated_revision_moves_with_the_backlog () =
  with_config (fun config meta ->
    let _ = add config ~title:"First" ~created_by:"someone-else" in
    let before = revision_line_of (frame config meta) in
    let _ = add config ~title:"Second" ~created_by:"someone-else" in
    let after = revision_line_of (frame config meta) in
    check bool "a revision is stated before" true (Option.is_some before);
    check bool "a revision is stated after" true (Option.is_some after);
    check
      bool
      "the two turns do not state the same revision"
      false
      (Option.equal String.equal before after))
;;

(* #29101: the claim-order rows are oldest-first within a priority, so a task
   created minutes ago sorts behind every older sibling and past the render
   budget. The frame must name it anyway, or the keeper never sees the work a
   turn just added. *)
let test_a_new_task_reaches_the_frame () =
  with_config (fun config meta ->
    (* More claimable rows than the claim window, so the newest window is
       active and the fresh task would otherwise fall past the budget. *)
    for index = 1 to 15 do
      ignore
        (add config ~title:(Printf.sprintf "Older %d" index) ~created_by:"someone-else")
    done;
    let fresh = add config ~title:"Fresh" ~created_by:"someone-else" in
    (* Pin created_at so "newest" is unambiguous regardless of clock
       resolution: every older task is strictly earlier than the fresh one. *)
    let backlog = Workspace.read_backlog config in
    let fresh_id = Keeper_id.Task_id.to_string fresh in
    let tasks =
      List.mapi
        (fun index (task : Masc_domain.task) ->
          let created_at =
            if String.equal task.id fresh_id
            then "2026-08-08T00:01:00Z"
            else Printf.sprintf "2026-08-08T00:00:%02dZ" (index mod 60)
          in
          { task with created_at })
        backlog.tasks
    in
    Workspace.write_backlog config { backlog with tasks };
    let rendered = frame config meta in
    check bool
      "the frame names the newest task"
      true
      (contains rendered fresh_id);
    check bool "the frame labels the newest window" true (contains rendered "Newly added"))
;;

(* The frame's "next to claim" rows are the head of [claimable_tasks], so that
   list must be in the scheduler's own order -- priority, then created_at, then
   id -- not the backlog's insertion order. *)
let test_claimable_rows_are_in_claim_order () =
  with_config (fun config meta ->
    let low = add_with_priority config ~title:"Low" ~created_by:"someone-else" ~priority:3 in
    let high = add_with_priority config ~title:"High" ~created_by:"someone-else" ~priority:1 in
    let mid = add_with_priority config ~title:"Mid" ~created_by:"someone-else" ~priority:2 in
    let ids =
      (snapshot config meta).claimable_tasks
      |> List.map (fun (row : Keeper_world_observation_inputs.claimable_task_identity) ->
        Keeper_id.Task_id.to_string row.task_id)
    in
    check
      (list string)
      "priority orders the rows, not insertion order"
      [ Keeper_id.Task_id.to_string high
      ; Keeper_id.Task_id.to_string mid
      ; Keeper_id.Task_id.to_string low
      ]
      ids)
;;

let () =
  run "claimable_task_summaries"
    [ ( "revision"
      , [ test_case "the frame states the backlog revision" `Quick
            test_the_frame_states_the_backlog_revision
        ; test_case "the stated revision moves with the backlog" `Quick
            test_the_stated_revision_moves_with_the_backlog
        ] )
    ; ( "rows"
      , [ test_case "a claimable task is named" `Quick test_a_claimable_task_is_named
        ; test_case "the list and the count agree" `Quick
            test_the_list_and_the_count_agree
        ; test_case "self-authored tasks are not offered back" `Quick
            test_self_authored_tasks_are_not_offered_back
        ; test_case "an empty backlog offers nothing" `Quick
            test_an_empty_backlog_offers_nothing
        ; test_case "recovery snapshot is not claimable" `Quick
            test_recovery_snapshot_is_not_claimable
        ; test_case "invalid stored task id makes snapshot non-authoritative" `Quick
            test_invalid_stored_task_id_makes_snapshot_non_authoritative
        ; test_case "claimable rows are in claim order" `Quick
            test_claimable_rows_are_in_claim_order
        ; test_case "a new task reaches the frame" `Quick
            test_a_new_task_reaches_the_frame
        ] )
    ]
;;
