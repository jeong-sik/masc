open Masc_mcp
open Test_command_plane_v2_support

let test_summary_json_omits_heavy_arrays_and_keeps_summaries () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      let config = Room.default_config base_dir in
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      ignore
        (start_operation_exn config ~actor:"owner"
           (`Assoc
             [
               ("assigned_unit_id", `String "platoon-alpha");
               ("objective", `String "Run summary drill");
               ("policy_class", `String "guarded");
               ("budget_class", `String "standard");
             ]));
      let summary = Command_plane_v2.summary_json config in
      Alcotest.(check int) "summary topology active ops" 1
        (summary |> Yojson.Safe.Util.member "topology"
       |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "active_operation_count"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "summary operations total" 1
        (summary |> Yojson.Safe.Util.member "operations"
       |> Yojson.Safe.Util.member "summary"
       |> Yojson.Safe.Util.member "total"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check bool) "topology units omitted" true
        (summary |> Yojson.Safe.Util.member "topology"
       |> Yojson.Safe.Util.member "units" = `Null);
      Alcotest.(check bool) "operations list omitted" true
        (summary |> Yojson.Safe.Util.member "operations"
       |> Yojson.Safe.Util.member "operations" = `Null);
      Alcotest.(check bool) "detachments list omitted" true
        (summary |> Yojson.Safe.Util.member "detachments"
       |> Yojson.Safe.Util.member "detachments" = `Null);
      Alcotest.(check bool) "traces omitted at root" true
        (summary |> Yojson.Safe.Util.member "traces" = `Null);
      Alcotest.(check bool) "swarm proof included" true
        (summary |> Yojson.Safe.Util.member "swarm_proof" <> `Null))

