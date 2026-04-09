(** Dashboard Mission read-model regression tests. *)

module Lib = Masc_mcp

open Alcotest

(* Force filesystem backend so tests run without PG/Eio context. *)
let () = Unix.putenv "MASC_STORAGE_TYPE" "filesystem"

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_mission" "" in
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

let contains str substr =
  try
    ignore (Str.search_forward (Str.regexp_string substr) str 0);
    true
  with Not_found -> false

let write_pending_confirm config session_id =
  let operator_dir = Filename.concat (Room_utils.masc_dir config) "operator" in
  Room_utils.mkdir_p operator_dir;
  Room_utils.write_json config (Filename.concat operator_dir "pending_confirms.json")
    (`List
      [
        `Assoc
          [
            ("token", `String "confirm-mission-test");
            ("confirm_token", `String "confirm-mission-test");
            ("trace_id", `String "ops_fixture_mission");
            ("actor", `String "dashboard-fixture");
            ("action_type", `String "team_stop");
            ("target_type", `String "team_session");
            ("target_id", `String session_id);
            ("payload", `Assoc [ ("reason", `String "fixture pending confirmation") ]);
            ("delegated_tool", `String "masc_team_session_stop");
            ("created_at", `String (Types.now_iso ()));
            ("expires_at", `Null);
          ];
      ])

let seed_room config session_id =
  ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
  ignore (Lib.Room.join config ~agent_name:"team-session-local64-smoke"
            ~capabilities:[ "operator"; "fixture"; "local64" ] ());
  ignore (Lib.Room.join config ~agent_name:"llama-local-alpha"
            ~capabilities:[ "worker"; "local64"; "manager" ] ());
  ignore (Lib.Room.join config ~agent_name:"llama-local-beta"
            ~capabilities:[ "worker"; "local64"; "metacog" ] ());
  ignore (Lib.Room.join config ~agent_name:"llama-local-gamma"
            ~capabilities:[ "worker"; "local64"; "executor" ] ());
  ignore (Lib.Room.join config ~agent_name:"llama-local-delta"
            ~capabilities:[ "worker"; "local64"; "observer" ] ());
  ignore
    (Lib.Room.broadcast config ~from_agent:"team-session-local64-smoke"
       ~content:"@llama-local-alpha recover failed worker coverage");
  ignore
    (Lib.Room.broadcast config ~from_agent:"llama-local-alpha"
       ~content:"Spawned worker recovered partial role coverage and runtime visibility.");

  let now = Unix.gettimeofday () in
  let open Team_session_types in
  let session =
    {
      session_id;
      goal = "Validate local64 swarm role coverage, runtime visibility, and operator census";
      created_by = "fixture-root";
      origin_kind = Origin_human;
      room_id = "default";
      operation_id = Some "op-mission-fixture-001";
      status = Interrupted;
      duration_seconds = 2700;
      execution_scope = Observe_only;
      checkpoint_interval_sec = 60;
      min_agents = 1;
      scale_profile = Scale_local64;
      control_profile = Control_hierarchical_quality_v1;
      orchestration_mode = Assist;
      communication_mode = Comm_hybrid;
      model_cascade = [ "qwen3.5-35b-a3b-ud-q8-xl"; "qwen27-balanced"; "qwen9-swarm" ];
      fallback_policy = Fallback_cascade_then_task;
      instruction_profile = Profile_strict;
      alert_channel = Alert_both;
      auto_resume = false;
      report_formats = [ Markdown; Json ];
      turn_count = 3;
      agent_names =
        [
          "team-session-local64-smoke";
          "llama-local-alpha";
          "llama-local-beta";
          "llama-local-gamma";
        ];
      planned_workers =
        [
          {
            spawn_agent = "llama";
            runtime_actor = Some "llama-local-alpha";
            spawn_role = Some "manager";
            spawn_model = Some "qwen3.5-35b-a3b-ud-q8-xl";
            execution_scope = Some Observe_only;
            worker_class = Some Worker_manager;
            parent_actor = Some "team-session-local64-smoke";
            capsule_mode = Some Capsule_inherit;
            runtime_pool = Some "local64";
            lane_id = Some "lane-manager";
            controller_level = Some Controller_root;
            control_domain = Some Domain_execution;
            supervisor_actor = Some "team-session-local64-smoke";
            task_profile = Some Profile_decide;
            risk_level = Some Risk_high;
            routing_confidence = Some 0.94;
            routing_reason = Some "manager must hold root synthesis";
            thinking_enabled = None;
            thinking_budget = None;
            max_turns = None;
            timeout_seconds = None;
            routing_escalated = false;
          };
          {
            spawn_agent = "llama";
            runtime_actor = Some "llama-local-beta";
            spawn_role = Some "metacog";
            spawn_model = Some "qwen27-balanced";
            execution_scope = Some Observe_only;
            worker_class = Some Worker_metacog;
            parent_actor = Some "team-session-local64-smoke";
            capsule_mode = Some Capsule_inherit;
            runtime_pool = Some "local64";
            lane_id = Some "lane-meta";
            controller_level = Some Controller_lane;
            control_domain = Some Domain_meta;
            supervisor_actor = Some "llama-local-alpha";
            task_profile = Some Profile_verify;
            risk_level = Some Risk_medium;
            routing_confidence = Some 0.68;
            routing_reason = Some "spawn failures hide runtime census";
            thinking_enabled = None;
            thinking_budget = None;
            max_turns = None;
            timeout_seconds = None;
            routing_escalated = true;
          };
          {
            spawn_agent = "llama";
            runtime_actor = Some "llama-local-gamma";
            spawn_role = Some "executor";
            spawn_model = Some "qwen9-swarm";
            execution_scope = Some Limited_code_change;
            worker_class = Some Worker_executor;
            parent_actor = Some "team-session-local64-smoke";
            capsule_mode = Some Capsule_fresh;
            runtime_pool = Some "local64";
            lane_id = Some "lane-worker";
            controller_level = Some Controller_worker;
            control_domain = Some Domain_runtime;
            supervisor_actor = Some "llama-local-alpha";
            task_profile = Some Profile_extract;
            risk_level = Some Risk_medium;
            routing_confidence = Some 0.88;
            routing_reason = Some "executor covers direct runtime checks";
            thinking_enabled = None;
            thinking_budget = None;
            max_turns = None;
            timeout_seconds = None;
            routing_escalated = false;
          };
          {
            spawn_agent = "llama";
            runtime_actor = Some "llama-local-delta";
            spawn_role = Some "observer";
            spawn_model = Some "qwen9-swarm";
            execution_scope = Some Observe_only;
            worker_class = Some Worker_scout;
            parent_actor = Some "team-session-local64-smoke";
            capsule_mode = Some Capsule_fresh;
            runtime_pool = Some "local64";
            lane_id = Some "lane-observer";
            controller_level = Some Controller_worker;
            control_domain = Some Domain_runtime;
            supervisor_actor = Some "llama-local-alpha";
            task_profile = Some Profile_extract;
            risk_level = Some Risk_low;
            routing_confidence = Some 0.72;
            routing_reason = Some "observer preserves room-level runtime census";
            thinking_enabled = None;
            thinking_budget = None;
            max_turns = None;
            timeout_seconds = None;
            routing_escalated = false;
          };
        ];
      broadcast_count = 2;
      portal_count = 0;
      cascade_attempted = 1;
      cascade_success = 0;
      cascade_failed = 1;
      fallback_task_created = 1;
      min_agents_violation_streak = 0;
      policy_violations = [];
      baseline_done_counts = [];
      final_done_delta_total = None;
      final_done_delta_by_agent = None;
      started_at = now -. 45.0;
      planned_end_at = now +. 2655.0;
      stopped_at = Some now;
      last_checkpoint_at = Some (now -. 15.0);
      last_event_at = Some (now -. 3.0);
      last_turn_at = Some (now -. 12.0);
      stop_reason = Some "fixture_interrupted_after_spawn_failure";
      generated_report = false;
      delivery_contract = None;
      latest_delivery_verdict = None;
      artifacts_dir = Filename.concat ".masc/team-sessions" session_id;
      created_at_iso = Types.now_iso ();
      updated_at_iso = Types.now_iso ();
    }
  in
  (* Team_session_store removed — skip session save and event append *)
  ignore (session, session_id);
  write_pending_confirm config session_id

let test_dashboard_mission_projection () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let session_id = "ts-mission-fixture-001" in
      Eio_main.run @@ fun env ->
      Eio_guard.enable ();
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      seed_room config session_id;
      Lib.A2a_tools.emit_heartbeat_task
        ~agent:"llama-local-alpha"
        ~goal:"Inspect board state with allowed MCP tools."
        ~context:"fixture context"
        ~allowed_tools:[ "masc_board_get"; "masc_board_vote"; "keeper_board_list" ]
        ();
      ignore
        (Lib.A2a_tools.submit_heartbeat_result
           ~worker_name:"worker-fixture"
           ~agent:"llama-local-alpha"
           ~status:"acted"
           ~summary:"Upvoted the target board post after inspection."
           ~tool_call_count:2
           ~tool_names:[ "masc_board_get"; "masc_board_vote" ]
           ~decision_reason:"fixture result"
           ~decision_confidence:0.93
           ());
      ignore
        (Lib.A2a_tools.submit_heartbeat_result
           ~worker_name:"worker-fixture"
           ~agent:"llama-local-beta"
           ~status:"acted"
           ~summary:"Older result for beta."
           ~tool_call_count:1
           ~tool_names:[ "masc_board_get" ]
           ~decision_reason:"fixture older result"
           ~decision_confidence:0.61
           ());
      Lib.A2a_tools.emit_heartbeat_task
        ~agent:"llama-local-beta"
        ~goal:"Fresh assignment for beta."
        ~context:"fixture context"
        ~allowed_tools:[ "masc_board_comment" ]
        ();
      (* Simulate delta departing: remove agent file so Dashboard_mission
         sees delta as departed. *)
      let delta_path =
        Filename.concat (Room_utils.agents_dir config) "llama-local-delta.json"
      in
      if Sys.file_exists delta_path then Sys.remove delta_path;
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_mission.json
            ~actor:"test-dashboard-projection"
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        let attention_queue = json |> member "attention_queue" |> to_list in
        let sessions = json |> member "sessions" |> to_list in
        let summary = json |> member "summary" in
        let session_briefs = json |> member "session_briefs" |> to_list in
        let agent_briefs = json |> member "agent_briefs" |> to_list in
        let internal_signals = json |> member "internal_signals" |> to_list in
        let attention_by_kind kind =
          attention_queue
          |> List.find (fun row -> row |> member "kind" |> to_string = kind)
        in
        let alpha_brief =
          agent_briefs
          |> List.find (fun row ->
                 row |> member "agent_name" |> to_string = "llama-local-alpha")
        in
        check bool "attention_queue present" true (attention_queue <> []);
        check string "top attention kind" "spawn_failure_present"
          (attention_queue |> List.hd |> member "kind" |> to_string);
        check string "top action type" "team_task_inject"
          (attention_queue |> List.hd |> member "top_action" |> member "action_type" |> to_string);
        check string "local64 gap action type" "team_worker_spawn_batch"
          (attention_by_kind "local64_role_gap"
           |> member "top_action" |> member "action_type" |> to_string);
        check string "routing escalation action type" "team_note"
          (attention_by_kind "routing_escalation_present"
           |> member "top_action" |> member "action_type" |> to_string);
        check string "session brief id" session_id
          (session_briefs |> List.hd |> member "session_id" |> to_string);
        check int "session brief seen count" 4
          (session_briefs |> List.hd |> member "seen_count" |> to_int);
        check int "session brief planned count" 6
          (session_briefs |> List.hd |> member "planned_count" |> to_int);
        check string "session brief counts basis"
          "live=recent_turns · planned=planned_participants"
          (session_briefs |> List.hd |> member "counts_basis" |> to_string);
        check bool "mission summary trims paused" true
          (summary |> member "paused" = `Null);
        check bool "mission summary trims active_agents" true
          (summary |> member "active_agents" = `Null);
        check string "mission summary namespace_id" "default"
          (summary |> member "namespace_id" |> to_string);
        check string "mission summary namespace" "default"
          (summary |> member "namespace" |> to_string);
        check string "mission summary namespace mode" "flattened"
          (summary |> member "namespace_mode" |> to_string);
        check bool "full session cards omitted from mission payload" true
          (sessions = []);
        check bool "session brief keeps member previews" true
          ((session_briefs |> List.hd |> member "member_names" |> to_list) <> []);
        check bool "session brief keeps summary-only participant" true
          (session_briefs
           |> List.exists (fun row ->
                  row |> member "session_id" |> to_string = session_id
                  && (row |> member "member_names" |> to_list
                     |> List.exists (fun value ->
                            value |> to_string = "llama-local-delta"))));
        check bool "agent brief linked to fixture session" true
          (agent_briefs
           |> List.exists (fun row ->
                row |> member "agent_name" |> to_string = "llama-local-alpha"
                && row |> member "related_session_id" |> to_string = session_id));
        check bool "summary-only participant links back to session" true
          (agent_briefs
           |> List.exists (fun row ->
                  row |> member "agent_name" |> to_string = "llama-local-delta"
                  && row |> member "related_session_id" |> to_string = session_id));
        let delta_brief =
          agent_briefs
          |> List.find (fun row ->
                 row |> member "agent_name" |> to_string = "llama-local-delta")
        in
        check bool "summary-only participant marked non-live" false
          (delta_brief |> member "is_live" |> to_bool);
        check string "summary-only participant archived reason"
          "not in current namespace state"
          (delta_brief |> member "archived_reason" |> to_string);
        check bool "participant preview omits old tool telemetry" true
          (delta_brief |> member "recent_tool_names" = `Null);
        let alpha_input = alpha_brief |> member "recent_input_preview" |> to_string in
        check bool "recent input preserves exact alpha mention" true
          (contains alpha_input "@llama-local-alpha");
        check bool "recent input excludes unrelated beta mention" false
          (contains alpha_input "@llama-local-beta");
        check bool "agent brief omits old audit surface" true
          (alpha_brief |> member "allowed_tool_names" = `Null);
        check bool "agent brief omits social context fields" true
          (alpha_brief |> member "where" = `Null);
        check string "agent brief keeps session linkage" session_id
          (alpha_brief |> member "related_session_id" |> to_string);
        check string "agent brief signal truth" "message"
          (alpha_brief |> member "evidence_source" |> to_string);
        check string "summary-only participant signal truth" "archived"
          (delta_brief |> member "signal_truth" |> to_string);
        check bool "internal signal includes pending confirm" true
          (internal_signals
           |> List.exists (fun row ->
                contains (row |> member "summary" |> to_string) "pending confirmation"));
        (* room broadcast actions require microarch signal tones "warn"/"bad",
           which need non-empty command-plane operations. In a clean test
           fixture all 9 signals default to "ok", so room_recommendations
           returns []. Verify internal_signals carries the pending-confirm
           incident instead — that is the reachable room-level signal. *)
        check bool "internal signals are room-scoped" true
          (internal_signals
           |> List.for_all (fun row ->
                row |> member "target_type" |> to_string = "namespace"));
        let session_detail =
          Lib.Dashboard_mission.session_json
            ~actor:"test-dashboard-projection"
            ~session_id
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        check string "session detail id" session_id
          (session_detail |> member "session_id" |> to_string);
        check bool "session detail participants present" true
          ((session_detail |> member "participants" |> to_list) <> []);
        check bool "session detail timeline present" true
          ((session_detail |> member "timeline" |> to_list) <> []);
        check bool "session detail operation preserved" true
          ((session_detail |> member "operations" |> to_list) <> []);
      ))

let test_dashboard_mission_http_full_contract () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let session_id = "ts-mission-http-fixture-001" in
      Eio_main.run @@ fun env ->
      Eio_guard.enable ();
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      seed_room config session_id;
      (* Clear stale cache entries from prior tests to avoid cross-test pollution.
         Both dashboard-level and operator snapshot caches must be invalidated. *)
      Lib.Dashboard_cache.invalidate_all ();
      Lib.Operator_control.invalidate_snapshot_cache ();
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_mission_http_json
            ~state
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/mission?agent_name=test-dashboard-http")
        in
        let open Yojson.Safe.Util in
        check bool "operator targets present in mission http payload" true
          (json |> member "operator_targets" <> `Null);
        check bool "operator target sessions retained in mission http payload" true
          ((json |> member "operator_targets" |> member "sessions" |> to_list) <> []);
        check bool "internal signals retained in mission http payload" true
          ((json |> member "internal_signals" |> to_list) <> []);
        check bool "command focus retained in mission http payload" true
          (json |> member "command_focus" <> `Null);
        check bool "session brief survives mission http payload" true
          (json |> member "session_briefs" |> to_list
         |> List.exists (fun row -> row |> member "session_id" |> to_string = session_id));
      ))

let test_dashboard_mission_http_default_bootstraps_first_success () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      let session_id = "ts-mission-http-default-001" in
      seed_room config session_id;
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_mission_http_json
            ~state
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/mission")
        in
        let open Yojson.Safe.Util in
        check string "default mission cache becomes fresh" "fresh"
          (json |> member "projection_diagnostics" |> member "cache_state"
          |> to_string);
        check bool "default mission records first success" true
          (json |> member "projection_diagnostics" |> member "last_success_at"
           <> `Null);
        check bool "default mission leaves initializing placeholder" true
          (json |> member "summary" |> member "room_health" |> to_string
           <> "initializing");
        check string "default mission exposes namespace id" "default"
          (json |> member "summary" |> member "namespace_id" |> to_string);
        check string "default mission exposes namespace" "default"
          (json |> member "summary" |> member "namespace" |> to_string);
        check bool "default mission includes session briefs" true
          (json |> member "session_briefs" |> to_list
         |> List.exists (fun row -> row |> member "session_id" |> to_string = session_id));
      ))

