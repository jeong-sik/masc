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

let sample_session now session_id =
  let open Lib.Team_session_types in
  {
    session_id;
    goal = "Prove multi-actor collaboration on MCP help cleanup";
    created_by = "supervisor";
    room_id = "default";
    status = Running;
    duration_seconds = 600;
    execution_scope = Limited_code_change;
    checkpoint_interval_sec = 60;
    min_agents = 2;
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
    agent_names = [ "worker-a"; "worker-b" ];
    planned_workers =
      [
        {
          spawn_agent = "llama";
          runtime_actor = Some "worker-a";
          spawn_role = Some "implementer";
          spawn_model = Some "qwen3.5-35b-a3b-ud-q8-xl";
          worker_class = Some Worker_executor;
          parent_actor = Some "supervisor";
          capsule_mode = Some Capsule_inherit;
          runtime_pool = Some "local64";
          lane_id = Some "lane-proof";
          controller_level = Some Controller_worker;
          control_domain = Some Domain_execution;
          supervisor_actor = Some "supervisor";
          model_tier = Some Tier_35b;
          task_profile = Some Profile_synthesize;
          risk_level = Some Risk_medium;
          routing_confidence = Some 0.9;
          routing_reason = Some "worker-a implements proof surface";
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
    started_at = now -. 120.0;
    planned_end_at = now +. 480.0;
    stopped_at = None;
    last_checkpoint_at = Some (now -. 30.0);
    last_event_at = Some (now -. 10.0);
    last_turn_at = Some (now -. 15.0);
    stop_reason = None;
    generated_report = true;
    artifacts_dir = Filename.concat ".masc/team-sessions" session_id;
    created_at_iso = Lib.Types.now_iso ();
    updated_at_iso = Lib.Types.now_iso ();
  }

let seed_session_artifacts config session_id =
  let now = Unix.gettimeofday () in
  let session = sample_session now session_id in
  Lib.Team_session_store.save_session config session;
  Lib.Team_session_store.append_event config session_id ~event_type:"team_step_spawn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "supervisor");
          ("runtime_actor", `String "worker-a");
          ("spawn_agent", `String "llama");
          ("success", `Bool true);
          ("tool_names", `List [ `String "masc_team_session_step" ]);
          ("title", `String "Spawn proof worker");
        ]);
  Lib.Team_session_store.append_event config session_id ~event_type:"team_turn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "worker-a");
          ("kind", `String "note");
          ("message", `String "Implemented the tool-help projection and validated prompts.");
          ("tool_names", `List [ `String "masc_tool_help"; `String "masc_team_session_prove" ]);
        ]);
  Lib.Team_session_store.append_event config session_id ~event_type:"team_turn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "worker-b");
          ("kind", `String "note");
          ("message", `String "Reviewed the proof evidence and confirmed the actor linkage.");
        ]);
  Lib.Team_session_store.write_checkpoint config session_id
    {
      Lib.Team_session_types.ts = now -. 25.0;
      ts_iso = Lib.Types.now_iso ();
      status = Lib.Team_session_types.Running;
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
  Lib.Room_utils.write_json config
    (Lib.Team_session_store.report_json_path config session_id)
    (`Assoc [ ("ok", `Bool true) ]);
  match Lib.Team_session_report.generate_proof config session with
  | Error msg -> fail msg
  | Ok (proof_json, proof_md) ->
      Lib.Room_utils.write_json config
        (Lib.Team_session_store.proof_json_path config session_id)
        proof_json;
      Lib.Team_session_store.write_text_file
        (Lib.Team_session_store.proof_md_path config session_id)
        proof_md

let test_dashboard_proof_projection () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Lib.Room.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "fixture-root"));
      let session_id = "ts-proof-fixture-001" in
      seed_session_artifacts config session_id;
      let json = Lib.Dashboard_proof.json ~config () in
      check string "verdict" "proven"
        (json |> U.member "proof_verdict" |> U.to_string);
      check string "session id" session_id
        (json |> U.member "session_id" |> U.to_string);
      check bool "timeline present" true
        ((json |> U.member "timeline" |> U.to_list) <> []);
      check bool "actor contributions present" true
        ((json |> U.member "actor_contributions" |> U.to_list) <> []);
      check bool "artifacts present" true
        ((json |> U.member "artifacts" |> U.to_list) <> []);
      check bool "cp backing present" true
        (json |> U.member "cp_backing_evidence" <> `Null))

let () =
  Alcotest.run "dashboard_proof"
    [
      ("projection", [ test_case "builds collaboration proof projection" `Quick test_dashboard_proof_projection ]);
    ]