let test_summary_json_swarm_proof_prefers_artifact () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      let run_dir =
        Filename.concat
          (Filename.concat (Filename.concat (Room.masc_dir config) "control-plane") "swarm-live")
          "run-artifact"
      in
      write_json_file (Filename.concat run_dir "swarm-live-summary.json")
        (`Assoc
          [
            ("pass", `Bool true);
            ("worker_count", `Int 4);
            ("joined_workers", `Int 4);
            ("current_task_bound", `Int 4);
            ("fresh_heartbeats", `Int 4);
            ("completed_workers", `Int 3);
            ("final_markers_seen", `Int 2);
          ]);
      write_text_file (Filename.concat run_dir "slot-samples.jsonl")
        "{\"timestamp\":\"2026-03-08T00:00:00Z\",\"active_slots\":5,\"ctx_per_slot\":1200}\n";
      let summary = Command_plane_v2.summary_json config in
      let proof = Yojson.Safe.Util.member "swarm_proof" summary in
      Alcotest.(check string) "artifact status" "present"
        (proof |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "artifact source" "artifact"
        (proof |> Yojson.Safe.Util.member "source" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "artifact reason code" "artifact_present"
        (proof |> Yojson.Safe.Util.member "reason_code"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "artifact run id" "run-artifact"
        (proof |> Yojson.Safe.Util.member "run_id" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "artifact pass" true
        (proof |> Yojson.Safe.Util.member "pass" |> Yojson.Safe.Util.to_bool);
      Alcotest.(check string) "artifact expected dir" run_dir
        (proof |> Yojson.Safe.Util.member "expected_artifact_dir"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check int) "artifact worker expected" 4
        (proof |> Yojson.Safe.Util.member "workers"
       |> Yojson.Safe.Util.member "expected"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "artifact worker joined" 4
        (proof |> Yojson.Safe.Util.member "workers"
       |> Yojson.Safe.Util.member "joined"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "artifact task bound" 4
        (proof |> Yojson.Safe.Util.member "workers"
       |> Yojson.Safe.Util.member "current_task_bound"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "artifact fresh heartbeats" 4
        (proof |> Yojson.Safe.Util.member "workers"
       |> Yojson.Safe.Util.member "fresh_heartbeats"
       |> Yojson.Safe.Util.to_int);
      Alcotest.(check int) "artifact peak hot slots" 5
        (proof |> Yojson.Safe.Util.member "peak_hot_slots"
       |> Yojson.Safe.Util.to_int))

let test_summary_json_swarm_proof_fallback_and_missing () =
  let fallback_dir = temp_dir () in
  let missing_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir fallback_dir;
      cleanup_dir missing_dir)
    (fun () ->
      let fallback_config = Room.default_config fallback_dir in
      ignore (Room.init fallback_config ~agent_name:(Some "owner"));
      let run_dir =
        Filename.concat
          (Filename.concat (Filename.concat (Room.masc_dir fallback_config) "control-plane") "swarm-live")
          "run-fallback"
      in
      write_text_file (Filename.concat run_dir "slot-samples.jsonl")
        "{\"timestamp\":\"2026-03-08T01:00:00Z\",\"active_slots\":2,\"ctx_per_slot\":800}\n";
      let fallback_summary = Command_plane_v2.summary_json fallback_config in
      let fallback_proof = Yojson.Safe.Util.member "swarm_proof" fallback_summary in
      Alcotest.(check string) "fallback status" "fallback"
        (fallback_proof |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "fallback source" "slot_samples"
        (fallback_proof |> Yojson.Safe.Util.member "source" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "fallback reason code" "slot_samples_only"
        (fallback_proof |> Yojson.Safe.Util.member "reason_code"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "fallback run id" "run-fallback"
        (fallback_proof |> Yojson.Safe.Util.member "run_id" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "fallback pass omitted" true
        (fallback_proof |> Yojson.Safe.Util.member "pass" = `Null);
      Alcotest.(check string) "fallback expected dir" run_dir
        (fallback_proof |> Yojson.Safe.Util.member "expected_artifact_dir"
       |> Yojson.Safe.Util.to_string);
      let missing_config = Room.default_config missing_dir in
      ignore (Room.init missing_config ~agent_name:(Some "owner"));
      let missing_summary = Command_plane_v2.summary_json missing_config in
      let missing_proof = Yojson.Safe.Util.member "swarm_proof" missing_summary in
      Alcotest.(check string) "missing status" "missing"
        (missing_proof |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "missing source" "none"
        (missing_proof |> Yojson.Safe.Util.member "source" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "missing reason code" "no_swarm_live_artifacts"
        (missing_proof |> Yojson.Safe.Util.member "reason_code"
       |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "missing reason present" true
        (missing_proof |> Yojson.Safe.Util.member "missing_reason" <> `Null);
      Alcotest.(check bool) "missing summary present" true
        (missing_proof |> Yojson.Safe.Util.member "status_summary" <> `Null);
      Alcotest.(check bool) "missing expected dir present" true
        (missing_proof |> Yojson.Safe.Util.member "expected_artifact_dir" <> `Null))
let test_swarm_live_json_reads_custom_worker_count_from_operation_note () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let run_id = "swarm-live-custom-count" in
      let plans =
        Agent_swarm_live_harness.build_worker_plans ~worker_count:13 run_id
      in
      let worker_names =
        List.map
          (fun (plan : Agent_swarm_live_harness.worker_plan) -> plan.name)
          plans
      in
      let leader = List.hd worker_names in
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
      List.iter
        (fun worker ->
          ignore (Room.join config ~agent_name:worker ~capabilities:[] ()))
        worker_names;
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "company-main");
            ("kind", `String "company");
            ("label", `String "Main Company");
            ("leader_id", `String owner);
            ( "roster",
              `List
                (List.map (fun name -> `String name) (owner :: worker_names))
            );
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "platoon-alpha");
            ("kind", `String "platoon");
            ("label", `String "Alpha Platoon");
            ("parent_unit_id", `String "company-main");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      unit_update_exn config ~actor:"owner"
        (`Assoc
          [
            ("unit_id", `String "squad-alpha-1");
            ("kind", `String "squad");
            ("label", `String "Alpha Squad 1");
            ("parent_unit_id", `String "platoon-alpha");
            ("leader_id", `String leader);
            ("roster", `List (List.map (fun name -> `String name) worker_names));
          ]);
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "squad-alpha-1");
              ( "objective",
                `String
                  (Printf.sprintf "Run deterministic 13-worker live harness %s"
                     run_id) );
              ( "note",
                `String
                  (Printf.sprintf
                     "run_id=%s worker_count=13 required_final_markers=13 min_hot_slots=11"
                     run_id) );
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String operation.operation_id) ])));
      let swarm =
        Command_plane_v2.swarm_live_json config ~run_id
          ~operation_id:operation.operation_id ()
      in
      let open Yojson.Safe.Util in
      Alcotest.(check int) "expected workers from note" 13
        (swarm |> member "summary" |> member "expected_workers" |> to_int);
      Alcotest.(check int) "worker rows from note" 13
        (swarm |> member "workers" |> to_list |> List.length);
      Alcotest.(check int) "live workers from joined roster" 13
        (swarm |> member "summary" |> member "live_workers" |> to_int))

