(** test_risk_digest.ml — Tests for Risk_digest structural risk signals. *)

open Masc_mcp

(* --- Test helpers --- *)

let make_delivery_contract
    ?(required_artifacts = []) ?(evidence_refs = [])
    ?(repair_budget = 3) () : Team_session_types.delivery_contract =
  {
    contract_id = "test-contract";
    summary = "test contract";
    acceptance_checks = [ "check_1" ];
    required_artifacts;
    repair_budget;
    generator_roles = [ "coder" ];
    evaluator_role = Some "reviewer";
    evaluator_cascade = "default";
    evidence_refs;
    updated_by = "test";
    updated_at_iso = "2026-03-29T00:00:00Z";
  }

let make_session
    ?(goal = "Implement feature X with proper testing")
    ?delivery_contract
    ?(planned_workers = [])
    ?(model_cascade = [ "opus" ]) () : Team_session_types.session =
  {
    session_id = "test-session";
    goal;
    created_by = "tester";
    origin_kind = Team_session_types.Origin_human;
    room_id = "test-room";
    operation_id = None;
    status = Team_session_types.Running;
    duration_seconds = 3600;
    execution_scope = Team_session_types.Autonomous;
    checkpoint_interval_sec = 300;
    min_agents = 1;
    scale_profile = Team_session_types.Scale_local64;
    control_profile = Team_session_types.Control_flat;
    orchestration_mode = Team_session_types.Auto;
    communication_mode = Team_session_types.Comm_broadcast;
    model_cascade;
    fallback_policy = Team_session_types.Fallback_cascade_then_task;
    instruction_profile = Team_session_types.Profile_standard;
    alert_channel = Team_session_types.Alert_broadcast;
    auto_resume = false;
    report_formats = [];
    turn_count = 0;
    agent_names = [];
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
    started_at = 1711670400.0;
    planned_end_at = 1711674000.0;
    stopped_at = None;
    last_checkpoint_at = None;
    last_event_at = None;
    last_turn_at = None;
    stop_reason = None;
    generated_report = false;
    delivery_contract;
    latest_delivery_verdict = None;
    artifacts_dir = "/tmp/test-artifacts";
    created_at_iso = "2026-03-29T00:00:00Z";
    updated_at_iso = "2026-03-29T00:00:00Z";
  }

let make_worker_card
    ?(status = "running") ?(risk_level = None) () :
    Operator_digest_types.worker_card =
  {
    actor = Some "worker-1";
    spawn_agent = Some "coder";
    spawn_role = Some "coder";
    spawn_model = None;
    execution_scope = None;
    worker_class = None;
    parent_actor = None;
    capsule_mode = None;
    runtime_pool = None;
    lane_id = None;
    controller_level = None;
    control_domain = None;
    supervisor_actor = None;
    task_profile = None;
    risk_level;
    routing_confidence = None;
    routing_reason = None;
    status;
    turn_count = 5;
    empty_note_turn_count = 0;
    has_turn = true;
    last_turn_age_sec = Some 10;
    evidence_source = "session_events";
    last_turn_ts_iso = Some "2026-03-29T00:01:00Z";
  }

(* --- Evidence gap tests --- *)

let test_evidence_gap_no_contract () =
  let session = make_session () in
  let result = Risk_digest.compute ~session ~worker_cards:[] in
  Alcotest.(check int) "required 0" 0 result.evidence_gap.required_count;
  Alcotest.(check int) "present 0" 0 result.evidence_gap.present_count;
  Alcotest.(check int) "missing 0" 0 (List.length result.evidence_gap.missing)

let test_evidence_gap_all_present () =
  let dc =
    make_delivery_contract
      ~required_artifacts:[ "report.md"; "test_results.xml" ]
      ~evidence_refs:[ "report.md"; "test_results.xml" ] ()
  in
  let session = make_session ~delivery_contract:dc () in
  let result = Risk_digest.compute ~session ~worker_cards:[] in
  Alcotest.(check int) "required 2" 2 result.evidence_gap.required_count;
  Alcotest.(check int) "present 2" 2 result.evidence_gap.present_count;
  Alcotest.(check int) "missing 0" 0 (List.length result.evidence_gap.missing)

let test_evidence_gap_partial () =
  let dc =
    make_delivery_contract
      ~required_artifacts:[ "report.md"; "test_results.xml"; "coverage.json" ]
      ~evidence_refs:[ "report.md" ] ()
  in
  let session = make_session ~delivery_contract:dc () in
  let result = Risk_digest.compute ~session ~worker_cards:[] in
  Alcotest.(check int) "required 3" 3 result.evidence_gap.required_count;
  Alcotest.(check int) "present 1" 1 result.evidence_gap.present_count;
  Alcotest.(check int) "missing 2" 2 (List.length result.evidence_gap.missing);
  Alcotest.(check bool) "missing test_results"
    true
    (List.mem "test_results.xml" result.evidence_gap.missing);
  Alcotest.(check bool) "missing coverage"
    true
    (List.mem "coverage.json" result.evidence_gap.missing)

(* --- Drift risk tests --- *)

let test_drift_no_workers () =
  let session = make_session () in
  let result = Risk_digest.compute ~session ~worker_cards:[] in
  Alcotest.(check int) "no drift signals" 0 (List.length result.drift_risk)

let test_drift_consistent_tiers () =
  let cards =
    [
      make_worker_card ();
      make_worker_card ();
    ]
  in
  let session = make_session ~model_cascade:[ "opus" ] () in
  let result = Risk_digest.compute ~session ~worker_cards:cards in
  Alcotest.(check int) "no drift" 0 (List.length result.drift_risk)

