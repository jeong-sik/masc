open Alcotest
open Masc_mcp
open Yojson.Safe.Util

let temp_dir () =
  let path = Filename.temp_file "dashboard_goals_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm dir with _ -> ()

let with_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
      let config = Coord.default_config dir in
      ignore (Coord.init config ~agent_name:(Some "planner"));
      f config)

let make_keeper_meta ~name ~goal_id =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String (name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("goal", `String "Goal-linked keeper");
          ("cascade_name", `String Keeper_config.default_cascade_name);
        ])
  with
  | Ok meta -> { meta with active_goal_ids = [ goal_id ] }
  | Error err -> fail ("meta_of_json failed: " ^ err)

let append_keeper_receipt (config : Coord.config) (meta : Keeper_types.keeper_meta) =
  let started_at = Types.now_iso () in
  let ended_at = Types.now_iso () in
  let receipt : Keeper_execution_receipt.t =
    {
      keeper_name = meta.name;
      agent_name = meta.agent_name;
      trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id;
      generation = meta.runtime.generation;
      turn_count = Some 7;
      current_task_id = None;
      goal_ids = meta.active_goal_ids;
      outcome = "ok";
      terminal_reason_code = "completed";
      response_text_present = true;
      model_used = Some "openai:gpt-5.4";
      requested_tools = [ "keeper_fs_read" ];
      reported_tools = [ "Read" ];
      observed_tools = [ "keeper_fs_read" ];
      canonical_tools = [ "keeper_fs_read" ];
      unexpected_tools = [];
      tools_used = [ "keeper_fs_read" ];
      tool_contract_result = "satisfied";
      tool_surface =
        {
          turn_lane = "tool";
          tool_surface_class = "mixed";
          tool_requirement = "required";
          visible_tool_count = 1;
          tool_gate_enabled = true;
          tool_surface_fallback_used = false;
          required_tools = [];
          missing_required_tools = [];
        };
      sandbox_kind = Keeper_execution_receipt.sandbox_kind_of_meta meta;
      sandbox_root = Some config.base_path;
      network_mode = Keeper_types.network_mode_to_string meta.network_mode;
      approval_profile = Some "trusted_local";
      approval_profile_derived = false;
      cascade_name = meta.cascade_name;
      cascade_selected_model = Some "openai:gpt-5.4";
      cascade_attempt_count = 1;
      cascade_fallback_applied = false;
      cascade_outcome = "completed";
      degraded_retry_applied = false;
      degraded_retry_cascade = None;
      fallback_reason = None;
      cascade_rotation_attempts = [];
      stop_reason = Some "completed";
      error_kind = None;
      error_message = None;
      started_at;
      ended_at;
    }
  in
  Keeper_execution_receipt.append config receipt

