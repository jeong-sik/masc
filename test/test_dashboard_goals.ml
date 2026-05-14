module Types = Masc_domain

open Alcotest
open Masc_mcp
open Coord_types
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

let parse_json_result (result : Tool_result.t) =
  (* RFC-0062 Phase 4d-2: Tool_coord.tool_result alias deleted.
     Callers now consume Tool_result.t directly. [legacy_message] preserves
     the prior string body for backward-compatible parsing. *)
  if result.success then Yojson.Safe.from_string result.legacy_message
  else fail result.legacy_message

let principal_json ~kind ~id =
  `Assoc [ ("kind", `String kind); ("id", `String id) ]

let create_done_task config ~goal_id ~title =
  ignore
    (Coord_task.add_task ~goal_id config ~title ~priority:3
       ~description:"done task fixture");
  let task_id =
    Coord.get_tasks_raw config
    |> List.find_map (fun (task : Masc_domain.task) ->
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
    | Error err -> fail (Masc_domain.masc_error_to_string err)
  in
  step Masc_domain.Claim "test fixture claim";
  step Masc_domain.Start "test fixture start";
  step Masc_domain.Done_action "test fixture done"

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
          ("cascade_name", `String (Keeper_config.default_cascade_name ()));
        ])
  with
  | Ok meta -> { meta with active_goal_ids = [ goal_id ] }
  | Error err -> fail ("meta_of_json failed: " ^ err)

let append_keeper_receipt
    ?(outcome : Keeper_execution_receipt.outcome_kind = `Ok)
    ?(terminal_reason_code = "completed")
    ?(requested_tools = [ "keeper_fs_read" ])
    ?(reported_tools = [ "Read" ])
    ?(observed_tools = [ "keeper_fs_read" ])
    ?(canonical_tools = [ "keeper_fs_read" ])
    ?(tools_used = [ "keeper_fs_read" ])
    ?(tool_contract_result : Keeper_execution_receipt.tool_contract_result =
      Contract_satisfied_completion)
    ?(tool_requirement = Keeper_agent_tool_surface.Required)
    ?(cascade_outcome : Keeper_execution_receipt.cascade_outcome =
      Cascade_completed) (config : Coord.config)
    (meta : Keeper_types.keeper_meta) =
  let started_at = Masc_domain.now_iso () in
  let ended_at = Masc_domain.now_iso () in
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
          turn_lane = Keeper_agent_tool_surface.Lane_tool_required;
          tool_surface_class = Keeper_agent_tool_surface.Surface_mixed;
          tool_requirement;
          visible_tool_count = 1;
          tool_gate_enabled = true;
          tool_surface_fallback_used = false;
          required_tools = [];
          missing_required_tools = [];
        };
      sandbox_kind = Keeper_execution_receipt.sandbox_kind_of_meta meta;
      sandbox_root = Some config.base_path;
      network_mode = meta.network_mode;
      approval_profile = Some "trusted_local";
      approval_profile_derived = false;
      cascade_name = Keeper_cascade_profile.Runtime_name (Keeper_types.cascade_name_of_meta meta);
      cascade_selected_model = Some "openai:gpt-5.4";
      cascade_attempt_count = 1;
      cascade_fallback_applied = false;
      cascade_outcome;
      degraded_retry_applied = false;
      degraded_retry_cascade = None;
      fallback_reason = None;
      cascade_rotation_attempts = [];
      stop_reason = Some Cascade_runner.Completed;
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

let append_keeper_decision_terminal_reason
    (config : Coord.config) (meta : Keeper_types.keeper_meta) =
  Fs_compat.append_jsonl
    (Keeper_types.keeper_decision_log_path config meta.name)
    (`Assoc
      [
        ("ts_unix", `Float (Unix.gettimeofday ()));
        ("turn_id", `Int 11);
        ( "terminal_reason",
          `Assoc
            [
              ("code", `String "decision_specific_terminal_reason");
              ("source", `String "decision_log");
              ("severity", `String "warn");
              ("summary", `String "decision terminal reason is more specific");
              ("next_action", `String "follow_decision_terminal_reason");
            ] );
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
   | Error err -> fail (Masc_domain.masc_error_to_string err));
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

