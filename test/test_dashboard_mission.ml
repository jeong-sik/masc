(** Dashboard Mission read-model regression tests. *)

module Lib = Masc_mcp

open Alcotest

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

let contains str substr =
  try
    ignore (Str.search_forward (Str.regexp_string substr) str 0);
    true
  with Not_found -> false

let write_pending_confirm config session_id =
  let operator_dir = Filename.concat (Lib.Room_utils.masc_dir config) "operator" in
  Lib.Room_utils.mkdir_p operator_dir;
  Lib.Room_utils.write_json config (Filename.concat operator_dir "pending_confirms.json")
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
            ("created_at", `String (Lib.Types.now_iso ()));
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
  let open Lib.Team_session_types in
  let session =
    {
      session_id;
      goal = "Validate local64 swarm role coverage, runtime visibility, and operator census";
      created_by = "fixture-root";
      room_id = "default";
      operation_id = None;
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
            worker_class = Some Worker_manager;
            parent_actor = Some "team-session-local64-smoke";
            capsule_mode = Some Capsule_inherit;
            runtime_pool = Some "local64";
            lane_id = Some "lane-manager";
            controller_level = Some Controller_root;
            control_domain = Some Domain_execution;
            supervisor_actor = Some "team-session-local64-smoke";
            model_tier = Some Tier_35b;
            task_profile = Some Profile_decide;
            risk_level = Some Risk_high;
            routing_confidence = Some 0.94;
            routing_reason = Some "manager must hold root synthesis";
            routing_escalated = false;
          };
          {
            spawn_agent = "llama";
            runtime_actor = Some "llama-local-beta";
            spawn_role = Some "metacog";
            spawn_model = Some "qwen27-balanced";
            worker_class = Some Worker_metacog;
            parent_actor = Some "team-session-local64-smoke";
            capsule_mode = Some Capsule_inherit;
            runtime_pool = Some "local64";
            lane_id = Some "lane-meta";
            controller_level = Some Controller_lane;
            control_domain = Some Domain_meta;
            supervisor_actor = Some "llama-local-alpha";
            model_tier = Some Tier_27b;
            task_profile = Some Profile_verify;
            risk_level = Some Risk_medium;
            routing_confidence = Some 0.68;
            routing_reason = Some "spawn failures hide runtime census";
            routing_escalated = true;
          };
          {
            spawn_agent = "llama";
            runtime_actor = Some "llama-local-gamma";
            spawn_role = Some "executor";
            spawn_model = Some "qwen9-swarm";
            worker_class = Some Worker_executor;
            parent_actor = Some "team-session-local64-smoke";
            capsule_mode = Some Capsule_fresh;
            runtime_pool = Some "local64";
            lane_id = Some "lane-worker";
            controller_level = Some Controller_worker;
            control_domain = Some Domain_runtime;
            supervisor_actor = Some "llama-local-alpha";
            model_tier = Some Tier_9b;
            task_profile = Some Profile_extract;
            risk_level = Some Risk_medium;
            routing_confidence = Some 0.88;
            routing_reason = Some "executor covers direct runtime checks";
            routing_escalated = false;
          };
          {
            spawn_agent = "llama";
            runtime_actor = Some "llama-local-delta";
            spawn_role = Some "observer";
            spawn_model = Some "qwen9-swarm";
            worker_class = Some Worker_scout;
            parent_actor = Some "team-session-local64-smoke";
            capsule_mode = Some Capsule_fresh;
            runtime_pool = Some "local64";
            lane_id = Some "lane-observer";
            controller_level = Some Controller_worker;
            control_domain = Some Domain_runtime;
            supervisor_actor = Some "llama-local-alpha";
            model_tier = Some Tier_9b;
            task_profile = Some Profile_extract;
            risk_level = Some Risk_low;
            routing_confidence = Some 0.72;
            routing_reason = Some "observer preserves room-level runtime census";
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
      artifacts_dir = Filename.concat ".masc/team-sessions" session_id;
      created_at_iso = Lib.Types.now_iso ();
      updated_at_iso = Lib.Types.now_iso ();
    }
  in
  Lib.Team_session_store.save_session config session;
  Lib.Team_session_store.append_event config session_id
    ~event_type:"team_step_spawn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "team-session-local64-smoke");
          ("spawn_agent", `String "llama");
          ("runtime_actor", `String "llama-local-delta");
          ("success", `Bool false);
          ("reason", `String "Connection refused on secondary runtime");
          ("title", `String "Recover failed worker coverage");
        ]);
  Lib.Team_session_store.append_event config session_id
    ~event_type:"team_step_spawn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "team-session-local64-smoke");
          ("spawn_agent", `String "llama");
          ("runtime_actor", `String "llama-local-epsilon");
          ("success", `Bool false);
          ("reason", `String "Slot census timed out on local64 runtime");
          ("title", `String "Recover failed worker coverage");
        ]);
  Lib.Team_session_store.append_event config session_id
    ~event_type:"team_turn"
    ~detail:
      (`Assoc
        [
          ("kind", `String "note");
          ("actor", `String "llama-local-alpha");
          ("message", `String "manager synthesized runtime visibility");
        ]);
  Lib.Team_session_store.append_event config session_id
    ~event_type:"local64_smoke_cleanup"
    ~detail:(`Assoc [ ("result", `String "interrupted after spawn failure reproduction") ]);
  write_pending_confirm config session_id

let test_dashboard_mission_projection () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Lib.Room_utils.default_config dir in
      let session_id = "ts-mission-fixture-001" in
      seed_room config session_id;
      Eio_main.run @@ fun env ->
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_mission.json
            ~actor:"test-dashboard"
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        let attention_queue = json |> member "attention_queue" |> to_list in
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
        let alpha_input = alpha_brief |> member "recent_input_preview" |> to_string in
        check bool "recent input preserves exact alpha mention" true
          (contains alpha_input "@llama-local-alpha");
        check bool "recent input excludes unrelated beta mention" false
          (contains alpha_input "@llama-local-beta");
        check bool "internal signal includes pending confirm" true
          (internal_signals
           |> List.exists (fun row ->
                contains (row |> member "summary" |> to_string) "pending confirmation"));
        let room_action_reasons =
          internal_signals
          |> List.filter_map (fun row ->
                 match row |> member "action" with
                 | `Assoc _ as action ->
                     if action |> member "target_type" |> to_string = "room"
                        && action |> member "action_type" |> to_string = "broadcast"
                     then Some (action |> member "reason" |> to_string)
                     else None
                 | _ -> None)
          |> List.sort_uniq String.compare
        in
        check bool "multiple room actions survive internal matching" true
          (List.length room_action_reasons >= 2);
      ))

let () =
  Alcotest.run "Dashboard Mission"
    [
      ( "read_model",
        [ Alcotest.test_case "projection groups root-cause lanes" `Quick
            test_dashboard_mission_projection ] );
    ]