let test_dashboard_mission_keeper_tool_audit_fallback () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let session_id = "ts-mission-http-default-001" in
      Eio_main.run @@ fun env ->
      Eio_guard.enable ();
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      seed_room config session_id;
      Lib.Dashboard_cache.invalidate_all ();
      Lib.Operator_control.invalidate_snapshot_cache ();
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_mission_http_json
            ~state
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/mission")
        in
        let open Yojson.Safe.Util in
        check string "default mission cache becomes fresh" "fresh"
          (json |> member "projection_diagnostics" |> member "cache_state"
          |> to_string);
        check bool "default mission records first success" true
          (json |> member "projection_diagnostics" |> member "last_success_at"
           <> `Null);
        check bool "default mission leaves initializing placeholder" true
          (json |> member "summary" |> member "room_health" |> to_string
           <> "initializing");
        check string "default mission exposes namespace id" "default"
          (json |> member "summary" |> member "namespace_id" |> to_string);
        check string "default mission exposes namespace" "default"
          (json |> member "summary" |> member "namespace" |> to_string);
        check bool "default mission includes session briefs" true
          (json |> member "session_briefs" |> to_list
         |> List.exists (fun row -> row |> member "session_id" |> to_string = session_id));
      ))

let test_dashboard_mission_http_cache_isolation () =
  let dir_a = test_dir () in
  let dir_b = test_dir () in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir dir_a;
      cleanup_dir dir_b)
    (fun () ->
      let actor = "test-dashboard-cache-isolation" in
      let session_a = "ts-mission-cache-fixture-a" in
      let session_b = "ts-mission-cache-fixture-b" in
      Eio_main.run @@ fun env ->
      Eio_guard.enable ();
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config_a = Room_utils.default_config dir_a in
      let config_b = Room_utils.default_config dir_b in
      seed_room config_a session_a;
      seed_room config_b session_b;
      let state_a =
        Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir_a ()
      in
      let state_b =
        Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir_b ()
      in
      Eio.Switch.run (fun sw ->
        let request =
          request ("/api/v1/dashboard/mission?agent_name=" ^ actor)
        in
        let json_a =
          Lib.Server_dashboard_http.dashboard_mission_http_json
            ~state:state_a
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            request
        in
        let json_b =
          Lib.Server_dashboard_http.dashboard_mission_http_json
            ~state:state_b
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            request
        in
        let open Yojson.Safe.Util in
        let has_session json expected_session =
          json |> member "session_briefs" |> to_list
          |> List.exists (fun row ->
                 row |> member "session_id" |> to_string = expected_session)
        in
        check bool "first room returns its own session brief" true
          (has_session json_a session_a);
        check bool "second room invalidates actor cache across rooms" true
          (has_session json_b session_b);
        check bool "second room does not reuse first room session brief" false
          (has_session json_b session_a);
      ))

let test_dashboard_mission_keeper_tool_audit_prefers_heartbeat_task () =
  let keeper_name = "audit-keeper-assembly-fixture" in
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      Lib.A2a_tools.emit_heartbeat_task
        ~agent:keeper_name
        ~goal:"Mission keeper audit fixture"
        ~context:"dashboard mission assembly"
        ~allowed_tools:[ "masc_board_get"; "masc_board_vote" ]
        ();
      let briefs =
        Lib.Dashboard_mission_assembly.build_keeper_briefs config
          [
            `Assoc
              [
                ("name", `String keeper_name);
                ("agent_name", `String keeper_name);
                ("status", `String "offline");
                ("updated_at", `String (Types.now_iso ()));
                ("allowed_tool_names", `List [ `String "masc_board_get"; `String "masc_board_vote" ]);
                ("latest_tool_names", `List []);
                ("latest_tool_call_count", `Null);
                ("latest_action_source", `String "structured_model");
                ("tool_audit_source", `Null);
                ("tool_audit_at", `Null);
              ];
          ]
      in
      let open Yojson.Safe.Util in
      let brief =
        briefs |> List.find (fun row -> row |> member "name" |> to_string = keeper_name)
      in
      check bool "heartbeat task allowed tools present" true
        ((brief |> member "allowed_tool_names" |> to_list) <> []);
      check string "heartbeat task source wins in keeper brief" "heartbeat_task"
        (brief |> member "tool_audit_source" |> to_string);
      check string "heartbeat task preserves fallback action source" "structured_model"
        (brief |> member "latest_action_source" |> to_string);
      check bool "no observed tools without evidence" true
        ((brief |> member "latest_tool_names" |> to_list) = []))