let test_goal_attainment_projects_percent_target () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Percent target goal"
        ~metric:"completion_pct" ~target_value:"75%" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Done task 1";
  create_done_task config ~goal_id:goal.id ~title:"Done task 2";
  create_done_task config ~goal_id:goal.id ~title:"Done task 3";
  ignore
    (Coord_task.add_task ~goal_id:goal.id config ~title:"Open task"
       ~priority:3 ~description:"remaining work");
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "attainment state" "attained"
    (attainment |> member "state" |> to_string);
  check string "attainment basis" "metric_target_percent"
    (attainment |> member "basis" |> to_string);
  check string "target parse status" "parseable"
    (attainment |> member "target_parse_status" |> to_string);
  check int "target-relative pct" 100
    (attainment |> member "attainment_pct" |> to_int);
  check (float 0.001) "observed percent" 75.0
    (attainment |> member "observed_value" |> to_float);
  check (float 0.001) "target percent" 75.0
    (attainment |> member "target_numeric" |> to_float);
  check int "task count" 4 (attainment |> member "task_count" |> to_int);
  check int "done task count" 3
    (attainment |> member "task_done_count" |> to_int)

let test_goal_attainment_exports_prometheus_metric () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Prometheus attainment goal"
        ~metric:"completion_pct" ~target_value:"75%" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Metric done task 1";
  create_done_task config ~goal_id:goal.id ~title:"Metric done task 2";
  create_done_task config ~goal_id:goal.id ~title:"Metric done task 3";
  ignore
    (Coord_task.add_task ~goal_id:goal.id config ~title:"Metric open task"
       ~priority:3 ~description:"remaining work");
  ignore (Dashboard_goals.dashboard_goals_tree_json ~config);
  let labels = [ ("goal_id", goal.id) ] in
  check (option (float 0.001)) "goal attainment pct metric" (Some 100.0)
    (Prometheus.get_metric_value Prometheus.metric_goal_attainment_pct ~labels
       ());
  check (option (float 0.001)) "goal attainment measured metric" (Some 1.0)
    (Prometheus.get_metric_value Prometheus.metric_goal_attainment_measured
       ~labels ())

let test_goal_attainment_projects_camel_case_percent_metric () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Camel percent metric goal"
        ~metric:"successRate" ~target_value:"75" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Done task 1";
  create_done_task config ~goal_id:goal.id ~title:"Done task 2";
  create_done_task config ~goal_id:goal.id ~title:"Done task 3";
  ignore
    (Coord_task.add_task ~goal_id:goal.id config ~title:"Open task"
       ~priority:3 ~description:"remaining work");
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "camel percent basis" "metric_target_percent"
    (attainment |> member "basis" |> to_string);
  check string "camel percent state" "attained"
    (attainment |> member "state" |> to_string);
  check (float 0.001) "camel percent target" 75.0
    (attainment |> member "target_numeric" |> to_float)

