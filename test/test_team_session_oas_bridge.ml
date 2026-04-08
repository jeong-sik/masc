(** Test_team_session_oas_bridge — Unit tests for Phase C-1 bridge module.

    LLM 0 — all tests use mock closures, no real model calls.
    Verifies lossy projection correctness and closure wiring.

    @since 2.124.0 *)

open Masc_mcp

module Swarm = Agent_sdk_swarm
module Oas = Agent_sdk

let execution_scope_testable =
  Alcotest.testable
    (fun fmt scope ->
      Format.pp_print_string fmt
        (Team_session_types.execution_scope_to_string scope))
    ( = )

(* ================================================================ *)
(* Role mapping tests                                               *)
(* ================================================================ *)

let show_role = Swarm.Swarm_types.show_agent_role

let test_role_of_worker_class_executor () =
  let r = Team_session_oas_bridge.role_of_worker_class
    (Some Team_session_types.Worker_executor) in
  Alcotest.(check string) "executor" "Swarm_types.Execute" (show_role r)

let test_role_of_worker_class_scout () =
  let r = Team_session_oas_bridge.role_of_worker_class
    (Some Team_session_types.Worker_scout) in
  Alcotest.(check string) "scout -> discover" "Swarm_types.Discover" (show_role r)

let test_role_of_worker_class_none () =
  let r = Team_session_oas_bridge.role_of_worker_class None in
  Alcotest.(check string) "none -> execute" "Swarm_types.Execute" (show_role r)

let test_role_of_spawn_role_verify () =
  let r = Team_session_oas_bridge.role_of_spawn_role
    ~worker_class:None (Some "verify") in
  Alcotest.(check string) "verify string" "Swarm_types.Verify" (show_role r)

let test_role_of_spawn_role_custom () =
  let r = Team_session_oas_bridge.role_of_spawn_role
    ~worker_class:None (Some "code_reviewer") in
  Alcotest.(check string) "custom role"
    "(Swarm_types.Custom_role \"code_reviewer\")" (show_role r)

let test_role_of_spawn_role_none_with_worker_class () =
  let r = Team_session_oas_bridge.role_of_spawn_role
    ~worker_class:(Some Team_session_types.Worker_librarian) None in
  Alcotest.(check string) "fallback to worker_class"
    "Swarm_types.Summarize" (show_role r)

(* ================================================================ *)
(* Orchestration mode tests                                         *)
(* ================================================================ *)

let show_mode = Swarm.Swarm_types.show_orchestration_mode

let test_mode_manual () =
  let m = Team_session_oas_bridge.mode_of_orchestration
    Team_session_types.Manual in
  Alcotest.(check string) "manual -> supervisor"
    "Swarm_types.Supervisor" (show_mode m)

let test_mode_auto () =
  let m = Team_session_oas_bridge.mode_of_orchestration
    Team_session_types.Auto in
  Alcotest.(check string) "auto -> decentralized"
    "Swarm_types.Decentralized" (show_mode m)

let test_mode_assist () =
  let m = Team_session_oas_bridge.mode_of_orchestration
    Team_session_types.Assist in
  Alcotest.(check string) "assist -> supervisor"
    "Swarm_types.Supervisor" (show_mode m)

(* ================================================================ *)
(* Cascade resolution tests                                         *)
(* ================================================================ *)

let make_pw ?(spawn_model = None) () : Team_session_types.planned_worker =
  { spawn_agent = "test-agent";
    runtime_actor = None;
    spawn_role = Some "execute";
    spawn_model;
    execution_scope = None;
    thinking_enabled = None;
    thinking_budget = None;
    max_turns = None;
    timeout_seconds = None;
    worker_class = None;
    parent_actor = None;
    capsule_mode = None;
    runtime_pool = None;
    lane_id = None;
    controller_level = None;
    control_domain = None;
    supervisor_actor = None;
    task_profile = None;
    risk_level = None;
    routing_confidence = None;
    routing_reason = None;
    routing_escalated = false;
  }