let append_keeper_decision_with_null_telemetry
    (config : Coord.config) (meta : Keeper_types.keeper_meta) =
  Fs_compat.append_jsonl
    (Keeper_types.keeper_decision_log_path config meta.name)
    (`Assoc
      [
        ("turn_id", `Int 9);
        ("turn_verdict", `String "run");
        ("turn_reasons", `List [ `String "test_fixture" ]);
        ("wall_clock", `Float (Unix.gettimeofday ()));
        ("telemetry", `Null);
      ])

let root_node json =
  match json |> member "tree" |> to_list with
  | node :: _ -> node
  | [] -> fail "expected one goal in tree"

let test_empty_executing_goal_is_at_risk () =
  with_room @@ fun config ->
  let _goal, _kind =
    match Goal_store.upsert_goal config ~title:"Empty executing goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let json = Dashboard_goals.dashboard_goals_tree_json ~config in
  let node = root_node json in
  check string "empty goal health" "at_risk"
    (node |> member "health" |> to_string);
  check string "empty goal blocker" "goal_linkage"
    (node |> member "blocking_source" |> to_string);
  check int "linkage warning count" 1
    (node |> member "linkage_warning_count" |> to_int);
  check int "active summary counts status" 1
    (json |> member "summary" |> member "active_goals" |> to_int);
  check int "on_track summary separate" 0
    (json |> member "summary" |> member "on_track_goals" |> to_int)

let test_open_task_without_keeper_is_at_risk () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Unstaffed goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  ignore
    (Coord_task.add_task ~goal_id:goal.id config ~title:"Unstaffed task"
       ~priority:3 ~description:"needs a keeper");
  let node = Dashboard_goals.dashboard_goals_tree_json ~config |> root_node in
  check string "unstaffed health" "at_risk"
    (node |> member "health" |> to_string);
  check string "unstaffed blocker" "goal_linkage"
    (node |> member "blocking_source" |> to_string);
  check int "one linked task" 1 (node |> member "task_count" |> to_int);
  check int "linkage warning count" 1
    (node |> member "linkage_warning_count" |> to_int)

let test_cancelled_only_goal_is_at_risk () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Cancelled-only goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  ignore
    (Coord_task.add_task ~goal_id:goal.id config ~title:"Cancelled task"
       ~priority:3 ~description:"cancel me");
  let task_id =
    match Coord.get_tasks_raw config with
    | [ task ] -> task.id
    | tasks ->
        fail (Printf.sprintf "expected one task, got %d" (List.length tasks))
  in
  (match Coord.cancel_task_r config ~agent_name:"planner" ~task_id
           ~reason:"test cancellation" with
   | Ok _ -> ()
   | Error err -> fail (Types.masc_error_to_string err));
  let node = Dashboard_goals.dashboard_goals_tree_json ~config |> root_node in
  check string "cancelled-only health" "at_risk"
    (node |> member "health" |> to_string);
  check string "cancelled-only blocker" "goal_linkage"
    (node |> member "blocking_source" |> to_string);
  check int "linkage warning count" 1
    (node |> member "linkage_warning_count" |> to_int)

let test_title_marker_links_legacy_task () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Legacy marker goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  ignore
    (Coord_task.add_task config
       ~title:(Printf.sprintf "[goal:%s] Legacy task" goal.id)
       ~priority:3 ~description:"legacy title marker");
  let node = Dashboard_goals.dashboard_goals_tree_json ~config |> root_node in
  let task =
    match node |> member "tasks" |> to_list with
    | task :: _ -> task
    | [] -> fail "expected linked title-marker task"
  in
  check string "legacy linkage source" "title_tag"
    (task |> member "linkage_source" |> to_string);
  check string "node linkage source" "title_tag"
    (node |> member "linkage_source" |> to_string)

let test_blocked_phase_projects_blocked_health () =
  with_room @@ fun config ->
  let _goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Blocked goal"
        ~phase:Goal_phase.Blocked ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let json = Dashboard_goals.dashboard_goals_tree_json ~config in
  let node =
    match json |> member "tree" |> to_list with
    | node :: _ -> node
    | [] -> fail "expected one goal in tree"
  in
  check string "legacy status remains paused" "paused"
    (node |> member "status" |> to_string);
  check string "phase remains blocked" "blocked"
    (node |> member "phase" |> to_string);
  check string "health follows blocked phase" "blocked"
    (node |> member "health" |> to_string);
  check int "blocked summary count" 1
    (json |> member "summary" |> member "blocked_goals" |> to_int);
  check int "paused summary count" 0
    (json |> member "summary" |> member "paused_goals" |> to_int)

let test_goal_detail_surfaces_keeper_runtime_trust_and_blockers () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Ship trust timeline" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let meta = make_keeper_meta ~name:"goal-keeper" ~goal_id:goal.id in
  (match Keeper_types.write_meta ~force:true config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  append_keeper_receipt config meta;
  let tree_json = Dashboard_goals.dashboard_goals_tree_json ~config in
  let node =
    match tree_json |> member "tree" |> to_list with
    | node :: _ -> node
    | [] -> fail "expected one goal in tree"
  in
  check string "blocking source defaults to none" "none"
    (node |> member "blocking_source" |> to_string);
  check string "latest keeper ref surfaced" meta.name
    (node |> member "latest_keeper_ref" |> to_string);
  check int "latest turn ref surfaced" 7
    (node |> member "latest_turn_ref" |> to_int);
  match Dashboard_goals.goal_detail_json ~config ~goal_id:goal.id with
  | Error msg -> fail msg
  | Ok json ->
      let linked_keeper =
        match json |> member "linked_keepers" |> to_list with
        | keeper :: _ -> keeper
        | [] -> fail "expected linked keeper detail"
      in
      let runtime_trust = linked_keeper |> member "runtime_trust" in
      check string "disposition ok" "Pass"
        (runtime_trust |> member "disposition" |> to_string);
      check string "operator disposition ok" "pass"
        (runtime_trust |> member "operator_disposition" |> to_string);
      check string "approval idle" "idle"
        (runtime_trust |> member "approval" |> member "state" |> to_string);
      check string "execution receipt latest event" "execution_receipt"
        (runtime_trust |> member "latest_causal_event" |> member "kind" |> to_string);
      check bool "causal timeline populated" true
        (runtime_trust |> member "causal_timeline" |> to_list <> []);
      check string "detail latest causal event mirrors runtime trust"
        "execution_receipt"
        (linked_keeper |> member "latest_causal_event" |> member "kind" |> to_string)

let test_goal_tree_tolerates_null_decision_telemetry () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Show resilient goal tree" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let meta = make_keeper_meta ~name:"null-telemetry-keeper" ~goal_id:goal.id in
  (match Keeper_types.write_meta ~force:true config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  append_keeper_decision_with_null_telemetry config meta;
  let tree_json = Dashboard_goals.dashboard_goals_tree_json ~config in
  let node =
    match tree_json |> member "tree" |> to_list with
    | node :: _ -> node
    | [] -> fail "expected one goal in tree"
  in
  check string "linked keeper still surfaced" meta.name
    (node |> member "latest_keeper_ref" |> to_string);
  match Dashboard_goals.goal_detail_json ~config ~goal_id:goal.id with
  | Error msg -> fail msg
  | Ok json ->
      let linked_keeper =
        match json |> member "linked_keepers" |> to_list with
        | keeper :: _ -> keeper
        | [] -> fail "expected linked keeper detail"
      in
      check (option string) "null telemetry selected_model stays absent" None
        (linked_keeper |> member "runtime_trust" |> member "selected_model"
        |> to_string_option)

let test_goal_detail_does_not_promote_synthetic_blocker_over_receipt () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Ship blocker ordering" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let meta =
    let base = make_keeper_meta ~name:"blocker-keeper" ~goal_id:goal.id in
    {
      base with
      runtime =
        {
          base.runtime with
          last_blocker = "turn timed out";
          last_blocker_class = Some Keeper_types.Turn_timeout;
        };
    }
  in
  (match Keeper_types.write_meta ~force:true config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  append_keeper_receipt config meta;
  match Dashboard_goals.goal_detail_json ~config ~goal_id:goal.id with
  | Error msg -> fail msg
  | Ok json ->
      let linked_keeper =
        match json |> member "linked_keepers" |> to_list with
        | keeper :: _ -> keeper
        | [] -> fail "expected linked keeper detail"
      in
      let runtime_trust = linked_keeper |> member "runtime_trust" in
      check string "durable receipt remains latest causal event"
        "execution_receipt"
        (runtime_trust |> member "latest_causal_event" |> member "kind" |> to_string);
      let timeline = runtime_trust |> member "causal_timeline" |> to_list in
      let blocker =
        timeline
        |> List.find_opt (fun event ->
               String.equal "runtime_blocker"
                 (event |> member "kind" |> to_string))
      in
      match blocker with
      | None -> fail "expected runtime_blocker observation in timeline"
      | Some event ->
          check bool "runtime blocker marked observation-only" true
            (event |> member "observation_only" |> to_bool)

let () =
  run "Dashboard_goals"
    [
      ( "tree",
        [
          test_case "empty executing goal is at risk" `Quick
            test_empty_executing_goal_is_at_risk;
          test_case "open task without keeper is at risk" `Quick
            test_open_task_without_keeper_is_at_risk;
          test_case "cancelled-only goal is at risk" `Quick
            test_cancelled_only_goal_is_at_risk;
          test_case "title marker links legacy task" `Quick
            test_title_marker_links_legacy_task;
          test_case "blocked phase maps to blocked health" `Quick
            test_blocked_phase_projects_blocked_health;
          test_case "goal detail surfaces keeper runtime trust and blockers"
            `Quick
            test_goal_detail_surfaces_keeper_runtime_trust_and_blockers;
          test_case "goal tree tolerates null decision telemetry" `Quick
            test_goal_tree_tolerates_null_decision_telemetry;
          test_case
            "goal detail keeps synthetic runtime blocker out of latest causal"
            `Quick
            test_goal_detail_does_not_promote_synthetic_blocker_over_receipt;
        ] );
    ]