let test_goal_attainment_does_not_fake_unparseable_target () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Unparseable target goal"
        ~metric:"latency" ~target_value:"fast enough" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Evidence task";
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "unmeasured state" "unmeasured"
    (attainment |> member "state" |> to_string);
  check string "unmeasured basis" "unmeasured"
    (attainment |> member "basis" |> to_string);
  check string "unparseable target" "unparseable"
    (attainment |> member "target_parse_status" |> to_string);
  check bool "attainment pct omitted" true
    (attainment |> member "attainment_pct" = `Null);
  check int "evidence task retained" 1
    (attainment |> member "task_done_count" |> to_int)

let test_goal_attainment_rejects_non_finite_target () =
  with_room @@ fun config ->
  let huge_decimal = String.make 400 '9' in
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Non-finite target goal"
        ~metric:"completion_pct" ~target_value:huge_decimal ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Evidence task";
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "non-finite target stays unmeasured" "unmeasured"
    (attainment |> member "state" |> to_string);
  check string "non-finite target is unparseable" "unparseable"
    (attainment |> member "target_parse_status" |> to_string);
  check bool "non-finite target numeric omitted" true
    (attainment |> member "target_numeric" = `Null);
  check bool "non-finite target pct omitted" true
    (attainment |> member "attainment_pct" = `Null)

let test_goal_attainment_parses_grouped_count_target () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Grouped count target goal"
        ~metric:"task_count" ~target_value:"1,000 tasks" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Single completed task";
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "count target basis" "metric_target_count"
    (attainment |> member "basis" |> to_string);
  check string "grouped target parse status" "parseable"
    (attainment |> member "target_parse_status" |> to_string);
  check (float 0.001) "grouped target numeric" 1000.0
    (attainment |> member "target_numeric" |> to_float);
  check int "grouped target pct" 0
    (attainment |> member "attainment_pct" |> to_int);
  (* Post-#13131 follow-up: 1 of 1,000 rounds to 0% but observed_value
     is > 0, so the state disambiguates to "in_progress" — the previous
     "not_started" was misleading because the goal already had real
     progress. *)
  check string "grouped target in progress" "in_progress"
    (attainment |> member "state" |> to_string)

let test_goal_attainment_parses_range_target_start () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Range percent target goal"
        ~metric:"completion_pct" ~target_value:"75-80%" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Done task 1";
  create_done_task config ~goal_id:goal.id ~title:"Done task 2";
  create_done_task config ~goal_id:goal.id ~title:"Done task 3";
  ignore
    (Coord_task.add_task ~goal_id:goal.id config ~title:"Open task"
       ~priority:3 ~description:"remaining work");
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "range target basis" "metric_target_percent"
    (attainment |> member "basis" |> to_string);
  check string "range target parse status" "parseable"
    (attainment |> member "target_parse_status" |> to_string);
  check (float 0.001) "range target numeric" 75.0
    (attainment |> member "target_numeric" |> to_float);
  check int "range target pct" 100
    (attainment |> member "attainment_pct" |> to_int)

let test_goal_attainment_rejects_substring_pr_metric () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Approval latency target goal"
        ~metric:"approval_latency" ~target_value:"5" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Completed evidence task";
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "substring pr metric remains unmeasured" "unmeasured"
    (attainment |> member "state" |> to_string);
  check string "substring pr metric unsupported" "unsupported_metric"
    (attainment |> member "target_parse_status" |> to_string);
  check (float 0.001) "unsupported target retained" 5.0
    (attainment |> member "target_numeric" |> to_float);
  check bool "unsupported metric has no pct" true
    (attainment |> member "attainment_pct" = `Null)

(* Post-#13131 follow-up: free-form camelCase metrics like
   [successRate] / [completionPct] must still infer Percent unit.
   The token-based [metric_implies_percent] would have regressed
   them when [metric_word_tokens] flattened camelCase to a single
   token; the camelCase-aware tokenizer keeps the inference. *)
let test_goal_attainment_camel_case_percent_metric_is_percent () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Camel-case percent metric"
        ~metric:"successRate" ~target_value:"80" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Completed evidence";
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "camelCase metric inferred as percent target"
    "metric_target_percent"
    (attainment |> member "basis" |> to_string);
  check string "camelCase metric unit is percent" "percent"
    (attainment |> member "unit" |> to_string)

(* Post-#13131 follow-up: [float_of_string_opt] accepts the literal
   "nan" / "inf" tokens; without the [Float.is_finite] guard the
   resulting non-finite numeric crashed [pct_of_float] via
   [int_of_float (floor nan)].  Pin the projection at
   unparseable / unmeasured for the "nan" target.

   Distinct from [test_goal_attainment_rejects_non_finite_target]
   above (which exercises overflow-to-infinity via a 400-digit
   decimal): both cases must individually round-trip through the
   guard.  Post-#13170 review caught the earlier instance where
   both bindings had the same top-level name and OCaml shadowing
   silently disabled one of them. *)
let test_goal_attainment_rejects_non_finite_target_nan_token () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Non-finite target goal"
        ~metric:"completion_pct" ~target_value:"nan" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Some task";
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "non-finite target stays unmeasured" "unmeasured"
    (attainment |> member "state" |> to_string);
  check string "non-finite target parse status" "unparseable"
    (attainment |> member "target_parse_status" |> to_string);
  check bool "non-finite target has no numeric value" true
    (attainment |> member "target_numeric" = `Null);
  check bool "non-finite target has no pct" true
    (attainment |> member "attainment_pct" = `Null)

(* Post-#13170 review: tokenizer must split acronym-prefixed
   PascalCase metric names.  [APIRatio] / [PRCount] should infer
   percent so dashboards keep treating these common metric forms
   as percent targets. *)