let make_session ?(orchestration_mode = Team_session_types.Auto)
    ?(duration_seconds = 600) ?(planned_workers = []) () :
    Team_session_types.session =
  let now = Time_compat.now () in
  {
    Team_session_types.session_id = "test-session";
    goal = "test goal";
    created_by = "test-user";
    room_id = "test-room";
    operation_id = None;
    origin_kind = Team_session_types.Origin_human;
    status = Team_session_types.Running;
    duration_seconds;
    execution_scope = Team_session_types.Autonomous;
    checkpoint_interval_sec = 30;
    min_agents = 1;
    scale_profile = Team_session_types.Scale_standard;
    control_profile = Team_session_types.Control_flat;
    orchestration_mode;
    communication_mode = Team_session_types.Comm_broadcast;
    model_cascade = [ "llama:qwen3.5" ];
    fallback_policy = Team_session_types.Fallback_none;
    instruction_profile = Team_session_types.Profile_standard;
    alert_channel = Team_session_types.Alert_broadcast;
    auto_resume = false;
    report_formats = [ Team_session_types.Markdown ];
    turn_count = 0;
    agent_names = [ "agent-1" ];
    planned_workers;
    broadcast_count = 0;
    portal_count = 0;
    cascade_attempted = 0;
    cascade_success = 0;
    cascade_failed = 0;
    fallback_task_created = 0;
    min_agents_violation_streak = 0;
    policy_violations = [];
    baseline_done_counts = [];
    final_done_delta_total = None;
    final_done_delta_by_agent = None;
    started_at = now;
    planned_end_at = now +. float_of_int duration_seconds;
    stopped_at = None;
    last_checkpoint_at = Some now;
    last_event_at = Some now;
    last_turn_at = None;
    stop_reason = None;
    generated_report = false;
    delivery_contract = None;
    latest_delivery_verdict = None;
    artifacts_dir = "/tmp/masc-test";
    created_at_iso = Types.now_iso ();
    updated_at_iso = Types.now_iso ();
  }

let test_cascade_explicit_model () =
  let pw = make_pw ~spawn_model:(Some "glm:auto") () in
  let c = Team_session_oas_bridge.cascade_of_worker
    ~session_cascade:["llama:qwen3.5"] pw in
  Alcotest.(check string) "explicit model wins" "glm:auto" c

let test_cascade_session_fallback () =
  let pw = make_pw () in
  let c = Team_session_oas_bridge.cascade_of_worker
    ~session_cascade:["claude:opus"; "llama:qwen3.5"] pw in
  Alcotest.(check string) "session cascade first" "claude:opus" c

let test_cascade_default () =
  let pw = make_pw () in
  let c = Team_session_oas_bridge.cascade_of_worker
    ~session_cascade:[] pw in
  Alcotest.(check string) "default cascade" "keeper_turn" c

let test_cascade_empty_model_string () =
  let pw = make_pw ~spawn_model:(Some "") () in
  let c = Team_session_oas_bridge.cascade_of_worker
    ~session_cascade:["llama:qwen3.5"] pw in
  Alcotest.(check string) "empty model falls through" "llama:qwen3.5" c

