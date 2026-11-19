(** The goals tree reads a Keeper's runtime trust only when a
    goal's task is assigned to that Keeper, and once per build. Reading every
    Keeper's snapshot first was what made the tree slow: on 2026-10-28 the 40
    snapshots took 7.3 s of a 7.5 s tree, and the 19 Keepers any goal named
    took 2.0 s of them. *)

open Alcotest
open Masc

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

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)
;;

let write_file path content =
  Out_channel.with_open_bin path (fun output -> output_string output content)
;;

let write_keeper config name =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    "[keeper]\ninstructions = \"test keeper\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n";
  let meta_path = Keeper_types_profile.keeper_meta_path config name in
  mkdir_p (Filename.dirname meta_path);
  write_file meta_path
    (Yojson.Safe.to_string (Masc_test_deps.current_meta_json_fixture ~name ()))
;;

let get_ok to_string = function
  | Ok value -> value
  | Error error -> fail (to_string error)
;;

let assign config ~task_id ~assignee =
  let backlog = get_ok Fun.id (Workspace_backlog.read_backlog_r config) in
  let claimed_at = Masc_domain.now_iso () in
  Workspace_backlog.write_backlog config
    { backlog with
      tasks =
        List.map
          (fun (task : Masc_domain.task) ->
             if String.equal task.id task_id
             then
               { task with
                 task_status = Masc_domain.Claimed { assignee; claimed_at }
               }
             else task)
          backlog.tasks
    }
;;