let test_swarm_live_json_reads_runtime_doctor_and_blockers () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      let run_id = "swarm-live-runtime-doctor" in
      let run_dir =
        Filename.concat
          (Filename.concat (Filename.concat (Room.masc_dir config) "control-plane") "swarm-live")
          run_id
      in
      write_json_file (Filename.concat run_dir "swarm-live-summary.json")
        (`Assoc
          [
            ("run_id", `String run_id);
            ("worker_count", `Int 12);
            ("required_final_markers", `Int 12);
            ("completed_workers", `Int 0);
            ("final_markers_seen", `Int 0);
            ("pass_hot_concurrency", `Bool false);
            ("pass_end_to_end", `Bool false);
            ("pass", `Bool false);
            ("min_hot_slots", `Int 10);
          ]);
      write_json_file (Filename.concat run_dir "runtime-doctor.json")
        (`Assoc
          [
            ("checked_at", `String "2026-03-09T06:30:00Z");
            ("provider_base_url", `String "http://127.0.0.1:3034");
            ("provider_reachable", `Bool false);
            ("provider_status_code", `Int 502);
            ("provider_model_id", `String "qwen3.5-35b-a3b-ud-q8-xl");
            ("actual_model_id", `String "qwen3.5-35b-a3b-ud-q8-xl");
            ("slot_url", `String "http://127.0.0.1:8085");
            ("slot_reachable", `Bool false);
            ("slot_status_code", `Int 0);
            ("expected_slots", `Int 12);
            ("actual_slots", `Int 0);
            ("expected_ctx", `Int 262144);
            ("actual_ctx", `Int 0);
            ("configured_capacity", `Int 12);
            ("runtime_blocker", `String "provider_unreachable");
            ("detail", `String "provider smoke request failed");
          ]);
      let swarm = Command_plane_v2.swarm_live_json config ~run_id () in
      let open Yojson.Safe.Util in
      Alcotest.(check bool) "provider reachable false" false
        (swarm |> member "provider" |> member "provider_reachable" |> to_bool);
      Alcotest.(check int) "expected slots from doctor" 12
        (swarm |> member "provider" |> member "expected_slots" |> to_int);
      Alcotest.(check int) "actual ctx from doctor" 0
        (swarm |> member "provider" |> member "actual_ctx" |> to_int);
      Alcotest.(check int) "configured capacity from doctor" 12
        (swarm |> member "provider" |> member "configured_capacity" |> to_int);
      Alcotest.(check string) "runtime blocker surfaced" "provider_unreachable"
        (swarm |> member "provider" |> member "runtime_blocker" |> to_string);
      Alcotest.(check bool) "blocker list contains runtime issue" true
        (swarm |> member "blockers" |> to_list
       |> List.exists (fun row ->
              String.equal
                (row |> member "code" |> to_string)
                "provider_unreachable")))

let test_swarm_live_json_recommends_rerun_without_resumable_state () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      let swarm = Command_plane_v2.swarm_live_json config ~run_id:"empty-swarm-run" () in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "rerun recommendation" "rerun"
        (swarm |> member "resolution_recommendation" |> member "recommended_kind"
       |> to_string);
      Alcotest.(check bool) "continue unavailable" false
        (swarm |> member "resolution_recommendation" |> member "continue_available"
       |> to_bool);
      Alcotest.(check bool) "rerun available" true
        (swarm |> member "resolution_recommendation" |> member "rerun_available"
       |> to_bool))

let test_swarm_live_json_recommends_continue_for_paused_run_and_hides_after_abandon () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let owner = "owner-root-node" in
      let alpha_lead = "alpha-lead-node" in
      let alpha_two = "alpha-two-node" in
      let run_id = "paused-swarm-run" in
      let config = Room.default_config base_dir in
      setup_company_and_platoon config ~owner ~alpha_lead ~alpha_two;
      let operation =
        start_operation_exn config ~actor:"owner"
          (`Assoc
            [
              ("assigned_unit_id", `String "platoon-alpha");
              ("objective", `String "Paused swarm live harness");
              ("note", `String (Printf.sprintf "run_id=%s" run_id));
              ("policy_class", `String "guarded");
              ("budget_class", `String "standard");
            ])
      in
      ignore
        (unwrap_ok
           (Command_plane_v2.dispatch_tick_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String operation.operation_id) ])));
      ignore
        (unwrap_ok
           (Command_plane_v2.pause_operation_json config ~actor:"owner"
              (`Assoc [ ("operation_id", `String operation.operation_id) ])));
      let before =
        Command_plane_v2.swarm_live_json config ~run_id
          ~operation_id:operation.operation_id ()
      in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "continue recommendation" "continue"
        (before |> member "resolution_recommendation" |> member "recommended_kind"
       |> to_string);
      let resolution =
        Command_plane_v2.record_swarm_run_resolution_json config ~run_id
          ~status:"abandoned" ~actor:"owner"
          ~reason:"operator chose soft abandon"
          ~operation_id:operation.operation_id
          ?note:(Some "test abandon") ()
      in
      Alcotest.(check string) "resolution written" "abandoned"
        (resolution |> member "status" |> to_string);
      let after =
        Command_plane_v2.swarm_live_json config ~run_id
          ~operation_id:operation.operation_id ()
      in
      Alcotest.(check string) "persisted run resolution" "abandoned"
        (after |> member "run_resolution" |> member "status" |> to_string);
      Alcotest.(check bool) "recommendation suppressed" true
        (after |> member "resolution_recommendation" = `Null))

