(** Dashboard proof read-model regression tests. *)

module Lib = Masc_mcp
module U = Yojson.Safe.Util

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_proof" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target

let sample_session ?(min_agents = 2) ?(agent_names = [ "worker-a"; "worker-b" ]) now session_id =
  let open Team_session_types in
  {
    session_id;
    goal = "Prove multi-actor collaboration on MCP help cleanup";
    created_by = "supervisor";
    origin_kind = Origin_human;
    room_id = "default";
    operation_id = None;
    status = Running;
    duration_seconds = 600;
    execution_scope = Limited_code_change;
    checkpoint_interval_sec = 60;
    min_agents;
    scale_profile = Scale_local64;
    control_profile = Control_hierarchical_quality_v1;
    orchestration_mode = Assist;
    communication_mode = Comm_hybrid;
    model_cascade = [ "qwen3.5-35b-a3b-ud-q8-xl" ];
    fallback_policy = Fallback_cascade_then_task;
    instruction_profile = Profile_strict;
    alert_channel = Alert_both;
    auto_resume = false;
    report_formats = [ Markdown; Json ];
    turn_count = 2;
    agent_names;
    planned_workers =
      [
        {
          spawn_agent = "llama";
          runtime_actor = Some "worker-a";
          spawn_role = Some "implementer";
          spawn_model = Some "qwen3.5-35b-a3b-ud-q8-xl";
          execution_scope = Some Limited_code_change;
          worker_class = Some Worker_executor;
          parent_actor = Some "supervisor";
          capsule_mode = Some Capsule_inherit;
          runtime_pool = Some "local64";
          lane_id = Some "lane-proof";
          controller_level = Some Controller_worker;
          control_domain = Some Domain_execution;
          supervisor_actor = Some "supervisor";
          task_profile = Some Profile_synthesize;
          risk_level = Some Risk_medium;
          routing_confidence = Some 0.9;
          routing_reason = Some "worker-a implements proof surface";
          thinking_enabled = None;
          thinking_budget = None;
          max_turns = None;
          timeout_seconds = None;
          routing_escalated = false;
        };
      ];
    broadcast_count = 1;
    portal_count = 0;
    cascade_attempted = 1;
    cascade_success = 1;
    cascade_failed = 0;
    fallback_task_created = 0;
    min_agents_violation_streak = 0;
    policy_violations = [];
    baseline_done_counts = [];
    final_done_delta_total = Some 1;
    final_done_delta_by_agent = Some [ ("worker-a", 1) ];
    delivery_contract = None;
    latest_delivery_verdict = None;
    started_at = now -. 120.0;
    planned_end_at = now +. 480.0;
    stopped_at = None;
    last_checkpoint_at = Some (now -. 30.0);
    last_event_at = Some (now -. 10.0);
    last_turn_at = Some (now -. 15.0);
    stop_reason = None;
    generated_report = true;
    artifacts_dir = Filename.concat ".masc/team-sessions" session_id;
    created_at_iso = Types.now_iso ();
    updated_at_iso = Types.now_iso ();
  }