let test_goal_attainment_acronym_pascal_case_percent_metric_is_percent () =
  with_room @@ fun config ->
  let goal, _kind =
    match
      Goal_store.upsert_goal config ~title:"Acronym-prefixed percent metric"
        ~metric:"APIRatio" ~target_value:"80" ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  create_done_task config ~goal_id:goal.id ~title:"Done evidence";
  let attainment =
    Dashboard_goals.dashboard_goals_tree_json ~config
    |> root_node
    |> member "attainment"
  in
  check string "acronym-prefix metric inferred as percent target"
    "metric_target_percent"
    (attainment |> member "basis" |> to_string);
  check string "acronym-prefix metric unit is percent" "percent"
    (attainment |> member "unit" |> to_string)

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
  check string "metadata-only activity is not a runtime blocker"
    "none"
    (node |> member "blocking_source" |> to_string);
  check string "metadata-only activity keeps health on track" "on_track"
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
    ~tools_used:[] ~tool_contract_result:Contract_missing_required_tool_use config meta;
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
          last_blocker =
            Some (Keeper_types.blocker_info_of_class
                    ~detail:"turn timed out" Keeper_types.Turn_timeout);
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

let test_goal_detail_promotes_newer_runtime_blocker_over_stale_receipt () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Ship newer blocker" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let meta = make_keeper_meta ~name:"newer-blocker-keeper" ~goal_id:goal.id in
  (match Keeper_types.write_meta ~force:true config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  append_keeper_receipt config meta;
  let blocked_meta =
    {
      meta with
      runtime =
        {
          meta.runtime with
          usage =
            {
              meta.runtime.usage with
              total_turns = meta.runtime.usage.total_turns + 1;
              last_turn_ts = Unix.gettimeofday () +. 60.0;
            };
          last_blocker =
            Some (Keeper_types.blocker_info_of_class
                    ~detail:"Internal error: [masc_oas_error] {\"kind\":\"oas_timeout_budget\"}"
                    Keeper_types.Oas_timeout_budget);
        };
    }
  in
  (match Keeper_types.write_meta ~force:true config blocked_meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  match Dashboard_goals.goal_detail_json ~config ~goal_id:goal.id with
  | Error msg -> fail msg
  | Ok json ->
      let linked_keeper =
        match json |> member "linked_keepers" |> to_list with
        | keeper :: _ -> keeper
        | [] -> fail "expected linked keeper detail"
      in
      let runtime_trust = linked_keeper |> member "runtime_trust" in
      let terminal_reason =
        runtime_trust |> member "latest_terminal_reason"
      in
      check string "newer blocker drives disposition" "Alert"
        (runtime_trust |> member "disposition" |> to_string);
      check string "newer blocker drives operator disposition"
        "alert_exhausted"
        (runtime_trust |> member "operator_disposition" |> to_string);
      check string "timeout blocker keeps attention reason"
        "timeout_budget_exhausted"
        (runtime_trust |> member "attention_reason" |> to_string);
      check string "latest terminal reason comes from blocker"
        "runtime_blocker"
        (terminal_reason |> member "source" |> to_string);
      check string "latest terminal reason is timeout budget"
        "oas_timeout_budget"
        (terminal_reason |> member "code" |> to_string);
      check string "latest causal event follows runtime blocker"
        "runtime_blocker"
        (runtime_trust |> member "latest_causal_event" |> member "kind" |> to_string)

let test_goal_detail_keeps_decision_terminal_reason_over_newer_blocker () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Prefer decision reason" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let meta =
    make_keeper_meta ~name:"decision-over-blocker-keeper" ~goal_id:goal.id
  in
  (match Keeper_types.write_meta ~force:true config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  append_keeper_receipt config meta;
  append_keeper_decision_terminal_reason config meta;
  let blocked_meta =
    {
      meta with
      runtime =
        {
          meta.runtime with
          usage =
            {
              meta.runtime.usage with
              total_turns = meta.runtime.usage.total_turns + 1;
              last_turn_ts = Unix.gettimeofday () +. 60.0;
            };
          last_blocker =
            Some (Keeper_types.blocker_info_of_class
                    ~detail:"Internal error: [masc_oas_error] {\"kind\":\"oas_timeout_budget\"}"
                    Keeper_types.Oas_timeout_budget);
        };
    }
  in
  (match Keeper_types.write_meta ~force:true config blocked_meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  match Dashboard_goals.goal_detail_json ~config ~goal_id:goal.id with
  | Error msg -> fail msg
  | Ok json ->
      let linked_keeper =
        match json |> member "linked_keepers" |> to_list with
        | keeper :: _ -> keeper
        | [] -> fail "expected linked keeper detail"
      in
      let terminal_reason =
        linked_keeper
        |> member "runtime_trust"
        |> member "latest_terminal_reason"
      in
      check string "decision terminal reason keeps precedence"
        "decision_specific_terminal_reason"
        (terminal_reason |> member "code" |> to_string);
      check string "decision source retained" "decision_log"
        (terminal_reason |> member "source" |> to_string)

let test_goal_detail_derives_attention_from_receipt_disposition () =
  with_room @@ fun config ->
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Ship receipt disposition" () with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  let meta = make_keeper_meta ~name:"receipt-disposition-keeper" ~goal_id:goal.id in
  (match Keeper_types.write_meta ~force:true config meta with
   | Ok () -> ()
   | Error err -> fail ("write_meta failed: " ^ err));
  append_keeper_receipt
    ~tool_contract_result:Contract_needs_execution_progress
    config meta;
  match Dashboard_goals.goal_detail_json ~config ~goal_id:goal.id with
  | Error msg -> fail msg
  | Ok json ->
      let linked_keeper =
        match json |> member "linked_keepers" |> to_list with
        | keeper :: _ -> keeper
        | [] -> fail "expected linked keeper detail"
      in
      let runtime_trust = linked_keeper |> member "runtime_trust" in
      let terminal_reason =
        runtime_trust |> member "latest_terminal_reason"
      in
      check string "receipt disposition pauses" "Pause"
        (runtime_trust |> member "disposition" |> to_string);
      check string "receipt disposition fills attention reason"
        "tool_required_unsatisfied"
        (runtime_trust |> member "attention_reason" |> to_string);
      check string "receipt terminal reason follows operator disposition"
        "required_tool_use_unsatisfied"
        (terminal_reason |> member "code" |> to_string);
      check string "receipt terminal reason source"
        "execution_receipt"
        (terminal_reason |> member "source" |> to_string);
      check string "next action follows terminal reason"
        "inspect_provider_tool_contract"
        (runtime_trust |> member "next_human_action" |> to_string)

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
          test_case "goal attainment projects percent targets" `Quick
            test_goal_attainment_projects_percent_target;
          test_case "goal attainment exports prometheus metric" `Quick
            test_goal_attainment_exports_prometheus_metric;
          test_case "goal attainment projects camel-case percent metrics" `Quick
            test_goal_attainment_projects_camel_case_percent_metric;
          test_case "goal attainment does not fake unparseable targets" `Quick
            test_goal_attainment_does_not_fake_unparseable_target;
          test_case "goal attainment rejects non-finite targets" `Quick
            test_goal_attainment_rejects_non_finite_target;
          test_case "goal attainment parses grouped count targets" `Quick
            test_goal_attainment_parses_grouped_count_target;
          test_case "goal attainment parses range target start" `Quick
            test_goal_attainment_parses_range_target_start;
          test_case "goal attainment rejects substring pr metrics" `Quick
            test_goal_attainment_rejects_substring_pr_metric;
          test_case "goal attainment handles camelCase percent metric"
            `Quick test_goal_attainment_camel_case_percent_metric_is_percent;
          test_case "goal attainment handles acronym-prefix percent metric"
            `Quick
            test_goal_attainment_acronym_pascal_case_percent_metric_is_percent;
          test_case "goal attainment rejects non-finite target (nan token)"
            `Quick test_goal_attainment_rejects_non_finite_target_nan_token;
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
          test_case
            "goal detail promotes newer runtime blocker over stale receipt"
            `Quick
            test_goal_detail_promotes_newer_runtime_blocker_over_stale_receipt;
          test_case
            "goal detail keeps decision terminal reason over newer blocker"
            `Quick
            test_goal_detail_keeps_decision_terminal_reason_over_newer_blocker;
          test_case
            "goal detail derives attention from receipt disposition"
            `Quick
            test_goal_detail_derives_attention_from_receipt_disposition;
        ] );
    ]
