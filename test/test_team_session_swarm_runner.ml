(** Test_team_session_swarm_runner — Unit tests for C-2a/C-2b swarm runner
    and callbacks modules.

    LLM 0 — all tests use mock closures, no real model calls.
    Tests verify: session loading, swarm config conversion, callback wiring,
    result application, and error paths.

    @since 2.125.0 *)

open Masc_mcp
module Swarm = Agent_sdk_swarm

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let make_test_session ?(orchestration_mode = Team_session_types.Auto)
    ?(model_cascade = ["llama:qwen3.5"])
    ?(planned_workers = [])
    ?(status = Team_session_types.Running)
    session_id =
  let now = Time_compat.now () in
  ({ Team_session_types.session_id;
     goal = "test goal";
     created_by = "test-user";
     room_id = "test-room";
     operation_id = None;
     origin_kind = Team_session_types.Origin_human;
     status;
     duration_seconds = 600;
     execution_scope = Team_session_types.Autonomous;
     checkpoint_interval_sec = 30;
     min_agents = 1;
     scale_profile = Team_session_types.Scale_standard;
     control_profile = Team_session_types.Control_flat;
     orchestration_mode;
     communication_mode = Team_session_types.Comm_broadcast;
     model_cascade;
     fallback_policy = Team_session_types.Fallback_none;
     instruction_profile = Team_session_types.Profile_standard;
     alert_channel = Team_session_types.Alert_broadcast;
     auto_resume = false;
     report_formats = [Team_session_types.Markdown];
     turn_count = 0;
     agent_names = ["agent-1"];
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
     planned_end_at = now +. 600.0;
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
   } : Team_session_types.session)

(* ================================================================ *)
(* Callback creation tests                                          *)
(* ================================================================ *)

let test_callbacks_all_some () =
  let tmp = Filename.temp_dir "masc-test" "" in
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Room.default_config tmp in
  let cbs = Team_session_swarm_callbacks.make_callbacks
    ~config ~session_id:"test-123" in
  Alcotest.(check bool) "on_iteration_start present"
    true (Option.is_some cbs.on_iteration_start);
  Alcotest.(check bool) "on_iteration_end present"
    true (Option.is_some cbs.on_iteration_end);
  Alcotest.(check bool) "on_agent_start present"
    true (Option.is_some cbs.on_agent_start);
  Alcotest.(check bool) "on_agent_done present"
    true (Option.is_some cbs.on_agent_done);
  Alcotest.(check bool) "on_converged present"
    true (Option.is_some cbs.on_converged);
  Alcotest.(check bool) "on_error present"
    true (Option.is_some cbs.on_error)