let seed_session_artifacts ?(session = None) ?events config session_id =
  let now = Unix.gettimeofday () in
  let session = Option.value session ~default:(sample_session now session_id) in
  Lib.Team_session_store.save_session config session;
  let default_events =
    [
      ( "team_step_spawn",
        `Assoc
          [
            ("actor", `String "supervisor");
            ("runtime_actor", `String "worker-a");
            ("spawn_agent", `String "llama");
            ("success", `Bool true);
            ("tool_names", `List [ `String "masc_team_session_step" ]);
            ("title", `String "Spawn proof worker");
          ] );
      ( "team_turn",
        `Assoc
          [
            ("actor", `String "worker-a");
            ("kind", `String "note");
            ("message", `String "Implemented the tool-help projection and validated prompts.");
            ("tool_names", `List [ `String "masc_tool_help"; `String "masc_team_session_prove" ]);
          ] );
      ( "team_turn",
        `Assoc
          [
            ("actor", `String "worker-b");
            ("kind", `String "note");
            ("message", `String "Reviewed the proof evidence and confirmed the actor linkage.");
          ] );
    ]
  in
  let events = Option.value events ~default:default_events in
  List.iter
    (fun (event_type, detail) ->
      Lib.Team_session_store.append_event config session_id ~event_type ~detail)
    events;
  Lib.Team_session_store.write_checkpoint config session_id
    {
      Team_session_types.ts = now -. 25.0;
      ts_iso = Types.now_iso ();
      status = Team_session_types.Running;
      elapsed_sec = 95;
      remaining_sec = 505;
      progress_pct = 16.0;
      done_delta_total = 1;
      done_delta_by_agent = [ ("worker-a", 1) ];
      active_agents = [ "worker-a"; "worker-b" ];
    };
  Lib.Team_session_store.write_text_file
    (Lib.Team_session_store.report_md_path config session_id)
    "# report";
  Room_utils.write_json config
    (Lib.Team_session_store.report_json_path config session_id)
    (`Assoc [ ("ok", `Bool true) ]);
  match Lib.Team_session_report.generate_proof config session with
  | Error msg -> fail msg
  | Ok (proof_json, proof_md) ->
      Room_utils.write_json config
        (Lib.Team_session_store.proof_json_path config session_id)
        proof_json;
      Lib.Team_session_store.write_text_file
        (Lib.Team_session_store.proof_md_path config session_id)
        proof_md

let write_manual_proof config session_id verdict =
  Room_utils.write_json config
    (Lib.Team_session_store.proof_json_path config session_id)
    (`Assoc [ ("verdict", `String verdict) ]);
  Lib.Team_session_store.write_text_file
    (Lib.Team_session_store.proof_md_path config session_id)
    ("# proof\n\nverdict: " ^ verdict)

let seed_worker_run_meta config session_id =
  Lib.Team_session_store.save_worker_run_proof_json config session_id
    "wr-proof-raw"
    (`Assoc
      [
        ("schema_version", `Int 1);
        ("run_id", `String "wr-proof-raw");
        ("contract_id", `String "contract-proof-raw");
        ("requested_execution_mode", `String "execute");
        ("effective_execution_mode", `String "draft");
        ("mode_decision_source", `String "downgraded");
        ("risk_class", `String "high");
        ( "provider_snapshot",
          `Assoc
            [
              ("provider_name", `String "openai_compat");
              ("model_id", `String "qwen3.5-35b-a3b-ud-q8-xl");
              ("api_version", `Null);
            ] );
        ( "capability_snapshot",
          `Assoc
            [
              ("tools", `List [ `String "file_write"; `String "shell_exec" ]);
              ("mcp_servers", `List []);
              ("max_turns", `Int 12);
              ("max_tokens", `Int 4096);
              ("thinking_enabled", `Bool false);
            ] );
        ("tool_trace_refs", `List [ `String "proof-store://wr-proof-raw/tool_traces/trace-1.jsonl" ]);
        ("raw_evidence_refs", `List [ `String "proof-store://wr-proof-raw/evidence/mode_violations.json" ]);
        ("checkpoint_ref", `String "proof-store://wr-proof-raw/checkpoint.json");
        ("result_status", `String "completed");
        ("started_at", `Float 1.0);
        ("ended_at", `Float 2.0);
      ]);
  Lib.Team_session_store.save_worker_run_meta_json config session_id
    "wr-proof-raw"
    (`Assoc
      [
        ("worker_run_id", `String "wr-proof-raw");
        ("worker_name", `String "worker-a");
        ("status", `String "completed");
        ("mode", `String "delegate");
        ("wait_mode", `String "background");
        ("trace_capability", `String "raw");
        ("success", `Bool true);
        ("cdal_run_id", `String "wr-proof-raw");
        ("contract_id", `String "contract-proof-raw");
        ("result_status", `String "completed");
        ("execution_scope", `String "limited_code_change");
        ("requested_worker_class", `String "executor");
        ("requested_worker_size", `String "lg");
        ("tool_surface_status", `String "available");
        ("tool_surface_source", `String "local_worker_tools");
        ( "tool_surface_names",
          `List
            [
              `String "file_read";
              `String "file_write";
              `String "shell_exec";
              `String "masc_status";
              `String "masc_team_session_step";
            ] );
        ( "tool_surface_masc_names",
          `List [ `String "masc_status"; `String "masc_team_session_step" ] );
        ( "tool_surface_shell_names",
          `List [ `String "file_read"; `String "file_write"; `String "shell_exec" ] );
        ("resolved_runtime", `String "llama-primary");
        ("resolved_model", `String "qwen3.5-35b-a3b-ud-q8-xl");
        ("routing_reason", `String "explicit_task_profile");
        ("proof_run_id", `String "proof-run-123");
        ("proof_status", `String "completed");
        ("proof_risk_class", `String "medium");
        ("proof_execution_mode", `String "execute");
        ("proof_evidence_count", `Int 2);
        ("evidence_session_id", `String "oas-session-proof-raw");
        ( "trace_ref",
          `Assoc
            [
              ("worker_run_id", `String "wr-proof-raw");
              ("start_seq", `Int 1);
              ("end_seq", `Int 8);
              ("agent_name", `String "worker-a");
              ("session_id", `String session_id);
            ] );
        ("tool_names", `List [ `String "file_write"; `String "shell_exec" ]);
        ("tool_call_count", `Int 2);
        ("output_preview", `String "Patched calc.py and verification passed.");
        ("validated", `Bool true);
        ( "proof_path",
          `String
            (Lib.Team_session_store.worker_run_proof_path config session_id
               "wr-proof-raw") );
        ("proof_present", `Bool true);
        ("tool_trace_refs", `List [ `String "proof-store://wr-proof-raw/tool_traces/trace-1.jsonl" ]);
        ("raw_evidence_refs", `List [ `String "proof-store://wr-proof-raw/evidence/mode_violations.json" ]);
        ("checkpoint_ref", `String "proof-store://wr-proof-raw/checkpoint.json");
        ("final_text", `String "Patched calc.py and verification passed.");
        ("failure_reason", `Null);
        ( "session_conformance",
          `Assoc
            [
              ("ok", `Bool true);
              ( "checks",
                `List
                  [
                    `Assoc
                      [
                        ("code", `String "proof_bundle_available");
                        ("name", `String "proof bundle available");
                        ("passed", `Bool true);
                        ("detail", `Null);
                      ];
                  ] );
            ] );
        ( "trace_summary",
          `Assoc
            [
              ("record_count", `Int 8);
              ("assistant_block_count", `Int 3);
              ("tool_execution_started_count", `Int 2);
              ("tool_execution_finished_count", `Int 2);
              ("tool_names", `List [ `String "file_write"; `String "shell_exec" ]);
              ("final_text", `String "Patched calc.py and verification passed.");
              ("stop_reason", `String "end_turn");
              ("error", `Null);
            ] );
        ( "trace_validation",
          `Assoc
            [
              ("ok", `Bool true);
              ( "checks",
                `List
                  [
                    `Assoc [ ("name", `String "seq_monotonic"); ("passed", `Bool true) ];
                    `Assoc [ ("name", `String "run_started"); ("passed", `Bool true) ];
                  ] );
              ("evidence", `List [ `String "record_count=8" ]);
            ] );
      ])

let seed_raw_only_worker_run_meta config session_id =
  Lib.Team_session_store.save_worker_run_meta_json config session_id
    "wr-raw-only"
    (`Assoc
      [
        ("worker_run_id", `String "wr-raw-only");
        ("worker_name", `String "worker-raw");
        ("status", `String "completed");
        ("mode", `String "swarm");
        ("wait_mode", `String "background");
        ("trace_capability", `String "raw");
        ("success", `Bool true);
        ("evidence_session_id", `String "oas-session-raw-only");
        ( "trace_ref",
          `Assoc
            [
              ("worker_run_id", `String "wr-raw-only");
              ("start_seq", `Int 1);
              ("end_seq", `Int 4);
              ("agent_name", `String "worker-raw");
              ("session_id", `String session_id);
            ] );
        ("proof_present", `Bool false);
        ("proof_run_id", `Null);
        ("proof_status", `Null);
        ("proof_risk_class", `Null);
        ("proof_execution_mode", `Null);
        ("proof_evidence_count", `Null);
        ("resolved_runtime", `String "oas_swarm");
        ("resolved_model", `String "glm:auto");
        ("output_preview", `String "Raw trace completed without proof.");
        ( "trace_ref",
          `Assoc
            [
              ("worker_run_id", `String "wr-raw-only");
              ("start_seq", `Int 1);
              ("end_seq", `Int 4);
              ("agent_name", `String "worker-raw");
              ("session_id", `String session_id);
            ] );
        ("trace_summary", `Null);
        ("trace_validation", `Null);
        ("tool_surface_status", `String "available");
        ("tool_surface_source", `String "swarm_masc_tools");
        ("tool_surface_names", `List [ `String "masc_status" ]);
        ("tool_surface_masc_names", `List [ `String "masc_status" ]);
        ("tool_surface_shell_names", `List []);
        ("ts_iso", `String "2026-04-08T00:00:00Z");
      ])

let test_dashboard_proof_projection () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-fixture-001" in
      seed_session_artifacts config session_id;
      let json = Lib.Dashboard_proof.json ~config () in
      check string "verdict requires validated worker evidence" "partial"
        (json |> U.member "proof_verdict" |> U.to_string);
      check string "live verdict remains partial without validated worker run"
        "partial"
        (json |> U.member "summary" |> U.member "live_verdict" |> U.to_string);
      check int "validated worker run count absent" 0
        (json |> U.member "summary" |> U.member "validated_worker_run_count"
       |> U.to_int);
      check string "session id" session_id
        (json |> U.member "session_id" |> U.to_string);
      check string "selection mode" "latest_auto_selected"
        (json |> U.member "selection" |> U.member "mode" |> U.to_string);
      check string "namespace id" "default"
        (json |> U.member "namespace" |> U.member "namespace_id" |> U.to_string);
      check string "namespace name" "default"
        (json |> U.member "namespace" |> U.member "namespace" |> U.to_string);
      check string "namespace current_namespace" "default"
        (json |> U.member "namespace" |> U.member "current_namespace" |> U.to_string);
      check string "namespace mode" "flattened"
        (json |> U.member "namespace" |> U.member "namespace_mode" |> U.to_string);
      check string "legacy room alias keeps namespace id" "default"
        (json |> U.member "room" |> U.member "namespace_id" |> U.to_string);
      check string "legacy room alias keeps current_namespace" "default"
        (json |> U.member "room" |> U.member "current_namespace" |> U.to_string);
      check string "legacy room alias keeps current_room" "default"
        (json |> U.member "room" |> U.member "current_room" |> U.to_string);
      check bool "timeline present" true
        ((json |> U.member "timeline" |> U.to_list) <> []);
      check bool "actor contributions present" true
        ((json |> U.member "actor_contributions" |> U.to_list) <> []);
      check bool "tool evidence present" true
        ((json |> U.member "tool_evidence" |> U.to_list) <> []);
      check bool "artifacts present" true
        ((json |> U.member "artifacts" |> U.to_list) <> []);
      check bool "cp backing present" true
        (json |> U.member "cp_backing_evidence" <> `Null))

let test_dashboard_proof_exposes_validated_worker_run_evidence () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-worker-runs" in
      seed_session_artifacts config session_id;
      seed_worker_run_meta config session_id;
      let json = Lib.Dashboard_proof.json ~config ~session_id () in
      check int "raw trace run count" 1
        (json |> U.member "summary" |> U.member "raw_trace_run_count" |> U.to_int);
      check int "validated worker run count" 1
        (json |> U.member "summary" |> U.member "validated_worker_run_count" |> U.to_int);
      let worker_proofs = json |> U.member "worker_proof_evidence" |> U.to_list in
      check int "worker proof evidence count" 1 (List.length worker_proofs);
      let worker_proof = List.hd worker_proofs in
      check string "worker proof run id" "wr-proof-raw"
        (worker_proof |> U.member "cdal_run_id" |> U.to_string);
      check string "worker proof contract id" "contract-proof-raw"
        (worker_proof |> U.member "contract_id" |> U.to_string);
      check bool "worker proof present" true
        (worker_proof |> U.member "proof_present" |> U.to_bool);
      let worker_runs = json |> U.member "worker_run_evidence" |> U.to_list in
      check int "worker run evidence count" 1 (List.length worker_runs);
      let worker = List.hd worker_runs in
      check string "worker session id" session_id
        (worker |> U.member "session_id" |> U.to_string);
      check string "worker run capability" "raw"
        (worker |> U.member "trace_capability" |> U.to_string);
      check bool "worker run validated" true
        (worker |> U.member "trace_validated" |> U.to_bool);
      check string "worker resolved runtime" "llama-primary"
        (worker |> U.member "resolved_runtime" |> U.to_string);
      check string "worker resolved model" "qwen3.5-35b-a3b-ud-q8-xl"
        (worker |> U.member "resolved_model" |> U.to_string);
      check string "worker tool surface status" "available"
        (worker |> U.member "tool_surface_status" |> U.to_string);
      check int "worker tool surface count" 5
        (worker |> U.member "tool_surface_count" |> U.to_int);
      check (list string) "worker tool surface names"
        [ "file_read"; "file_write"; "shell_exec"; "masc_status"; "masc_team_session_step" ]
        (worker |> U.member "tool_surface_names" |> U.to_list
       |> List.map U.to_string);
      check string "worker result_status" "completed"
        (worker |> U.member "result_status" |> U.to_string);
      check string "worker proof run id" "proof-run-123"
        (worker |> U.member "proof_run_id" |> U.to_string);
      check string "worker proof status" "completed"
        (worker |> U.member "proof_status" |> U.to_string);
      check string "worker proof risk class" "medium"
        (worker |> U.member "proof_risk_class" |> U.to_string);
      check string "worker proof execution mode" "execute"
        (worker |> U.member "proof_execution_mode" |> U.to_string);
      check int "worker proof evidence count" 2
        (worker |> U.member "proof_evidence_count" |> U.to_int);
      check string "worker evidence session id" "oas-session-proof-raw"
        (worker |> U.member "evidence_session_id" |> U.to_string);
      check string "worker trace ref run id" "wr-proof-raw"
        (worker |> U.member "trace_ref" |> U.member "worker_run_id"
       |> U.to_string);
      check string "worker final text" "Patched calc.py and verification passed."
        (worker |> U.member "final_text" |> U.to_string);
      check bool "worker proof path hidden" true
        (worker |> U.member "proof_path" = `Null);
      check bool "worker proof evidence path hidden" true
        ((worker_proof |> U.member "proof_path") = `Null);
      check bool "worker proof evidence meta path hidden" true
        ((worker_proof |> U.member "meta_path") = `Null))

let test_dashboard_proof_exposes_raw_only_worker_run_evidence () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-raw-only-worker-run" in
      seed_session_artifacts config session_id;
      seed_raw_only_worker_run_meta config session_id;
      let json = Lib.Dashboard_proof.json ~config ~session_id () in
      check int "raw trace run count" 1
        (json |> U.member "summary" |> U.member "raw_trace_run_count" |> U.to_int);
      let worker_proofs = json |> U.member "worker_proof_evidence" |> U.to_list in
      check int "worker proof evidence absent without proof" 0
        (List.length worker_proofs);
      let worker_runs = json |> U.member "worker_run_evidence" |> U.to_list in
      check int "worker run evidence count" 1 (List.length worker_runs);
      let worker = List.hd worker_runs in
      check string "worker run id" "wr-raw-only"
        (worker |> U.member "worker_run_id" |> U.to_string);
      check string "raw-only evidence session id" "oas-session-raw-only"
        (worker |> U.member "evidence_session_id" |> U.to_string);
      check string "output preview surfaced" "Raw trace completed without proof."
        (worker |> U.member "output_preview" |> U.to_string);
      check bool "proof_present false preserved" false
        (worker |> U.member "proof_present" |> U.to_bool);
      check bool "proof run id omitted in summary" true
        (worker |> U.member "proof_run_id" = `Null))

let test_dashboard_proof_http_cache_isolation_by_selection () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let session_a = "ts-proof-cache-a" in
      let session_b = "ts-proof-cache-b" in
      Eio_main.run @@ fun env ->
      Eio_guard.enable ();
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      seed_session_artifacts config session_a;
      seed_session_artifacts config session_b;
      Lib.Dashboard_cache.invalidate_all ();
      let state =
        Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir ()
      in
      let json_a =
        Lib.Server_dashboard_http.dashboard_proof_http_json
          ~state
          (request
             "/api/v1/dashboard/proof?session_id=ts-proof-cache-a&operation_id=op-cache-a")
      in
      let json_b =
        Lib.Server_dashboard_http.dashboard_proof_http_json
          ~state
          (request
             "/api/v1/dashboard/proof?session_id=ts-proof-cache-b&operation_id=op-cache-b")
      in
      let open Yojson.Safe.Util in
      check string "first selection keeps session a" session_a
        (json_a |> member "session_id" |> to_string);
      check string "first selection keeps operation a" "op-cache-a"
        (json_a |> member "operation_id" |> to_string);
      check string "second selection keeps session b" session_b
        (json_b |> member "session_id" |> to_string);
      check string "second selection keeps operation b" "op-cache-b"
        (json_b |> member "operation_id" |> to_string))

let test_dashboard_proof_http_cache_invalidates_on_worker_run_write () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let session_id = "ts-proof-cache-refresh" in
      Eio_main.run @@ fun env ->
      Eio_guard.enable ();
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      seed_session_artifacts config session_id;
      Lib.Dashboard_cache.invalidate_all ();
      let state =
        Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir ()
      in
      let proof_request =
        request ("/api/v1/dashboard/proof?session_id=" ^ session_id)
      in
      let json_before =
        Lib.Server_dashboard_http.dashboard_proof_http_json ~state
          proof_request
      in
      check int "initial worker run evidence empty" 0
        (json_before |> U.member "worker_run_evidence" |> U.to_list
        |> List.length);
      seed_raw_only_worker_run_meta config session_id;
      let json_after =
        Lib.Server_dashboard_http.dashboard_proof_http_json ~state
          proof_request
      in
      check int "worker run evidence refreshed after write" 1
        (json_after |> U.member "worker_run_evidence" |> U.to_list
        |> List.length))

let test_dashboard_proof_prefers_attached_session_operation_id () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-linked-operation" in
      let session =
        {
          (sample_session (Unix.gettimeofday ()) session_id) with
          operation_id = Some "op-proof-linked";
        }
      in
      seed_session_artifacts ~session:(Some session) config session_id;
      let cp_event : Lib.Command_plane_v2.event_record =
        {
          event_id = Lib.Command_plane_v2.next_event_id "trace";
          trace_id = "trace-proof-linked";
          event_type = "operation_progress";
          operation_id = Some "op-proof-linked";
          unit_id = None;
          actor = Some "cp-agent";
          source = "managed";
          ts = "2026-03-11T09:00:01Z";
          detail = `Assoc [ ("message", `String "linked cp event") ];
        }
      in
      Lib.Command_plane_v2.append_event config cp_event;
      let json = Lib.Dashboard_proof.json ~config ~session_id () in
      check string "selected operation id" "op-proof-linked"
        (json |> U.member "selection" |> U.member "selected_operation_id"
       |> U.to_string);
      check string "goal binding operation id" "op-proof-linked"
        (json |> U.member "goal_binding" |> U.member "operation_id"
       |> U.to_string);
      let timeline = json |> U.member "timeline" |> U.to_list in
      check bool "linked cp event included" true
        (List.exists (fun item ->
             item |> U.member "source" |> U.to_string = "command_plane"
             && item |> U.member "operation_id" |> U.to_string
                = "op-proof-linked") timeline))

let test_team_session_proof_projects_worker_proof_metadata () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-worker-projection" in
      let session = sample_session (Unix.gettimeofday ()) session_id in
      seed_session_artifacts ~session:(Some session) config session_id;
      seed_worker_run_meta config session_id;
      match Lib.Team_session_report.generate_proof config session with
      | Error msg -> fail msg
      | Ok (proof_json, _) ->
          let integration =
            proof_json |> U.member "oas_cdal_integration"
          in
          check int "worker_proof_count" 1
            (integration |> U.member "worker_proof_count" |> U.to_int);
          check bool "proof_projected" true
            (integration |> U.member "proof_projected" |> U.to_bool))

let test_timeline_json_orders_command_plane_events_by_timestamp () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-fixture-ordered" in
      seed_session_artifacts config session_id;
      let cp_event : Lib.Command_plane_v2.event_record =
        {
          event_id = Lib.Command_plane_v2.next_event_id "trace";
          trace_id = "trace-proof-order";
          event_type = "operation_progress";
          operation_id = Some ("detachment-" ^ session_id);
          unit_id = None;
          actor = Some "cp-agent";
          source = "managed";
          ts = "2026-03-11T09:00:01Z";
          detail = `Assoc [ ("message", `String "early cp event") ];
        }
      in
      Lib.Command_plane_v2.append_event config cp_event;
      let timeline =
        Lib.Dashboard_proof.json ~config ~session_id ()
        |> U.member "timeline"
        |> U.to_list
      in
      let first = List.hd timeline in
      check string "first item source" "command_plane"
        (first |> U.member "source" |> U.to_string);
      check string "first item timestamp" "2026-03-11T09:00:01Z"
        (first |> U.member "timestamp" |> U.to_string))

let test_dashboard_proof_prefers_actual_activity_over_stronger_persisted_verdict ()
    =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-persisted-verdict" in
      let session =
        sample_session ~min_agents:1
          ~agent_names:[ "opus-leader-witty-heron"; "codex-warm-heron"; "keeper-a"; "keeper-b" ]
          (Unix.gettimeofday ()) session_id
      in
      seed_session_artifacts ~session:(Some session)
        ~events:
          [
            ( "team_turn",
              `Assoc
                [
                  ("actor", `String "opus-leader-witty-heron");
                  ("kind", `String "note");
                  ( "message",
                    `String
                      "Task decomposition: schema first, then tests and docs in parallel." );
                ] );
            ( "team_turn",
              `Assoc
                [
                  ("actor", `String "opus-leader-witty-heron");
                  ("kind", `String "task");
                  ("result", `String "Added task-016: API schema design complete");
                ] );
          ]
        config session_id;
      write_manual_proof config session_id "proved";
      let json = Lib.Dashboard_proof.json ~config ~session_id () in
      check string "top-level verdict follows actual activity" "partial"
        (json |> U.member "proof_verdict" |> U.to_string);
      check string "live verdict" "partial"
        (json |> U.member "summary" |> U.member "live_verdict" |> U.to_string);
      check string "historical verdict" "proven"
        (json |> U.member "summary" |> U.member "historical_verdict"
       |> U.to_string);
      check string "verdict basis remains live" "live"
        (json |> U.member "summary" |> U.member "verdict_basis" |> U.to_string);
      check int "only one active actor counted" 1
        (json |> U.member "summary" |> U.member "actors_count" |> U.to_int);
      check int "planned actors kept separate" 6
        (json |> U.member "summary" |> U.member "planned_actor_count" |> U.to_int);
      check string "raw proof still exposes original verdict spelling" "proved"
        (json |> U.member "raw_proof" |> U.member "verdict" |> U.to_string))

let test_dashboard_proof_marks_mentioned_only_actor_as_unanswered () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-mentioned-only" in
      let session =
        sample_session ~agent_names:[ "worker-a"; "worker-b" ]
          (Unix.gettimeofday ()) session_id
      in
      seed_session_artifacts ~session:(Some session)
        ~events:
          [
            ( "team_turn",
              `Assoc
                [
                  ("actor", `String "supervisor");
                  ("kind", `String "broadcast");
                  ("message", `String "@worker-b review the proof output and reply here.");
                ] );
            ( "team_turn",
              `Assoc
                [
                  ("actor", `String "worker-a");
                  ("kind", `String "note");
                  ("message", `String "Updated the proof dashboard copy.");
                  ("tool_names", `List [ `String "masc_tool_help" ]);
                ] );
          ]
        config session_id;
      let json = Lib.Dashboard_proof.json ~config ~session_id () in
      check string "selection mode" "explicit"
        (json |> U.member "selection" |> U.member "mode" |> U.to_string);
      check int "active actors" 2
        (json |> U.member "summary" |> U.member "actors_count" |> U.to_int);
      check int "unanswered actors" 1
        (json |> U.member "summary" |> U.member "unanswered_actor_count"
       |> U.to_int);
      let worker_b =
        json |> U.member "actor_contributions" |> U.to_list
        |> List.find (fun row ->
               String.equal "worker-b" (row |> U.member "actor" |> U.to_string))
      in
      check string "mentioned-only state" "mentioned_only"
        (worker_b |> U.member "activity_state" |> U.to_string);
      check string "request source" "supervisor"
        (worker_b |> U.member "requested_by" |> U.to_string))

let test_dashboard_proof_ignores_unknown_mentions_outside_session () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-ignore-unknown-mentions" in
      let session =
        sample_session ~agent_names:[ "worker-a"; "worker-b" ]
          (Unix.gettimeofday ()) session_id
      in
      seed_session_artifacts ~session:(Some session)
        ~events:
          [
            ( "team_turn",
              `Assoc
                [
                  ("actor", `String "supervisor");
                  ("kind", `String "broadcast");
                  ( "message",
                    `String
                      "@worker-b review this proof, and @external-bot can ignore it." );
                ] );
            ( "team_turn",
              `Assoc
                [
                  ("actor", `String "worker-a");
                  ("kind", `String "note");
                  ("message", `String "Adjusted the proof summary copy.");
                ] );
          ]
        config session_id;
      let json = Lib.Dashboard_proof.json ~config ~session_id () in
      check int "only known mention counted" 1
        (json |> U.member "summary" |> U.member "mentioned_actor_count"
       |> U.to_int);
      check bool "unknown mention not promoted to actor" false
        (json |> U.member "actor_contributions" |> U.to_list
       |> List.exists (fun row ->
              String.equal "external-bot" (row |> U.member "actor" |> U.to_string))))

let test_dashboard_proof_uses_historical_verdict_when_live_is_empty () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-historical-only" in
      let session = sample_session ~agent_names:[ "worker-a"; "worker-b" ]
          (Unix.gettimeofday ()) session_id in
      Lib.Team_session_store.save_session config session;
      write_manual_proof config session_id "proved";
      let json = Lib.Dashboard_proof.json ~config ~session_id () in
      check string "historical-only final verdict is partial" "partial"
        (json |> U.member "proof_verdict" |> U.to_string);
      check string "live verdict is insufficient" "insufficient"
        (json |> U.member "summary" |> U.member "live_verdict" |> U.to_string);
      check string "historical verdict is proven" "proven"
        (json |> U.member "summary" |> U.member "historical_verdict"
       |> U.to_string);
      check string "basis is historical_only" "historical_only"
        (json |> U.member "summary" |> U.member "verdict_basis"
       |> U.to_string))

let () =
  Alcotest.run "dashboard_proof"
    [
      ( "projection",
        [
          test_case "builds collaboration proof projection" `Quick test_dashboard_proof_projection;
          test_case "exposes validated worker run evidence" `Quick
            test_dashboard_proof_exposes_validated_worker_run_evidence;
          test_case "exposes raw-only worker run evidence" `Quick
            test_dashboard_proof_exposes_raw_only_worker_run_evidence;
          test_case "http cache isolates proof selections" `Quick
            test_dashboard_proof_http_cache_isolation_by_selection;
          test_case "http cache refreshes after worker run write" `Quick
            test_dashboard_proof_http_cache_invalidates_on_worker_run_write;
          test_case "prefers attached session operation id" `Quick
            test_dashboard_proof_prefers_attached_session_operation_id;
          test_case "projects worker proof metadata into session proof" `Quick
            test_team_session_proof_projects_worker_proof_metadata;
          test_case "orders merged timeline chronologically" `Quick
            test_timeline_json_orders_command_plane_events_by_timestamp;
          test_case "prefers actual activity over stronger persisted proof" `Quick
            test_dashboard_proof_prefers_actual_activity_over_stronger_persisted_verdict;
          test_case "marks mentioned-only actor as unanswered" `Quick
            test_dashboard_proof_marks_mentioned_only_actor_as_unanswered;
          test_case "ignores unknown mentions outside session" `Quick
            test_dashboard_proof_ignores_unknown_mentions_outside_session;
          test_case "uses historical verdict when live is empty" `Quick
            test_dashboard_proof_uses_historical_verdict_when_live_is_empty;
        ] );
    ]
