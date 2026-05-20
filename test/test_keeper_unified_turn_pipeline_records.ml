open Alcotest

module KRun = Masc_mcp.Keeper_turn_driver
module KP = Masc_mcp.Keeper_state_machine
module UT = Masc_mcp.Keeper_unified_turn
module Rotation_attempt = Masc_mcp.Keeper_unified_turn_rotation_attempt
module Receipt = Masc_mcp.Keeper_execution_receipt
module EC = Masc_mcp.Keeper_error_classify

let test_turn_plan_phase_gate_records_typed_contract () =
  let open Yojson.Safe.Util in
  let running =
    UT.decide_turn_plan_at_phase_gate
      ~keeper_turn_id:17
      ~supervisor_stop_at_entry:false
      (Some KP.Running)
  in
  check int "turn plan keeps turn id" 17 running.turn_plan_keeper_turn_id;
  check string "running manifest status" "ok" (UT.turn_plan_manifest_status running);
  check bool "running executable" true running.turn_plan_executable;
  check
    (option string)
    "running terminal reason absent"
    None
    running.turn_plan_terminal_reason_code;
  let running_decision = UT.turn_plan_manifest_decision running in
  check string "running phase" "running" (running_decision |> member "phase" |> to_string);
  check
    string
    "running reason"
    "executable_phase"
    (running_decision |> member "reason" |> to_string);
  check
    bool
    "running decision executable"
    true
    (running_decision |> member "executable" |> to_bool);
  let paused =
    UT.decide_turn_plan_at_phase_gate
      ~keeper_turn_id:18
      ~supervisor_stop_at_entry:false
      (Some KP.Paused)
  in
  check string "paused manifest status" "skipped" (UT.turn_plan_manifest_status paused);
  check
    (option string)
    "paused terminal reason"
    (Some "non_executable_phase:paused")
    paused.turn_plan_terminal_reason_code;
  let paused_decision = UT.turn_plan_manifest_decision paused in
  check string "paused phase" "paused" (paused_decision |> member "phase" |> to_string);
  check
    string
    "paused reason"
    "non_executable_phase"
    (paused_decision |> member "reason" |> to_string);
  let missing =
    UT.decide_turn_plan_at_phase_gate
      ~keeper_turn_id:19
      ~supervisor_stop_at_entry:false
      None
  in
  check string "missing manifest status" "error" (UT.turn_plan_manifest_status missing);
  check
    (option string)
    "missing terminal reason"
    (Some "registry_phase_missing")
    missing.turn_plan_terminal_reason_code;
  let missing_decision = UT.turn_plan_manifest_decision missing in
  check bool "missing phase is null" true (missing_decision |> member "phase" = `Null);
  check
    string
    "missing reason"
    "registry_phase_missing"
    (missing_decision |> member "reason" |> to_string);
  let stopped =
    UT.decide_turn_plan_at_phase_gate
      ~keeper_turn_id:20
      ~supervisor_stop_at_entry:true
      None
  in
  check
    string
    "supervisor stop manifest status"
    "cancelled"
    (UT.turn_plan_manifest_status stopped);
  check
    (option string)
    "supervisor stop terminal reason"
    (Some "supervisor_stop")
    stopped.turn_plan_terminal_reason_code
;;

let test_provider_attempt_records_manifest_decision_contract () =
  let provenance : KRun.provider_attempt_provenance =
    { model_source = "named_cascade"
    ; resolved_model_source = "cascade_catalog_binding"
    ; capability_source = "provider_config_from_cascade_catalog"
    ; fallback_authority = "declared_cascade"
    ; provider_source_cascade = Some "phase_buffer"
    }
  in
  let open Yojson.Safe.Util in
  let started =
    KRun.provider_attempt_started_decision
      { started_provenance = provenance
      ; started_is_last = false
      ; started_per_provider_timeout_s = Some 12.5
      }
  in
  check
    string
    "started model source"
    "named_cascade"
    (started |> member "model_source" |> to_string);
  check
    string
    "started provider source cascade"
    "phase_buffer"
    (started |> member "provider_source_cascade" |> to_string);
  check bool "started is not last" false (started |> member "is_last" |> to_bool);
  check
    (float 0.0)
    "started timeout"
    12.5
    (started |> member "per_provider_timeout_s" |> to_float);
  let finished =
    KRun.provider_attempt_finished_decision
      { finished_provenance = provenance
      ; finished_status = "timeout"
      ; finished_latency_ms = 250.0
      ; finished_checkpoint_after_present = false
      ; finished_error = `String "Eio.Time.Timeout"
      ; finished_exception_kind = Some "outer_oas_timeout"
      }
  in
  check
    string
    "finished exception kind"
    "outer_oas_timeout"
    (finished |> member "exception_kind" |> to_string);
  check
    string
    "finished resolved model source"
    "cascade_catalog_binding"
    (finished |> member "resolved_model_source" |> to_string);
  check (float 0.0) "finished latency" 250.0 (finished |> member "latency_ms" |> to_float);
  check
    bool
    "finished checkpoint absent"
    false
    (finished |> member "checkpoint_after_present" |> to_bool);
  check string "finished error" "Eio.Time.Timeout" (finished |> member "error" |> to_string)