let test_reads_trust_once_for_assigned_keepers_only () =
  let base_path = Filename.temp_dir "dashboard-goals-trust-reads" "" in
  Fun.protect ~finally:(fun () -> rm_rf base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:None);
  List.iter (write_keeper config) [ "alpha"; "beta" ];
  let goal title =
    get_ok Goal_store.write_error_to_string
      (Goal_store.upsert_goal_with_events ~actor:"test" config ~title ~measure:(Goal_measure_fixture.done_when "1") ~procedure:"tasks" ())
    |> (fun (goal, _, _) -> goal)
  in
  let assigned_task (goal : Goal_store.goal) title =
    let created =
      get_ok Workspace.add_task_error_to_string
        (Workspace.add_task_with_result ~goal_id:goal.id config ~title
           ~priority:3 ~description:"evidence")
    in
    assign config ~task_id:created.task_id ~assignee:"alpha"
  in
  (* Both goals' tasks belong to alpha; beta is a Keeper no goal names. *)
  assigned_task (goal "First") "First task";
  assigned_task (goal "Second") "Second task";
  let asked = ref [] in
  let read_trust ~config:_ ~(meta : Keeper_meta_contract.keeper_meta) =
    asked := meta.name :: !asked;
    `Assoc
      [ "turn_id", `Int 7
      ; ( "latest_causal_event"
        , `Assoc
            [ "ts", `String "2026-10-28T08:00:00Z"; "ts_unix", `Float 1793174400. ] )
      ]
  in
  let goals =
    get_ok Goal_store.unavailable_to_string (Goal_store.list_goals_result config ())
  in
  let forest =
    get_ok Fun.id
      (Dashboard_goals.build_forest_with_trust_reader ~read_trust ~config ~goals
         ~tasks:(Workspace.get_tasks_safe config) ~pending_approvals:[])
  in
  check int "both goals are projected" 2 (List.length forest);
  check (list string) "trust is read once, for the assigned Keeper only"
    [ "alpha" ] !asked;
  List.iter
    (fun (node : Dashboard_goals.tree_node) ->
       check (list string) "the goal names its assigned Keeper" [ "alpha" ]
         node.linked_keeper_names;
       check (option string) "the trust read names the latest Keeper" (Some "alpha")
         node.latest_keeper_ref;
       check (option int) "the trust read names the latest turn" (Some 7)
         node.latest_turn_ref;
       let node = { node with goal = { node.goal with last_review_note = Some "needs evidence" } } in
       let json = Dashboard_goals.tree_node_to_json node in
       check string "tree carries the selected Goal's review note" "needs evidence"
         Yojson.Safe.Util.(json |> member "last_review_note" |> to_string))
    forest
;;

let with_goal_events f =
  let base_path = Filename.temp_dir "dashboard-goals-event-reads" "" in
  Fun.protect ~finally:(fun () -> rm_rf base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:None);
  let goal, _, _ =
    get_ok Goal_store.write_error_to_string
      (Goal_store.upsert_goal_with_events ~actor:"test" config
         ~title:"Listed" ~measure:(Goal_measure_fixture.done_when "1") ~procedure:"tasks" ())
  in
  f config goal
;;

let phase_row ~goal_id ~ts phase =
  `Assoc
    [ "goal_id", `String goal_id; "ts", `String ts
    ; "event_type", `String "goal_phase"
    ; "payload", `Assoc ["phase", `String phase; "actor", `String "test"]
    ]
;;

let write_events config rows =
  write_file (Goal_store.goal_events_path config)
    (String.concat "\n" (List.map Yojson.Safe.to_string rows) ^ "\n")
;;

let listed_timeline json =
  let open Yojson.Safe.Util in
  json |> member "tree" |> to_list |> List.hd |> member "timeline_events" |> to_list
;;

let unlisted_history json =
  let open Yojson.Safe.Util in
  json |> member "goal_history" |> member "unlisted" |> to_list
;;

let capture_stderr path f =
  Out_channel.with_open_bin path @@ fun output ->
  flush stderr;
  let previous = Unix.dup Unix.stderr in
  Fun.protect
    ~finally:(fun () ->
      flush stderr;
      Unix.dup2 previous Unix.stderr;
      Unix.close previous)
    (fun () -> Unix.dup2 (Unix.descr_of_out_channel output) Unix.stderr; f ())
;;

let test_event_capture_preserves_rows_and_diagnostics () =
  with_goal_events @@ fun config goal ->
  let open Yojson.Safe.Util in
  let later = "2026-11-17T03:00:00Z" in
  let earlier = "2026-11-17T02:00:00Z" in
  let rows =
    [ phase_row ~goal_id:goal.id ~ts:later "executing"
    ; phase_row ~goal_id:"goal-z" ~ts:later "completed"
    ; phase_row ~goal_id:goal.id ~ts:earlier "verifying"
    ; phase_row ~goal_id:"goal-a" ~ts:earlier "dropped"
    ; `Assoc ["event_type", `String "goal_phase"]
    ]
  in
  let path = Goal_store.goal_events_path config in
  write_events config rows;
  Out_channel.with_open_gen [Open_wronly; Open_append; Open_binary] 0o600 path
    (fun output -> output_string output "\n{invalid json\n");
  let diagnostics = Filename.concat config.base_path "diagnostics.log" in
  let json = capture_stderr diagnostics (fun () ->
    Dashboard_goals.dashboard_goals_tree_json ~config) in
  check (list string) "listed events keep their recorded order" [later; earlier]
    (listed_timeline json |> List.map (fun row -> row |> member "ts" |> to_string));
  check (list string) "history excludes listed goals and orders ids"
    ["goal-a"; "goal-z"]
    (unlisted_history json |> List.map (fun row -> row |> member "goal_id" |> to_string));
  let coverage = json |> member "goal_history" |> member "coverage" in
  check int "malformed rows are counted" 1
    (coverage |> member "malformed_event_lines" |> to_int);
  check int "rows without goal identity remain diagnosed" 1
    (coverage |> member "rows_without_goal_id" |> to_int);
  let warnings =
    In_channel.with_open_bin diagnostics In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter (String.starts_with ~prefix:("[fs_compat] malformed JSONL (" ^ path ^ ")"))
  in
  check int "one malformed row is diagnosed once per tree read" 1 (List.length warnings)
;;

let test_event_capture_is_fresh_and_preserves_read_failures () =
  with_goal_events @@ fun config goal ->
  let open Yojson.Safe.Util in
  let project phase history_id =
    write_events config
      [ phase_row ~goal_id:goal.id ~ts:"2026-11-17T02:00:00Z" phase
      ; phase_row ~goal_id:history_id ~ts:"2026-11-17T03:00:00Z" "completed"
      ];
    let json = Dashboard_goals.dashboard_goals_tree_json ~config in
    check (list string) "listed timeline reads current bytes"
      ["phase=" ^ phase ^ " by test"]
      (listed_timeline json |> List.map (fun row -> row |> member "summary" |> to_string));
    check (list string) "unlisted history reads current bytes" [history_id]
      (unlisted_history json |> List.map (fun row -> row |> member "goal_id" |> to_string));
    let standalone = Dashboard_goals.unlisted_goal_history_json ~config ~goals:[goal] in
    check bool "standalone history preserves the same projection" true
      (Yojson.Safe.equal standalone (json |> member "goal_history"));
    let detail = get_ok Fun.id (Dashboard_goals.goal_detail_json ~config ~goal_id:goal.id) in
    check bool "detail keeps the same listed events" true
      (Yojson.Safe.equal (detail |> member "goal" |> member "timeline_events")
         (`List (listed_timeline json)))
  in
  project "executing" "goal-before";
  project "verifying" "goal-after";
  let path = Goal_store.goal_events_path config in
  Sys.remove path;
  let missing = Dashboard_goals.dashboard_goals_tree_json ~config in
  check int "missing log has no listed events" 0 (List.length (listed_timeline missing));
  check int "missing log has no unlisted events" 0 (List.length (unlisted_history missing));
  check int "missing log has no malformed lines" 0
    (missing |> member "goal_history" |> member "coverage" |> member "malformed_event_lines" |> to_int);
  Unix.mkdir path 0o700;
  (* Directory reads can fail while converting the descriptor on Linux or
     while reading it on other platforms. Preserve the reader's own error. *)
  let read_failure =
    match Fs_compat.load_jsonl_diagnostics path with
    | exception ((Sys_error _ | Unix.Unix_error _) as error) -> error
    | _ -> fail "the unreadable log fixture must fail in the underlying reader"
  in
  check_raises "the tree preserves the underlying event-reader failure" read_failure
    (fun () -> ignore (Dashboard_goals.dashboard_goals_tree_json ~config))
;;

let () =
  run "dashboard_goals_trust_reads"
    [ ( "build_forest"
      , [ test_case "reads trust once, for assigned Keepers only" `Quick
            test_reads_trust_once_for_assigned_keepers_only
        ] )
    ; ( "event_reads"
      , [ test_case "preserves rows and diagnoses each malformed row once" `Quick
            test_event_capture_preserves_rows_and_diagnostics
        ; test_case "rereads current events and preserves missing/error semantics" `Quick
            test_event_capture_is_fresh_and_preserves_read_failures
        ] )
    ]
;;