let test_agent_done_event_includes_telemetry () =
  let tmp = Filename.temp_dir "masc-test" "" in
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Room.default_config tmp in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let session_id = "test-telemetry" in
  Team_session_store.ensure_session_dirs config session_id;
  let cbs = Team_session_swarm_callbacks.make_callbacks ~config ~session_id in
  let trace_ref =
    {
      Agent_sdk.Raw_trace.worker_run_id = "run-telemetry";
      path = "/tmp/run-telemetry.jsonl";
      start_seq = 2;
      end_seq = 9;
      agent_name = "agent-a";
      session_id = Some session_id;
    }
  in
  let usage =
    {
      Agent_sdk.Types.total_input_tokens = 11;
      total_output_tokens = 7;
      total_cache_creation_input_tokens = 0;
      total_cache_read_input_tokens = 0;
      api_calls = 2;
      estimated_cost_usd = 0.13;
    }
  in
  let telemetry =
    {
      Swarm.Swarm_types.trace_ref = Some trace_ref;
      usage = Some usage;
      turn_count = 3;
    }
  in
  Option.get cbs.on_agent_done "agent-a"
    (Swarm.Swarm_types.Done_ok
       { elapsed = 1.25; text = "completed"; telemetry });
  let events = Team_session_store.read_events ~max_events:1 config session_id in
  let event = List.hd events in
  let open Yojson.Safe.Util in
  let detail = event |> member "detail" in
  Alcotest.(check string) "event type" "swarm_agent_done"
    (event |> member "event_type" |> to_string);
  Alcotest.(check int) "telemetry turn_count" 3
    (detail |> member "telemetry" |> member "turn_count" |> to_int);
  Alcotest.(check string) "trace ref worker_run_id" "run-telemetry"
    (detail |> member "telemetry" |> member "trace_ref"
     |> member "worker_run_id" |> to_string);
  Alcotest.(check string) "top-level worker_run_id" "run-telemetry"
    (detail |> member "worker_run_id" |> to_string);
  Alcotest.(check string) "top-level trace ref worker_run_id" "run-telemetry"
    (detail |> member "trace_ref" |> member "worker_run_id" |> to_string);
  Alcotest.(check bool) "trace path omitted from event detail" true
    (detail |> member "trace_ref" |> member "path" = `Null);
  Alcotest.(check (list string)) "evidence refs use worker-run ref"
    [ "worker-run:run-telemetry" ]
    (detail |> member "evidence_refs" |> to_list |> List.map to_string);
  Alcotest.(check int) "usage api_calls" 2
    (detail |> member "telemetry" |> member "usage" |> member "api_calls"
     |> to_int);
  Alcotest.(check (option string)) "proof events parse agent from swarm callback"
    (Some "agent-a") (Dashboard_proof_events.event_actor event);
  Alcotest.(check (option string)) "proof events parse output preview"
    (Some "completed")
    (Dashboard_proof_events.event_output_preview event);
  Alcotest.(check string) "proof events use output preview in summary"
    "completed" (Dashboard_proof_events.event_summary event)

(* ================================================================ *)
(* apply_swarm_result tests                                         *)
(* ================================================================ *)

let test_apply_converged_result () =
  let session = make_test_session "s-conv" in
  let result : Swarm.Swarm_types.swarm_result = {
    iterations = [];
    final_metric = Some 0.95;
    converged = true;
    total_elapsed = 12.5;
    total_usage = { Agent_sdk.Types.total_input_tokens = 0;
      total_output_tokens = 0; total_cache_creation_input_tokens = 0;
      total_cache_read_input_tokens = 0; api_calls = 0;
      estimated_cost_usd = 0.0 };
  } in
  let updated = Team_session_oas_bridge.apply_swarm_result session result in
  Alcotest.(check string) "status completed"
    "completed" (Team_session_types.status_to_string updated.status);
  Alcotest.(check bool) "stop_reason set"
    true (Option.is_some updated.stop_reason);
  Alcotest.(check string) "stop_reason value"
    "swarm_converged" (Option.get updated.stop_reason)

let test_apply_exhausted_result () =
  let session = make_test_session "s-exh" in
  let result : Swarm.Swarm_types.swarm_result = {
    iterations = [];
    final_metric = None;
    converged = false;
    total_elapsed = 300.0;
    total_usage = { Agent_sdk.Types.total_input_tokens = 0;
      total_output_tokens = 0; total_cache_creation_input_tokens = 0;
      total_cache_read_input_tokens = 0; api_calls = 0;
      estimated_cost_usd = 0.0 };
  } in
  let updated = Team_session_oas_bridge.apply_swarm_result session result in
  Alcotest.(check string) "status failed"
    "failed" (Team_session_types.status_to_string updated.status);
  Alcotest.(check string) "stop_reason exhausted"
    "swarm_exhausted" (Option.get updated.stop_reason)

let test_apply_partial_result () =
  let session = make_test_session "s-partial" in
  let result : Swarm.Swarm_types.swarm_result = {
    iterations = [
      {
        Swarm.Swarm_types.iteration = 1;
        metric_value = Some 0.5;
        agent_results = [
          ( "agent-ok",
            Swarm.Swarm_types.Done_ok
              {
                elapsed = 1.0;
                text = "done";
                telemetry = Swarm.Swarm_types.empty_telemetry;
              } );
          ( "agent-err",
            Swarm.Swarm_types.Done_error
              {
                elapsed = 1.5;
                error = "boom";
                telemetry = Swarm.Swarm_types.empty_telemetry;
              } );
        ];
        elapsed = 2.0;
        timestamp = Time_compat.now ();
        trace_refs = [];
      };
    ];
    final_metric = Some 0.5;
    converged = false;
    total_elapsed = 2.0;
    total_usage = { Agent_sdk.Types.total_input_tokens = 0;
      total_output_tokens = 0; total_cache_creation_input_tokens = 0;
      total_cache_read_input_tokens = 0; api_calls = 0;
      estimated_cost_usd = 0.0 };
  } in
  let updated = Team_session_oas_bridge.apply_swarm_result session result in
  Alcotest.(check string) "status interrupted"
    "interrupted" (Team_session_types.status_to_string updated.status);
  Alcotest.(check int) "turn_count increments by iteration count" 1
    updated.turn_count;
  Alcotest.(check string) "stop_reason partial"
    "swarm_partial_completion" (Option.get updated.stop_reason)

let test_apply_result_counts_iterations_as_turns () =
  let session = { (make_test_session "s-turns") with turn_count = 4 } in
  let result : Swarm.Swarm_types.swarm_result = {
    iterations = [
      {
        Swarm.Swarm_types.iteration = 1;
        metric_value = Some 0.2;
        agent_results = [
          ( "agent-1",
            Swarm.Swarm_types.Done_ok
              {
                elapsed = 0.8;
                text = "done";
                telemetry = Swarm.Swarm_types.empty_telemetry;
              } );
          ( "agent-2",
            Swarm.Swarm_types.Done_ok
              {
                elapsed = 0.9;
                text = "done";
                telemetry = Swarm.Swarm_types.empty_telemetry;
              } );
        ];
        elapsed = 1.8;
        timestamp = Time_compat.now ();
        trace_refs = [];
      };
      {
        Swarm.Swarm_types.iteration = 2;
        metric_value = Some 0.4;
        agent_results = [
          ( "agent-1",
            Swarm.Swarm_types.Done_ok
              {
                elapsed = 1.0;
                text = "done";
                telemetry = Swarm.Swarm_types.empty_telemetry;
              } );
        ];
        elapsed = 1.0;
        timestamp = Time_compat.now ();
        trace_refs = [];
      };
    ];
    final_metric = Some 0.4;
    converged = false;
    total_elapsed = 2.8;
    total_usage = { Agent_sdk.Types.total_input_tokens = 0;
      total_output_tokens = 0; total_cache_creation_input_tokens = 0;
      total_cache_read_input_tokens = 0; api_calls = 0;
      estimated_cost_usd = 0.0 };
  } in
  let updated = Team_session_oas_bridge.apply_swarm_result session result in
  Alcotest.(check int) "turn_count adds iteration count, not agent results" 6
    updated.turn_count

let test_apply_all_agents_failed_result () =
  let session = make_test_session "s-all-failed" in
  let result : Swarm.Swarm_types.swarm_result = {
    iterations = [
      {
        Swarm.Swarm_types.iteration = 1;
        metric_value = Some 0.0;
        agent_results = [
          ( "agent-1",
            Swarm.Swarm_types.Done_error
              {
                elapsed = 1.0;
                error = "first";
                telemetry = Swarm.Swarm_types.empty_telemetry;
              } );
          ( "agent-2",
            Swarm.Swarm_types.Done_error
              {
                elapsed = 1.1;
                error = "second";
                telemetry = Swarm.Swarm_types.empty_telemetry;
              } );
        ];
        elapsed = 2.1;
        timestamp = Time_compat.now ();
        trace_refs = [];
      };
    ];
    final_metric = Some 0.0;
    converged = false;
    total_elapsed = 2.1;
    total_usage = { Agent_sdk.Types.total_input_tokens = 0;
      total_output_tokens = 0; total_cache_creation_input_tokens = 0;
      total_cache_read_input_tokens = 0; api_calls = 0;
      estimated_cost_usd = 0.0 };
  } in
  let updated = Team_session_oas_bridge.apply_swarm_result session result in
  Alcotest.(check string) "status failed"
    "failed" (Team_session_types.status_to_string updated.status);
  Alcotest.(check string) "stop_reason all agents failed"
    "swarm_all_agents_failed" (Option.get updated.stop_reason)

let test_apply_updates_stopped_at () =
  let session = make_test_session "s-ts" in
  Alcotest.(check bool) "initially no stopped_at"
    true (Option.is_none session.stopped_at);
  let result : Swarm.Swarm_types.swarm_result = {
    iterations = []; final_metric = None;
    converged = true; total_elapsed = 1.0;
    total_usage = { Agent_sdk.Types.total_input_tokens = 0;
      total_output_tokens = 0; total_cache_creation_input_tokens = 0;
      total_cache_read_input_tokens = 0; api_calls = 0;
      estimated_cost_usd = 0.0 };
  } in
  let updated = Team_session_oas_bridge.apply_swarm_result session result in
  Alcotest.(check bool) "stopped_at set"
    true (Option.is_some updated.stopped_at)

(* ================================================================ *)
(* session_to_swarm_config tests                                    *)
(* ================================================================ *)

let test_empty_planned_workers () =
  let session = make_test_session "s-empty" in
  let tmp = Filename.temp_dir "masc-test" "" in
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Room.default_config tmp in
  let swarm_cfg =
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    Team_session_oas_bridge.session_to_swarm_config
      ~sw ~net ~config ~masc_tools:[] ~dispatch:(fun ~name:_ ~args:_ -> (false, "no"))
      session
  in
  Alcotest.(check int) "entries empty" 0 (List.length swarm_cfg.entries);
  Alcotest.(check string) "prompt" "test goal" swarm_cfg.prompt

let test_auto_mode_produces_decentralized () =
  let session = make_test_session
    ~orchestration_mode:Team_session_types.Auto "s-auto" in
  let tmp = Filename.temp_dir "masc-test" "" in
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Room.default_config tmp in
  let swarm_cfg =
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    Team_session_oas_bridge.session_to_swarm_config
      ~sw ~net ~config ~masc_tools:[] ~dispatch:(fun ~name:_ ~args:_ -> (false, "no"))
      session
  in
  let mode_str = Swarm.Swarm_types.show_orchestration_mode swarm_cfg.mode in
  Alcotest.(check string) "mode decentralized"
    "Swarm_types.Decentralized" mode_str

let test_manual_mode_produces_supervisor () =
  let session = make_test_session
    ~orchestration_mode:Team_session_types.Manual "s-manual" in
  let tmp = Filename.temp_dir "masc-test" "" in
  Eio_main.run @@ fun env ->
  Eio_guard.enable ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Room.default_config tmp in
  let swarm_cfg =
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    Team_session_oas_bridge.session_to_swarm_config
      ~sw ~net ~config ~masc_tools:[] ~dispatch:(fun ~name:_ ~args:_ -> (false, "no"))
      session
  in
  let mode_str = Swarm.Swarm_types.show_orchestration_mode swarm_cfg.mode in
  Alcotest.(check string) "mode supervisor"
    "Swarm_types.Supervisor" mode_str

let test_run_swarm_empty_workers_keeps_session_running () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let tmp = Filename.temp_dir "masc-test" "" in
  let config = Room.default_config tmp in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let session =
    make_test_session ~orchestration_mode:Team_session_types.Assist "s-idle"
  in
  Team_session_store.ensure_session_dirs config session.session_id;
  Team_session_store.save_session config session;
  match
    Team_session_swarm_runner.run_swarm ~sw ~env ~config
      ~session_id:session.session_id ~masc_tools:[]
      ~dispatch:(fun ~name:_ ~args:_ -> (false, "no"))
  with
  | Error e ->
      Alcotest.failf "expected idle session to remain running, got %s" e
  | Ok updated ->
      Alcotest.(check string) "status remains running" "running"
        (Team_session_types.status_to_string updated.status);
      let reloaded =
        Team_session_store.load_session config session.session_id |> Option.get
      in
      Alcotest.(check string) "stored status remains running" "running"
        (Team_session_types.status_to_string reloaded.status);
      let events =
        Team_session_store.read_events ~max_events:10 config session.session_id
      in
      let has_deferred_event =
        List.exists
          (fun json ->
            Yojson.Safe.Util.(
              json |> member "event_type" |> to_string = "swarm_deferred"))
          events
      in
      Alcotest.(check bool) "swarm deferred event recorded" true
        has_deferred_event

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "Team Session Swarm Runner" [
    "callbacks", [
      Alcotest.test_case "all callbacks present" `Quick
        test_callbacks_all_some;
      Alcotest.test_case "agent done event includes telemetry" `Quick
        test_agent_done_event_includes_telemetry;
    ];
    "apply_swarm_result", [
      Alcotest.test_case "converged result" `Quick
        test_apply_converged_result;
      Alcotest.test_case "exhausted result" `Quick
        test_apply_exhausted_result;
      Alcotest.test_case "partial result" `Quick
        test_apply_partial_result;
      Alcotest.test_case "counts iterations as turns" `Quick
        test_apply_result_counts_iterations_as_turns;
      Alcotest.test_case "all agents failed result" `Quick
        test_apply_all_agents_failed_result;
      Alcotest.test_case "updates stopped_at" `Quick
        test_apply_updates_stopped_at;
    ];
    "session_to_swarm_config", [
      Alcotest.test_case "empty planned workers" `Quick
        test_empty_planned_workers;
      Alcotest.test_case "auto -> decentralized" `Quick
        test_auto_mode_produces_decentralized;
      Alcotest.test_case "manual -> supervisor" `Quick
        test_manual_mode_produces_supervisor;
    ];
    "runner", [
      Alcotest.test_case "empty workers keep session running" `Quick
        test_run_swarm_empty_workers_keeps_session_running;
    ];
  ]
