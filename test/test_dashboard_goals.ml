open Alcotest
open Masc_mcp
open Tool_coord
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

let coord_ctx config : Tool_coord.context =
  { Tool_coord.config; agent_name = "planner" }

let parse_json_result (result : Tool_coord.tool_result) =
  match result with
  | { success = true; message = body } -> Yojson.Safe.from_string body
  | { success = false; message = body } -> fail body

let principal_json ~kind ~id =
  `Assoc [ ("kind", `String kind); ("id", `String id) ]

let create_done_task config ~goal_id ~title =
  ignore
    (Coord_task.add_task ~goal_id config ~title ~priority:3
       ~description:"done task fixture");
  let task_id =
    Coord.get_tasks_raw config
    |> List.find_map (fun (task : Types.task) ->
           if String.equal task.title title then Some task.id else None)
    |> function
    | Some task_id -> task_id
    | None -> fail ("task not found: " ^ title)
  in
  let step action notes =
    match
      Coord.transition_task_r config ~agent_name:"planner" ~task_id ~action
        ~notes ()
    with
    | Ok _ -> ()
    | Error err -> fail (Types.masc_error_to_string err)
  in
  step Types.Claim "test fixture claim";
  step Types.Start "test fixture start";
  step Types.Done_action "test fixture done"

let string_list_field json field =
  json |> member field |> to_list |> List.map to_string

let rewrite_goal_updated_at config ~goal_id ~updated_at =
  let state = Goal_store.read_state config in
  let goals =
    state.goals
    |> List.map (fun (goal : Goal_store.goal) ->
           if String.equal goal.id goal_id then
             { goal with created_at = updated_at; updated_at }
           else
             goal)
  in
  Goal_store.write_state config { state with updated_at; goals }

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

let append_keeper_receipt ?(outcome = "ok")
    ?(terminal_reason_code = "completed")
    ?(requested_tools = [ "keeper_fs_read" ])
    ?(reported_tools = [ "Read" ])
    ?(observed_tools = [ "keeper_fs_read" ])
    ?(canonical_tools = [ "keeper_fs_read" ])
    ?(tools_used = [ "keeper_fs_read" ])
    ?(tool_contract_result = "satisfied")
    ?(tool_requirement = "required")
    ?(cascade_outcome = "completed") (config : Coord.config)
    (meta : Keeper_types.keeper_meta) =
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
      outcome;
      terminal_reason_code;
      response_text_present = true;
      model_used = Some "openai:gpt-5.4";
      requested_tools;
      reported_tools;
      observed_tools;
      canonical_tools;
      unexpected_tools = [];
      tools_used;
      tool_contract_result;
      tool_surface =
        {
          turn_lane = "tool";
          tool_surface_class = "mixed";
          tool_requirement;
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
      cascade_name = Keeper_cascade_profile.Runtime_name meta.cascade_name;
      cascade_selected_model = Some "openai:gpt-5.4";
      cascade_attempt_count = 1;
      cascade_fallback_applied = false;
      cascade_outcome;
      degraded_retry_applied = false;
      degraded_retry_cascade = None;
      fallback_reason = None;
      cascade_rotation_attempts = [];
      stop_reason = Some terminal_reason_code;
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

let test_goal_tree_surfaces_resolved_verification_evidence () =
  with_room @@ fun config ->
  let verifier_policy =
    {
      Goal_verification.inherit_mode = Goal_verification.Extend;
      principals =
        [
          {
            kind = Goal_verification.Keeper;
            id = "keeper-alpha";
            display_name = Some "keeper-alpha";
          };
        ];
      required_verdicts = Some 1;
    }
  in
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Resolved verification evidence"
        ~verifier_policy ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Resolved done task";
  let transitioned =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_transition"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("action", `String "request_complete");
            ("actor", principal_json ~kind:"operator" ~id:"planner");
          ])
  in
  let request_id =
    match transitioned with
    | Some result ->
        parse_json_result result
        |> member "verification_request"
        |> fun json -> json |> member "id" |> to_string
    | None -> fail "masc_goal_transition not handled"
  in
  let verified =
    Tool_coord.dispatch (coord_ctx config) ~name:"masc_goal_verify"
      ~args:
        (`Assoc
          [
            ("goal_id", `String goal.id);
            ("request_id", `String request_id);
            ("principal", principal_json ~kind:"keeper" ~id:"keeper-alpha");
            ("decision", `String "approve");
            ("note", `String "checked receipt and tests");
            ( "evidence_refs",
              `List
                [
                  `String "receipt:keeper-alpha:turn-7";
                  `String "test:test_dashboard_goals";
                ] );
          ])
  in
  (match verified with
  | Some result -> ignore (parse_json_result result)
  | None -> fail "masc_goal_verify not handled");
  let node = Dashboard_goals.dashboard_goals_tree_json ~config |> root_node in
  let summary = node |> member "verification_summary" in
  check bool "open request cleared in dashboard tree" true
    (summary |> member "open_request" = `Null);
  let latest_request = summary |> member "latest_request" in
  check string "latest request id retained in dashboard tree" request_id
    (latest_request |> member "id" |> to_string);
  check string "latest request approved in dashboard tree" "approved"
    (latest_request |> member "status" |> to_string);
  let vote =
    match latest_request |> member "votes" |> to_list with
    | vote :: _ -> vote
    | [] -> fail "expected dashboard verification vote"
  in
  check string "vote note surfaced in dashboard tree" "checked receipt and tests"
    (vote |> member "note" |> to_string);
  check (list string) "vote evidence surfaced in dashboard tree"
    [ "receipt:keeper-alpha:turn-7"; "test:test_dashboard_goals" ]
    (string_list_field vote "evidence_refs");
  match Dashboard_goals.goal_detail_json ~config ~goal_id:goal.id with
  | Error msg -> fail msg
  | Ok detail_json ->
      let detail_latest =
        detail_json
        |> member "goal"
        |> member "verification_summary"
        |> member "latest_request"
      in
      check string "latest request retained in goal detail" request_id
        (detail_latest |> member "id" |> to_string)

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
  let fsm = node |> member "goal_fsm" in
  check string "goal fsm source is explicit phase" "goal.phase"
    (fsm |> member "source" |> to_string);
  check string "goal fsm state follows phase" "blocked"
    (fsm |> member "state" |> to_string);
  check string "goal fsm kind is blocked" "blocked"
    (fsm |> member "state_kind" |> to_string);
  check (list string) "blocked goal next actions"
    [ "operator_unblock"; "drop" ]
    (string_list_field fsm "next_actions");
  check int "blocked summary count" 1
    (json |> member "summary" |> member "blocked_goals" |> to_int);
  check int "paused summary count" 0
    (json |> member "summary" |> member "paused_goals" |> to_int)

let test_goal_fsm_withholds_stalled_when_activity_is_metadata_only () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Metadata-only active goal" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  rewrite_goal_updated_at config ~goal_id:goal.id
    ~updated_at:"2026-04-01T00:00:00Z";
  let meta = make_keeper_meta ~name:"metadata-only-keeper" ~goal_id:goal.id in
  (match Keeper_types.write_meta ~force:true config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  let node = Dashboard_goals.dashboard_goals_tree_json ~config |> root_node in
  check string "phase remains the lifecycle source" "executing"
    (node |> member "phase" |> to_string);
  check string "metadata-only freshness does not create a blocker"
    "none"
    (node |> member "blocking_source" |> to_string);
  check string "health stays on track without observed runtime failure" "on_track"
    (node |> member "health" |> to_string);
  check bool "stalled badge withheld" false
    (List.mem "stalled" (string_list_field node "badges"));
  check bool "unobserved badge explains weak freshness" true
    (List.mem "activity_unobserved" (string_list_field node "badges"));
  check string "activity observation is metadata only" "goal_metadata"
    (node |> member "activity_observation" |> to_string);
  check string "stagnation status is unobserved" "unobserved"
    (node |> member "stagnation_status" |> to_string);
  let fsm = node |> member "goal_fsm" in
  check string "goal fsm source is explicit phase" "goal.phase"
    (fsm |> member "source" |> to_string);
  check string "goal fsm state remains executing" "executing"
    (fsm |> member "state" |> to_string);
  check string "goal fsm carries observation confidence" "goal_metadata"
    (fsm |> member "activity_observation" |> to_string);
  check string "goal fsm carries unobserved freshness" "unobserved"
    (fsm |> member "stagnation_status" |> to_string);
  check bool "operator can still pause executing goal" true
    (List.mem "pause" (string_list_field fsm "next_actions"))

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

let test_goal_detail_uses_receipt_disposition_for_required_tool_failure () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Surface required tool failure" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let meta = make_keeper_meta ~name:"tool-failure-keeper" ~goal_id:goal.id in
  (match Keeper_types.write_meta ~force:true config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  append_keeper_receipt ~reported_tools:[] ~observed_tools:[] ~canonical_tools:[]
    ~tools_used:[] ~tool_contract_result:"missing_required_tool_use" config meta;
  match Dashboard_goals.goal_detail_json ~config ~goal_id:goal.id with
  | Error msg -> fail msg
  | Ok json ->
      let linked_keeper =
        match json |> member "linked_keepers" |> to_list with
        | keeper :: _ -> keeper
        | [] -> fail "expected linked keeper detail"
      in
      let runtime_trust = linked_keeper |> member "runtime_trust" in
      check string "receipt-derived disposition pauses" "Pause"
        (runtime_trust |> member "disposition" |> to_string);
      check string "receipt-derived reason surfaced"
        "tool_required_unsatisfied"
        (runtime_trust |> member "disposition_reason" |> to_string);
      check string "operator disposition preserved" "pause_human"
        (runtime_trust |> member "operator_disposition" |> to_string);
      check string "operator reason preserved" "tool_required_unsatisfied"
        (runtime_trust |> member "operator_disposition_reason" |> to_string);
      check bool "receipt-derived failure needs attention" true
        (runtime_trust |> member "needs_attention" |> to_bool)

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
          test_case "resolved goal verification evidence is surfaced" `Quick
            test_goal_tree_surfaces_resolved_verification_evidence;
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
          test_case
            "metadata-only freshness does not assert stalled FSM state"
            `Quick
            test_goal_fsm_withholds_stalled_when_activity_is_metadata_only;
          test_case "goal detail surfaces keeper runtime trust and blockers"
            `Quick
            test_goal_detail_surfaces_keeper_runtime_trust_and_blockers;
          test_case "goal detail pauses on required tool receipt failure"
            `Quick
            test_goal_detail_uses_receipt_disposition_for_required_tool_failure;
          test_case "goal tree tolerates null decision telemetry" `Quick
            test_goal_tree_tolerates_null_decision_telemetry;
          test_case
            "goal detail keeps synthetic runtime blocker out of latest causal"
            `Quick
            test_goal_detail_does_not_promote_synthetic_blocker_over_receipt;
        ] );
    ]