let test_session_to_swarm_config_health_contract () =
  let worker_a = make_pw () in
  let worker_b =
    { (make_pw ()) with
      spawn_agent = "reviewer";
      spawn_role = Some "verify";
      max_turns = Some 4;
    }
  in
  let session = make_session ~planned_workers:[ worker_a; worker_b ] () in
  let tmp = Filename.temp_dir "masc-test" "" in
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Room.default_config tmp in
  ignore (Room.init config ~agent_name:(Some "tester"));
  Team_session_store.ensure_session_dirs config session.session_id;
  Team_session_store.save_session config session;
  let swarm_cfg =
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    Team_session_oas_bridge.session_to_swarm_config ~sw ~net ~config ~masc_tools:[]
      ~dispatch:(fun ~name:_ ~args:_ -> (false, "no"))
      session
  in
  Alcotest.(check bool) "convergence present" true
    (Option.is_some swarm_cfg.convergence);
  Alcotest.(check bool) "resource_check present" true
    (Option.is_some swarm_cfg.resource_check);
  Alcotest.(check bool) "streaming disabled by default" false
    swarm_cfg.enable_streaming;
  Alcotest.(check (option (float 0.001))) "budget derived from duration"
    (Some 600.0) swarm_cfg.budget.max_total_time_sec;
  let convergence = Option.get swarm_cfg.convergence in
  let metric_value =
    match convergence.metric with
    | Swarm.Swarm_types.Callback f -> f ()
    | Swarm.Swarm_types.Argv_command argv ->
        Alcotest.failf "expected callback metric, got argv command %s"
          (String.concat " " argv)
  in
  Alcotest.(check (float 0.001)) "initial success ratio" 0.0 metric_value;
  Alcotest.(check int) "single-pass convergence iterations" 1
    convergence.max_iterations;
  let first_entry = List.hd swarm_cfg.entries in
  Alcotest.(check bool) "entry telemetry present" true
    (Option.is_some first_entry.get_telemetry);
  let telemetry = Option.get first_entry.get_telemetry () in
  Alcotest.(check int) "initial telemetry turn_count" 0 telemetry.turn_count;
  Alcotest.(check bool) "initial telemetry usage empty" true
    (Option.is_none telemetry.usage);
  Alcotest.(check bool) "collaboration_context populated" true
    (Option.is_some swarm_cfg.collaboration_context);
  (match swarm_cfg.collaboration_context with
   | Some (`Assoc fields) ->
       Alcotest.(check bool) "has team_goal field" true
         (List.mem_assoc "team_goal" fields);
       Alcotest.(check bool) "has task_tree field" true
         (List.mem_assoc "task_tree" fields)
   | _ -> Alcotest.fail "collaboration_context should be JSON object");
  let resource_ok = Option.get swarm_cfg.resource_check () in
  Alcotest.(check bool) "resource check passes for initialized room" true
    resource_ok;
  Team_session_store.save_session config
    { session with status = Team_session_types.Paused };
  let resource_stale = Option.get swarm_cfg.resource_check () in
  Alcotest.(check bool) "resource check fails when session no longer running"
    false resource_stale

let test_telemetry_of_run_result_carries_trace_ref () =
  let trace_ref =
    {
      Oas.Raw_trace.worker_run_id = "run-123";
      path = "/tmp/oas-trace.jsonl";
      start_seq = 1;
      end_seq = 7;
      agent_name = "test-agent";
      session_id = Some "team-session-1";
    }
  in
  let result : Oas_worker.run_result =
    {
      response =
        {
          Oas.Types.id = "resp-1";
          model = "glm:auto";
          stop_reason = Oas.Types.EndTurn;
          content = [];
          usage = None;
          telemetry = None;
        };
      checkpoint = None;
      session_id = "session-1";
      turns = 3;
      trace_ref = Some trace_ref;
      proof = None;
      cascade_observation = None;
      stop_reason = Oas_worker.Completed;
    }
  in
  let telemetry = Team_session_oas_bridge.telemetry_of_run_result result in
  Alcotest.(check int) "turn_count preserved" 3 telemetry.turn_count;
  match telemetry.trace_ref with
  | Some actual ->
      Alcotest.(check string) "worker_run_id" trace_ref.worker_run_id
        actual.worker_run_id;
      Alcotest.(check string) "agent_name" trace_ref.agent_name
        actual.agent_name
  | None -> Alcotest.fail "expected trace_ref in telemetry"

let test_is_safe_worker_run_id_rejects_dot_segments () =
  Alcotest.(check bool) "plain run id accepted" true
    (Team_session_oas_bridge.is_safe_worker_run_id "run-123");
  Alcotest.(check bool) "dot rejected" false
    (Team_session_oas_bridge.is_safe_worker_run_id ".");
  Alcotest.(check bool) "dot-dot rejected" false
    (Team_session_oas_bridge.is_safe_worker_run_id "..");
  Alcotest.(check bool) "slash rejected" false
    (Team_session_oas_bridge.is_safe_worker_run_id "run/123")

let test_slot_aware_cap_reduces_parallelism () =
  let cap =
    Team_session_oas_bridge.slot_aware_concurrency_cap ~entry_count:4
      ~selection_count:2 ~all_discovered:true ~endpoints_found:2 ~total:2
  in
  Alcotest.(check int) "cap reduced to discovered total" 2 cap

let test_slot_aware_cap_keeps_single_entry_sessions_unchanged () =
  let cap =
    Team_session_oas_bridge.slot_aware_concurrency_cap ~entry_count:1
      ~selection_count:2 ~all_discovered:true ~endpoints_found:1 ~total:1
  in
  Alcotest.(check int) "single-entry sessions keep original entry count" 1 cap

let test_slot_aware_cap_accepts_shared_endpoint_selections () =
  let cap =
    Team_session_oas_bridge.slot_aware_concurrency_cap ~entry_count:3
      ~selection_count:2 ~all_discovered:true ~endpoints_found:1 ~total:1
  in
  Alcotest.(check int) "shared endpoint still caps concurrency" 1 cap

let test_slot_aware_cap_accepts_partially_collapsed_endpoint_selections () =
  let cap =
    Team_session_oas_bridge.slot_aware_concurrency_cap ~entry_count:4
      ~selection_count:3 ~all_discovered:true ~endpoints_found:2 ~total:2
  in
  Alcotest.(check int) "partially collapsed shared endpoints still cap concurrency" 2 cap

let test_slot_aware_cap_falls_back_without_full_discovery () =
  let cap =
    Team_session_oas_bridge.slot_aware_concurrency_cap ~entry_count:3
      ~selection_count:2 ~all_discovered:false ~endpoints_found:1 ~total:1
  in
  Alcotest.(check int) "fallback keeps original entry count" 3 cap

let test_slot_aware_cap_falls_back_for_non_positive_selection_count () =
  let cap =
    Team_session_oas_bridge.slot_aware_concurrency_cap ~entry_count:3
      ~selection_count:0 ~all_discovered:true ~endpoints_found:1 ~total:1
  in
  Alcotest.(check int) "non-positive selection count keeps original entry count" 3 cap

(* ================================================================ *)
(* Supported tool runtime tests                                     *)
(* ================================================================ *)

let test_supported_local_worker_tools_present () =
  let schemas =
    match Team_session_oas_bridge.supported_local_worker_tools () with
    | Ok schemas -> schemas
    | Error message -> Alcotest.failf "expected schemas, got error: %s" message
  in
  let names =
    List.map (fun (schema : Types.tool_schema) -> schema.name) schemas
  in
  Alcotest.(check bool) "masc_status present" true
    (List.mem "masc_status" names);
  Alcotest.(check bool) "masc_code_read present" true
    (List.mem "masc_code_read" names);
  Alcotest.(check bool) "masc_run_init present" true
    (List.mem "masc_run_init" names);
  Alcotest.(check bool) "masc_repair_loop_start present" true
    (List.mem "masc_repair_loop_start" names)

let test_supported_local_worker_tools_for_observe_only_filter_mutations () =
  let names =
    Team_session_oas_bridge.supported_local_worker_tool_names_for_scope
      (Some Team_session_types.Observe_only)
  in
  Alcotest.(check bool) "observe_only keeps masc_status" true
    (List.mem "masc_status" names);
  Alcotest.(check bool) "observe_only keeps masc_code_read" true
    (List.mem "masc_code_read" names);
  Alcotest.(check bool) "observe_only keeps masc_worktree_list" true
    (List.mem "masc_worktree_list" names);
  Alcotest.(check bool) "observe_only blocks masc_worktree_create" false
    (List.mem "masc_worktree_create" names);
  Alcotest.(check bool) "observe_only blocks masc_worktree_remove" false
    (List.mem "masc_worktree_remove" names);
  Alcotest.(check bool) "observe_only blocks masc_run_init" false
    (List.mem "masc_run_init" names);
  Alcotest.(check bool) "observe_only blocks masc_board_post" false
    (List.mem "masc_board_post" names)

let test_supported_local_worker_tools_for_observe_only_resolve_subset () =
  let schemas =
    match
      Team_session_oas_bridge.supported_local_worker_tools_for_scope
        (Some Team_session_types.Observe_only)
    with
    | Ok schemas -> schemas
    | Error message ->
        Alcotest.failf "expected scoped schemas, got error: %s" message
  in
  let names =
    List.map (fun (schema : Types.tool_schema) -> schema.name) schemas
  in
  Alcotest.(check bool) "scoped schemas keep masc_status" true
    (List.mem "masc_status" names);
  Alcotest.(check bool) "scoped schemas keep masc_code_read" true
    (List.mem "masc_code_read" names);
  Alcotest.(check bool) "scoped schemas block masc_worktree_create" false
    (List.mem "masc_worktree_create" names);
  Alcotest.(check bool) "scoped schemas block masc_run_log" false
    (List.mem "masc_run_log" names)

let test_effective_planned_worker_execution_scope_defaults_executor () =
  let worker =
    { (make_pw ()) with
      worker_class = Some Team_session_types.Worker_executor;
      execution_scope = None;
    }
  in
  let scope =
    Team_session_types.effective_execution_scope_of_planned_worker worker
  in
  Alcotest.(check execution_scope_testable)
    "executor defaults to limited_code_change"
    Team_session_types.Limited_code_change scope

let test_effective_planned_worker_execution_scope_defaults_observe_only () =
  let worker = make_pw () in
  let scope =
    Team_session_types.effective_execution_scope_of_planned_worker worker
  in
  Alcotest.(check execution_scope_testable)
    "non-executor defaults to observe_only"
    Team_session_types.Observe_only scope;
  let names =
    Team_session_oas_bridge.supported_local_worker_tool_names_for_scope
      (Some scope)
  in
  Alcotest.(check bool) "defaulted observe_only blocks masc_run_init" false
    (List.mem "masc_run_init" names);
  Alcotest.(check bool) "defaulted observe_only keeps masc_code_read" true
    (List.mem "masc_code_read" names)

let test_effective_planned_worker_execution_scope_preserves_explicit_scope () =
  let worker =
    { (make_pw ()) with
      worker_class = Some Team_session_types.Worker_executor;
      execution_scope = Some Team_session_types.Autonomous;
    }
  in
  let scope =
    Team_session_types.effective_execution_scope_of_planned_worker worker
  in
  Alcotest.(check execution_scope_testable) "explicit scope wins"
    Team_session_types.Autonomous scope

let test_dispatch_supported_tool_status () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let tmp = Filename.temp_dir "masc-test" "" in
  let config = Room.default_config tmp in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ok, message =
    Team_session_oas_bridge.dispatch_supported_tool
      ~sw ~clock:(Eio.Stdenv.clock env) ~config
      ~name:"masc_status"
      ~args:(`Assoc [("agent_name", `String "worker-status")])
  in
  Alcotest.(check bool) "status dispatch succeeded" true ok;
  Alcotest.(check bool) "status payload non-empty" true
    (String.length message > 0)

let test_dispatch_supported_tool_heartbeat_autojoin () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let tmp = Filename.temp_dir "masc-test" "" in
  let config = Room.default_config tmp in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ok, _message =
    Team_session_oas_bridge.dispatch_supported_tool
      ~sw ~clock:(Eio.Stdenv.clock env) ~config
      ~name:"masc_heartbeat"
      ~args:(`Assoc [("agent_name", `String "worker-heartbeat")])
  in
  Alcotest.(check bool) "heartbeat dispatch succeeded" true ok;
  Alcotest.(check bool) "worker auto-joined" true
    (Room.is_agent_joined config ~agent_name:"worker-heartbeat")

let test_run_repair_loop_until_terminal_with_fake_dispatch () =
  let iterate_calls = ref 0 in
  let dispatch_tool ~name ~args:_ =
    match name with
    | "masc_repair_loop_start" ->
        ( true,
          Yojson.Safe.to_string
            (`Assoc
              [
                ("loop_id", `String "loop-1");
                ("status", `String "running");
                ("attempt_count", `Int 0);
                ("max_attempts", `Int 2);
              ]) )
    | "masc_repair_loop_iterate" ->
        incr iterate_calls;
        if !iterate_calls = 1 then
          ( true,
            Yojson.Safe.to_string
              (`Assoc
                [
                  ("loop_id", `String "loop-1");
                  ("status", `String "repairable_failure");
                  ("attempt_count", `Int 1);
                  ("max_attempts", `Int 2);
                ]) )
        else
          ( true,
            Yojson.Safe.to_string
              (`Assoc
                [
                  ("loop_id", `String "loop-1");
                  ("status", `String "passed");
                  ("attempt_count", `Int 2);
                  ("max_attempts", `Int 2);
                ]) )
    | other -> Alcotest.failf "unexpected tool call: %s" other
  in
  let ok, body =
    Team_session_oas_bridge.run_repair_loop_until_terminal_with ~dispatch_tool
      (`Assoc
        [
          ("plugin_id", `String "ocaml");
          ("task_spec", `String "Write only OCaml code for inc : int -> int.");
        ])
  in
  Alcotest.(check bool) "terminal result ok" true ok;
  Alcotest.(check int) "iterate called twice" 2 !iterate_calls;
  let json = Yojson.Safe.from_string body in
  Alcotest.(check string) "status passed" "passed"
    Yojson.Safe.Util.(json |> member "status" |> to_string)

let test_run_repair_loop_until_terminal_with_guard () =
  let iterate_calls = ref 0 in
  let dispatch_tool ~name ~args:_ =
    match name with
    | "masc_repair_loop_start" ->
        ( true,
          Yojson.Safe.to_string
            (`Assoc
              [
                ("loop_id", `String "loop-guard");
                ("status", `String "running");
                ("attempt_count", `Int 0);
                ("max_attempts", `Int 2);
              ]) )
    | "masc_repair_loop_iterate" ->
        incr iterate_calls;
        ( true,
          Yojson.Safe.to_string
            (`Assoc
              [
                ("loop_id", `String "loop-guard");
                ("status", `String "running");
                ("attempt_count", `Int !iterate_calls);
                ("max_attempts", `Int 2);
              ]) )
    | other -> Alcotest.failf "unexpected tool call: %s" other
  in
  let ok, body =
    Team_session_oas_bridge.run_repair_loop_until_terminal_with ~dispatch_tool
      (`Assoc
        [
          ("plugin_id", `String "ocaml");
          ("task_spec", `String "Never reaches terminal state.");
        ])
  in
  Alcotest.(check bool) "guard returns failure" false ok;
  Alcotest.(check int) "guard caps iterate calls" 3 !iterate_calls;
  Alcotest.(check string) "guard message"
    "repair loop iteration guard exceeded for loop-guard" body

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "Team Session OAS Bridge" [
    "role_mapping", [
      Alcotest.test_case "worker_class executor" `Quick
        test_role_of_worker_class_executor;
      Alcotest.test_case "worker_class scout" `Quick
        test_role_of_worker_class_scout;
      Alcotest.test_case "worker_class none" `Quick
        test_role_of_worker_class_none;
      Alcotest.test_case "spawn_role verify" `Quick
        test_role_of_spawn_role_verify;
      Alcotest.test_case "spawn_role custom" `Quick
        test_role_of_spawn_role_custom;
      Alcotest.test_case "spawn_role none with worker_class" `Quick
        test_role_of_spawn_role_none_with_worker_class;
    ];
    "orchestration_mode", [
      Alcotest.test_case "manual -> supervisor" `Quick
        test_mode_manual;
      Alcotest.test_case "auto -> decentralized" `Quick
        test_mode_auto;
      Alcotest.test_case "assist -> supervisor" `Quick
        test_mode_assist;
    ];
    "cascade_resolution", [
      Alcotest.test_case "explicit model" `Quick
        test_cascade_explicit_model;
      Alcotest.test_case "session fallback" `Quick
        test_cascade_session_fallback;
      Alcotest.test_case "default cascade" `Quick
        test_cascade_default;
      Alcotest.test_case "empty model string" `Quick
        test_cascade_empty_model_string;
      Alcotest.test_case "session swarm health contract" `Quick
        test_session_to_swarm_config_health_contract;
      Alcotest.test_case "telemetry carries trace_ref" `Quick
        test_telemetry_of_run_result_carries_trace_ref;
      Alcotest.test_case "worker run id rejects dot segments" `Quick
        test_is_safe_worker_run_id_rejects_dot_segments;
      Alcotest.test_case "slot-aware cap reduces parallelism" `Quick
        test_slot_aware_cap_reduces_parallelism;
      Alcotest.test_case "slot-aware cap keeps single-entry sessions unchanged" `Quick
        test_slot_aware_cap_keeps_single_entry_sessions_unchanged;
      Alcotest.test_case "slot-aware cap accepts shared endpoint selections" `Quick
        test_slot_aware_cap_accepts_shared_endpoint_selections;
      Alcotest.test_case "slot-aware cap accepts partially collapsed endpoint selections" `Quick
        test_slot_aware_cap_accepts_partially_collapsed_endpoint_selections;
      Alcotest.test_case "slot-aware cap falls back without full discovery" `Quick
        test_slot_aware_cap_falls_back_without_full_discovery;
      Alcotest.test_case "slot-aware cap falls back for non-positive selection count" `Quick
        test_slot_aware_cap_falls_back_for_non_positive_selection_count;
    ];
    "supported_tools", [
      Alcotest.test_case "schemas present" `Quick
        test_supported_local_worker_tools_present;
      Alcotest.test_case "observe_only filters mutating names" `Quick
        test_supported_local_worker_tools_for_observe_only_filter_mutations;
      Alcotest.test_case "observe_only resolves scoped schemas" `Quick
        test_supported_local_worker_tools_for_observe_only_resolve_subset;
      Alcotest.test_case "executor default scope" `Quick
        test_effective_planned_worker_execution_scope_defaults_executor;
      Alcotest.test_case "non-executor default observe_only scope" `Quick
        test_effective_planned_worker_execution_scope_defaults_observe_only;
      Alcotest.test_case "explicit scope preserved" `Quick
        test_effective_planned_worker_execution_scope_preserves_explicit_scope;
      Alcotest.test_case "status dispatch" `Quick
        test_dispatch_supported_tool_status;
      Alcotest.test_case "heartbeat autojoin" `Quick
        test_dispatch_supported_tool_heartbeat_autojoin;
      Alcotest.test_case "repair loop wrapper iterates until terminal" `Quick
        test_run_repair_loop_until_terminal_with_fake_dispatch;
      Alcotest.test_case "repair loop wrapper guards runaway status" `Quick
        test_run_repair_loop_until_terminal_with_guard;
    ];
  ]