(* --- Unsafe edit risk tests --- *)

let test_unsafe_edit_no_risk () =
  let session = make_session () in
  let result = Risk_digest.compute ~session ~worker_cards:[] in
  Alcotest.(check int) "no unsafe signals" 0 (List.length result.unsafe_edit_risk)

let test_unsafe_edit_zero_repair () =
  let dc = make_delivery_contract ~repair_budget:0 () in
  let session = make_session ~delivery_contract:dc () in
  let result = Risk_digest.compute ~session ~worker_cards:[] in
  Alcotest.(check bool) "has zero_repair_budget" true
    (List.exists
       (fun s -> match s with Risk_digest.Zero_repair_budget -> true | _ -> false)
       result.unsafe_edit_risk)

let test_unsafe_edit_high_risk_worker () =
  let cards = [ make_worker_card ~risk_level:(Some "high") () ] in
  let session = make_session () in
  let result = Risk_digest.compute ~session ~worker_cards:cards in
  Alcotest.(check bool) "has high_risk_class" true
    (List.exists
       (fun s -> match s with Risk_digest.High_risk_class -> true | _ -> false)
       result.unsafe_edit_risk)

(* --- Ambiguity tests --- *)

let test_ambiguity_short_goal () =
  let session = make_session ~goal:"fix" () in
  let result = Risk_digest.compute ~session ~worker_cards:[] in
  Alcotest.(check bool) "short goal no longer implies ambiguity" true
    (Option.is_none result.ambiguity)

let test_ambiguity_no_contract_multi_worker () =
  let pw : Team_session_types.planned_worker =
    {
      spawn_agent = "coder";
      runtime_actor = None;
      spawn_role = None;
      spawn_model = None;
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
  in
  let session = make_session ~planned_workers:[ pw; pw; pw ] () in
  let result = Risk_digest.compute ~session ~worker_cards:[] in
  Alcotest.(check bool) "has ambiguity" true (Option.is_some result.ambiguity)

let test_ambiguity_clear_session () =
  let dc = make_delivery_contract () in
  let session = make_session ~delivery_contract:dc () in
  let result = Risk_digest.compute ~session ~worker_cards:[] in
  Alcotest.(check bool) "no ambiguity" true (Option.is_none result.ambiguity)

(* --- JSON serialization test --- *)

let test_to_yojson () =
  let dc =
    make_delivery_contract
      ~required_artifacts:[ "report.md" ]
      ~evidence_refs:[] ~repair_budget:0 ()
  in
  let planned_worker : Team_session_types.planned_worker =
    {
      spawn_agent = "worker-proof";
      runtime_actor = None;
      spawn_role = None;
      spawn_model = None;
      execution_scope = Some Team_session_types_enums.Autonomous;
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
  in
  let session = make_session ~delivery_contract:dc ~planned_workers:[ planned_worker ] () in
  let cards = [ make_worker_card ~risk_level:(Some "critical") () ] in
  let result = Risk_digest.compute ~session ~worker_cards:cards in
  let json = Risk_digest.to_yojson result in
  let open Yojson.Safe.Util in
  let eg = json |> member "evidence_gap" in
  Alcotest.(check int) "required 1" 1 (eg |> member "required_count" |> to_int);
  let signal_count = json |> member "signal_count" |> to_int in
  Alcotest.(check bool) "signal_count > 0" true (signal_count > 0);
  let unsafe = json |> member "unsafe_edit_risk" |> to_list in
  Alcotest.(check bool) "unsafe not empty" true (List.length unsafe > 0);
  let autonomous_signal =
    List.find
      (fun item ->
        item |> member "type" |> to_string
        |> String.equal "autonomous_execution_scope")
      unsafe
  in
  Alcotest.(check string) "worker_name preserved" "worker-proof"
    (autonomous_signal |> member "worker_name" |> to_string);
  Alcotest.(check string) "legacy tool_name alias preserved" "worker-proof"
    (autonomous_signal |> member "tool_name" |> to_string)

(* --- Test suite --- *)

let () =
  Alcotest.run "risk_digest"
    [
      ( "evidence_gap",
        [
          Alcotest.test_case "no contract" `Quick test_evidence_gap_no_contract;
          Alcotest.test_case "all present" `Quick test_evidence_gap_all_present;
          Alcotest.test_case "partial" `Quick test_evidence_gap_partial;
        ] );
      ( "drift_risk",
        [
          Alcotest.test_case "no workers" `Quick test_drift_no_workers;
          Alcotest.test_case "consistent tiers" `Quick test_drift_consistent_tiers;
        ] );
      ( "unsafe_edit_risk",
        [
          Alcotest.test_case "no risk" `Quick test_unsafe_edit_no_risk;
          Alcotest.test_case "zero repair budget" `Quick
            test_unsafe_edit_zero_repair;
          Alcotest.test_case "high risk worker" `Quick
            test_unsafe_edit_high_risk_worker;
        ] );
      ( "ambiguity",
        [
          Alcotest.test_case "short goal" `Quick test_ambiguity_short_goal;
          Alcotest.test_case "no contract multi worker" `Quick
            test_ambiguity_no_contract_multi_worker;
          Alcotest.test_case "clear session" `Quick test_ambiguity_clear_session;
        ] );
      ( "serialization",
        [
          Alcotest.test_case "to_yojson" `Quick test_to_yojson;
        ] );
    ]
