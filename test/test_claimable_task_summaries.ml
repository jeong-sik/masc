(* The turn frame said "Claimable tasks for this keeper: N" and nothing else.
   A count says work exists and not which work, so a keeper that wants to claim
   has to decide to spend a tool call before it can even see a title.

   Measured over the ten hours after one server start: 2000 turns across seven
   keepers, 320 of them calling any tool at all. [lane-smith] ran 284 turns and
   [taskmaster] 286 with zero tool calls, and taskmaster's turns reason each
   time from a twelve-hour-old memory about which tasks were open -- while the
   frame in front of it said only "3".

   [read_backlog_snapshot] keeps the rows and revision from one authoritative
   read. The count is derived from those rows, so a second read cannot silently
   make the heading disagree with the rendered tasks. *)

open Alcotest
open Masc

let () = Workspace_metric_hooks.install ()

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
         ; "active_goal_ids", `List []
         ])
  with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)
;;

let add config ~title ~created_by =
  ignore (Workspace.add_task ~created_by config ~title ~priority:2 ~description:"")
;;

let snapshot config meta =
  Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta
;;

let with_config f =
  let config = make_config () in
  Fun.protect ~finally:(fun () -> cleanup config) (fun () -> f config (make_meta ()))
;;

(* The point of the change: a title reaches the keeper, not only a number. *)
let test_a_claimable_task_is_named () =
  with_config (fun config meta ->
    add config ~title:"Wire the timeline panel" ~created_by:"someone-else";
    match (snapshot config meta).claimable_tasks with
    | [ { title_preview; _ } ] ->
      check string "the title is carried" "Wire the timeline panel" title_preview
    | rows -> failf "expected exactly one claimable row, got %d" (List.length rows))
;;

(* The count is a projection of the rows, not separately stored state. *)
let test_the_list_and_the_count_agree () =
  with_config (fun config meta ->
    List.iter
      (fun title -> add config ~title ~created_by:"someone-else")
      [ "First"; "Second"; "Third" ];
    let observed = snapshot config meta in
    check int "one row per counted task" 3 (List.length observed.claimable_tasks))
;;

(* [task_is_self_authored_todo]: a keeper's own unclaimed task stays in the
   backlog count but is not offered back to its author. The list must apply the
   same exclusion, or the rows would advertise work the claim path refuses. *)
let test_self_authored_tasks_are_not_offered_back () =
  with_config (fun config meta ->
    add config ~title:"Mine" ~created_by:"claimable-probe";
    add config ~title:"Theirs" ~created_by:"someone-else";
    let observed = snapshot config meta in
    let titles = List.map (fun row -> row.title_preview) observed.claimable_tasks in
    check (list string) "only the other keeper's task is offered" [ "Theirs" ] titles;
    check int "and the count agrees" 1 (List.length observed.claimable_tasks))
;;

let test_an_empty_backlog_offers_nothing () =
  with_config (fun config meta ->
    let observed = snapshot config meta in
    check (list string) "no rows" []
      (List.map (fun row -> row.task_id) observed.claimable_tasks);
    check int "no count" 0 (List.length observed.claimable_tasks))
;;

let test_title_preview_is_one_line_utf8_and_byte_bounded () =
  with_config (fun config meta ->
    let oversized = String.concat "" (List.init 100 (fun _ -> "가")) ^ "\nsecond line" in
    add config ~title:oversized ~created_by:"someone-else";
    match (snapshot config meta).claimable_tasks with
    | [ { title_preview; _ } ] ->
      check bool "at most 160 bytes" true (String.length title_preview <= 160);
      check bool "valid UTF-8" true (String.is_valid_utf_8 title_preview);
      check bool "single line" false (String.contains title_preview '\n')
    | rows -> failf "expected one bounded row, got %d" (List.length rows))
;;

let test_recovery_snapshot_is_not_claimable () =
  with_config (fun config meta ->
    add config ~title:"Primary task" ~created_by:"someone-else";
    Out_channel.with_open_text (Workspace.backlog_path config) (fun channel ->
      output_string channel {|{"tasks":"corrupt"}|});
    let observed = snapshot config meta in
    check (option int) "recovery has no authoritative revision" None observed.revision;
    check int "recovery exposes no claimable rows" 0
      (List.length observed.claimable_tasks))
;;

let () =
  run "claimable_task_summaries"
    [ ( "rows"
      , [ test_case "a claimable task is named" `Quick test_a_claimable_task_is_named
        ; test_case "the list and the count agree" `Quick
            test_the_list_and_the_count_agree
        ; test_case "self-authored tasks are not offered back" `Quick
            test_self_authored_tasks_are_not_offered_back
        ; test_case "an empty backlog offers nothing" `Quick
            test_an_empty_backlog_offers_nothing
        ; test_case "title preview is bounded and valid" `Quick
            test_title_preview_is_one_line_utf8_and_byte_bounded
        ; test_case "recovery snapshot is not claimable" `Quick
            test_recovery_snapshot_is_not_claimable
        ] )
    ]
;;