;;

let test_rotation_attempt_builder_records_retry_decision () =
  let retry : EC.degraded_retry =
    { next_cascade = "tool_required_fallback"
    ; fallback_reason = EC.Required_tool_contract_violation
    }
  in
  let err = Agent_sdk.Error.Internal "forced tool-choice contract failure" in
  let attempt =
    Rotation_attempt.build
      ~recorded_at:"2026-05-20T00:00:00Z"
      ~slot_release_at_phase:Receipt.Retry_scheduled
      ~productive_phase_elapsed_ms:1234
      ~retry_phase_elapsed_ms:56
      ~from_cascade:(Receipt.cascade_name_of_string "default")
      ~retry
      ~outcome:Receipt.Rotation_retry_scheduled
      err
  in
  check
    string
    "from cascade"
    "default"
    (Receipt.cascade_name_to_string attempt.from_cascade);
  check
    string
    "to cascade"
    "tool_required_fallback"
    (Receipt.cascade_name_to_string attempt.to_cascade);
  check
    string
    "fallback reason"
    "required_tool_contract_violation"
    (EC.degraded_retry_reason_to_string attempt.reason);
  check
    string
    "outcome"
    "retry_scheduled"
    (Receipt.cascade_rotation_outcome_to_string attempt.outcome);
  check
    (option string)
    "slot release phase"
    (Some "retry_scheduled")
    (Option.map Receipt.slot_release_phase_to_string attempt.slot_release_at_phase);
  check
    (option int)
    "productive phase ms"
    (Some 1234)
    attempt.productive_phase_elapsed_ms;
  check (option int) "retry phase ms" (Some 56) attempt.retry_phase_elapsed_ms;
  check
    (option string)
    "error kind"
    (Some "internal")
    (Option.map Receipt.error_kind_to_string attempt.error_kind);
  check
    (option string)
    "error message"
    (Some (Agent_sdk.Error.to_string err))
    attempt.error_message;
  check string "recorded at" "2026-05-20T00:00:00Z" attempt.recorded_at
;;

let () =
  run
    "keeper_unified_turn_pipeline_records"
    [ ( "turn_pipeline_records"
      , [ test_case
            "phase gate emits typed turn plan records"
            `Quick
            test_turn_plan_phase_gate_records_typed_contract
        ; test_case
            "provider attempt emits typed manifest records"
            `Quick
            test_provider_attempt_records_manifest_decision_contract
        ; test_case
            "rotation attempt builder records degraded retry decision"
            `Quick
            test_rotation_attempt_builder_records_retry_decision
        ] )
    ]
;;