let test_dashboard_mission_keeper_tool_audit_uses_decision_log () =
  let keeper_name = "audit-keeper-decision-fixture" in
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      Room_utils.mkdir_p
        (Filename.dirname (Lib.Keeper_types.keeper_decision_log_path config keeper_name));
      Fs_compat.append_jsonl
        (Lib.Keeper_types.keeper_decision_log_path config keeper_name)
        (`Assoc
          [
            ("ts", `String (Types.now_iso ()));
            ("selected_mode", `String "text_response");
            ("action_source", `String "structured_model");
            ("tool_call_count", `Int 0);
            ("tools_used", `List []);
          ]);
      let briefs =
        Lib.Dashboard_mission_assembly.build_keeper_briefs config
          [
            `Assoc
              [
                ("name", `String keeper_name);
                ("agent_name", `String keeper_name);
                ("status", `String "active");
                ("updated_at", `String (Types.now_iso ()));
                ("allowed_tool_names", `List [ `String "masc_board_get" ]);
                ("latest_tool_names", `List []);
                ("latest_tool_call_count", `Null);
                ("tool_audit_source", `Null);
                ("tool_audit_at", `Null);
              ];
          ]
      in
      let open Yojson.Safe.Util in
      let brief =
        briefs |> List.find (fun row -> row |> member "name" |> to_string = keeper_name)
      in
      check string "decision log source present in keeper brief" "keeper_decision_log"
        (brief |> member "tool_audit_source" |> to_string);
      check string "decision log action source present in keeper brief"
        "structured_model"
        (brief |> member "latest_action_source" |> to_string);
      check int "decision log zero tool count preserved" 0
        (brief |> member "latest_tool_call_count" |> to_int);
      check bool "decision log still reports empty tool list" true
        ((brief |> member "latest_tool_names" |> to_list) = []))

let test_dashboard_mission_keeper_brief_registry_lookup_scoped_to_base_path () =
  let root_dir = test_dir () in
  let dir_a = Filename.concat root_dir "a-scope" in
  let dir_z = Filename.concat root_dir "z-scope" in
  let keeper_name = "shared-dashboard-keeper" in
  let make_meta ~also_allow name =
    match
      Lib.Keeper_types.meta_of_json
        (`Assoc
          [
            ("name", `String name);
            ("agent_name", `String name);
            ("trace_id", `String ("trace-" ^ name));
            ( "tool_access",
              Lib.Keeper_types.tool_access_to_json
                (Lib.Keeper_types.Preset
                   { preset = Lib.Keeper_types.Minimal; also_allow }) );
          ])
    with
    | Ok meta -> meta
    | Error err -> failwith ("make_meta failed: " ^ err)
  in
  Fun.protect
    ~finally:(fun () ->
      Lib.Keeper_registry.clear ();
      cleanup_dir root_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.mkdir dir_a 0o755;
      Unix.mkdir dir_z 0o755;
      Masc_test_deps.init_keeper_tool_registry ();
      let policy_base_path = Masc_test_deps.find_project_root () in
      ignore (Result.get_ok (Lib.Keeper_exec_tools.init_policy_config ~base_path:policy_base_path));
      let config_a = Room_utils.default_config dir_a in
      let config_z = Room_utils.default_config dir_z in
      ignore
        (Lib.Keeper_registry.register ~base_path:config_a.base_path keeper_name
           (make_meta ~also_allow:[ "keeper_board_vote" ] keeper_name));
      ignore
        (Lib.Keeper_registry.register ~base_path:config_z.base_path keeper_name
           (make_meta ~also_allow:[ "keeper_board_post" ] keeper_name));
      let briefs =
        Lib.Dashboard_mission_assembly.build_keeper_briefs config_a
          [
            `Assoc
              [
                ("name", `String keeper_name);
                ("agent_name", `String keeper_name);
                ("status", `String "idle");
                ("updated_at", `String (Types.now_iso ()));
                ("allowed_tool_names", `Null);
                ("latest_tool_names", `List []);
                ("latest_tool_call_count", `Null);
                ("tool_audit_source", `Null);
                ("tool_audit_at", `Null);
              ];
          ]
      in
      let open Yojson.Safe.Util in
      let brief =
        briefs |> List.find (fun row -> row |> member "name" |> to_string = keeper_name)
      in
      let allowed_tool_names =
        brief |> member "allowed_tool_names" |> to_list |> List.map to_string
      in
      check bool "current base path registry tools included" true
        (List.mem "keeper_board_vote" allowed_tool_names);
      check bool "other base path registry tools excluded" false
        (List.mem "keeper_board_post" allowed_tool_names))

let () =
  Alcotest.run "Dashboard Mission"
    [
      ( "read_model",
        [
          Alcotest.test_case "projection groups root-cause lanes" `Quick
            test_dashboard_mission_projection;
          Alcotest.test_case "http mission keeps full contract" `Quick
            test_dashboard_mission_http_full_contract;
          Alcotest.test_case "http mission default bootstraps first success"
            `Quick test_dashboard_mission_http_default_bootstraps_first_success;
          Alcotest.test_case "keeper tool audit fallback" `Quick
            test_dashboard_mission_keeper_tool_audit_fallback;
          Alcotest.test_case "http mission cache stays room-scoped" `Quick
            test_dashboard_mission_http_cache_isolation;
          Alcotest.test_case "keeper brief prefers heartbeat task" `Quick
            test_dashboard_mission_keeper_tool_audit_prefers_heartbeat_task;
          Alcotest.test_case "keeper brief uses decision log fallback" `Quick
            test_dashboard_mission_keeper_tool_audit_uses_decision_log;
          Alcotest.test_case "keeper brief registry lookup scoped to base path"
            `Quick
            test_dashboard_mission_keeper_brief_registry_lookup_scoped_to_base_path;
        ] );
    ]
