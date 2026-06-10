open Alcotest

module Policy = Keeper_failure_policy

let check_lifecycle label expected actual =
  check string label expected (Policy.lifecycle_effect_to_label actual)
;;

let check_circuit label expected actual =
  check string label expected (Policy.circuit_effect_to_label actual)
;;

let check_scope label expected actual =
  check string label expected (Policy.failure_scope_to_label actual)
;;

let check_action label expected actual =
  check string label expected (Policy.operator_action_to_label actual)
;;

let test_stream_idle_thinking_label_round_trips () =
  let phase = Policy.Stream_idle Policy.Streaming_thinking in
  check string
    "thinking timeout label"
    "stream_idle:streaming_thinking"
    (Policy.timeout_phase_to_label phase);
  match Policy.timeout_phase_of_label "stream_idle:streaming_thinking" with
  | Some parsed ->
    check bool "thinking phase round-trips" true (parsed = phase);
    check bool
      "thinking is streaming activity"
      true
      (Policy.timeout_phase_is_streaming_activity parsed)
  | None -> fail "stream_idle:streaming_thinking did not parse"
;;

let test_stream_idle_awaiting_delta_is_not_activity () =
  let phase = Policy.Stream_idle Policy.Awaiting_first_delta in
  check bool
    "awaiting first delta is not streaming activity"
    false
    (Policy.timeout_phase_is_streaming_activity phase)
;;

let test_operational_timeout_phase_aliases () =
  let cases =
    [
      "admission", Policy.Admission;
      "admission_queue_timeout", Policy.Queue;
      "no_first_token", Policy.First_token;
      "stream_idle", Policy.Stream_idle Policy.Streaming_unknown;
      "max_execution_time", Policy.Wall_clock;
      "capacity_backpressure", Policy.Capacity_backpressure;
    ]
  in
  List.iter
    (fun (label, expected) ->
       match Policy.timeout_phase_of_label label with
       | Some actual -> check bool label true (actual = expected)
       | None -> fail (label ^ " did not parse"))
    cases
;;

let test_provider_streaming_thinking_timeout_does_not_kill_keeper () =
  let decision =
    Policy.decide
      (Policy.Provider_timeout
         {
           phase = Some (Policy.Stream_idle Policy.Streaming_thinking);
           strikes = None;
           liveness = Policy.In_turn_progress;
         })
  in
  check_scope "scope" "provider" decision.failure_scope;
  check_lifecycle "lifecycle" "soft_fail_turn" decision.lifecycle_effect;
  check_circuit "circuit" "provider_cooldown" decision.circuit_effect;
  check_action "action" "inspect_provider_stream" decision.operator_action;
  check bool "keeper death not allowed" false (Policy.should_kill_keeper decision);
  check string
    "reason"
    "provider_stream_idle_active:streaming_thinking"
    decision.reason
;;

let test_provider_capacity_backpressure_reroutes_provider () =
  let decision =
    Policy.decide
      (Policy.Provider_timeout
         {
           phase = Some Policy.Capacity_backpressure;
           strikes = None;
           liveness = Policy.Recent_heartbeat;
         })
  in
  check_scope "scope" "provider" decision.failure_scope;
  check_lifecycle "lifecycle" "soft_fail_turn" decision.lifecycle_effect;
  check_circuit "circuit" "provider_cooldown" decision.circuit_effect;
  check_action "action" "reroute_or_tune_provider" decision.operator_action;
  check string "reason" "provider_timeout:capacity_backpressure" decision.reason
;;

let test_provider_timeout_strike_capacity_backpressure_reroutes_provider () =
  let decision =
    Policy.decide
      (Policy.Provider_timeout
         {
           phase = Some Policy.Capacity_backpressure;
           strikes = Some 1;
           liveness = Policy.Recent_heartbeat;
         })
  in
  check_scope "scope" "provider" decision.failure_scope;
  check_lifecycle "lifecycle" "soft_fail_turn" decision.lifecycle_effect;
  check_circuit "circuit" "provider_cooldown" decision.circuit_effect;
  check_action "action" "reroute_or_tune_provider" decision.operator_action;
  check string "reason" "provider_timeout:capacity_backpressure" decision.reason
;;

let test_provider_timeout_loop_with_live_keeper_pauses_work_not_keeper () =
  let decision =
    Policy.decide
      (Policy.Provider_timeout
         {
           phase = Some Policy.Wall_clock;
           strikes = Some 3;
           liveness = Policy.Recent_heartbeat;
         })
  in
  check_scope "scope" "provider" decision.failure_scope;
  check_lifecycle "lifecycle" "pause_current_work" decision.lifecycle_effect;
  check_circuit "circuit" "provider_cooldown" decision.circuit_effect;
  check_action "action" "reroute_or_tune_provider" decision.operator_action;
  check bool "keeper death not allowed" false (Policy.should_kill_keeper decision);
  check string "reason" "provider_timeout_loop:wall_clock" decision.reason
;;

let test_provider_timeout_loop_with_lost_liveness_pauses_keeper_without_death () =
  let decision =
    Policy.decide
      (Policy.Provider_timeout
         {
           phase = Some Policy.Wall_clock;
           strikes = Some 3;
           liveness = Policy.No_recent_heartbeat;
         })
  in
  check_scope "scope" "keeper_liveness" decision.failure_scope;
  check_lifecycle "lifecycle" "pause_keeper" decision.lifecycle_effect;
  check_circuit "circuit" "operator_breaker" decision.circuit_effect;
  check_action "action" "inspect_keeper_liveness" decision.operator_action;
  check bool "keeper death not allowed" false (Policy.should_kill_keeper decision);
  check string "reason" "keeper_liveness_lost_after_timeout:wall_clock" decision.reason
;;

let test_workflow_rejection_skips_keeper_circuit () =
  let decision =
    Policy.decide
      (Policy.Workflow_rejection { rule_id = Some "rate_limit" })
  in
  check_scope "scope" "invocation" decision.failure_scope;
  check_lifecycle "lifecycle" "keep_running" decision.lifecycle_effect;
  check_circuit "circuit" "skip_circuit" decision.circuit_effect;
  check_action "action" "fix_invocation" decision.operator_action;
  check string "reason" "workflow_rejection:rate_limit" decision.reason
;;

let test_only_liveness_failures_allow_keeper_death () =
  check bool
    "stale_turn with progress false kills keeper"
    true
    (Policy.should_kill_keeper
       (Policy.decide (Policy.Stale_turn { progress_seen = false })));
  check bool
    "stale_turn with progress true does not kill"
    false
    (Policy.should_kill_keeper
       (Policy.decide (Policy.Stale_turn { progress_seen = true })));
  check bool
    "provider timeout with heartbeat lost does not allow death"
    false
    (Policy.should_kill_keeper
       (Policy.decide
          (Policy.Provider_timeout
             { phase = None; strikes = None; liveness = Policy.No_recent_heartbeat })));
  check bool
    "fatal environment allows keeper death"
    true
    (Policy.should_kill_keeper
       (Policy.decide (Policy.Fatal_environment { detail = None })));
  check bool
    "turn_failure_streak does not kill keeper"
    false
    (Policy.should_kill_keeper
       (Policy.decide (Policy.Turn_failure_streak { count = 5 })));
  check bool
    "turn_overflow_pause does not kill keeper"
    false
    (Policy.should_kill_keeper (Policy.decide Policy.Turn_overflow_pause))
;;

(* --- Coverage for newly-exported functions --- *)

let test_make_decision_constructs_record () =
  let d =
    Policy.make_decision
      ~failure_scope:Policy.Invocation_scope
      ~lifecycle_effect:Policy.Soft_fail_turn
      ~circuit_effect:Policy.Skip_circuit
      ~operator_action:Policy.Fix_invocation
      ~keeper_death_allowed:false
      ~reason:"test"
  in
  check_scope "scope" "invocation" d.failure_scope;
  check_lifecycle "lifecycle" "soft_fail_turn" d.lifecycle_effect;
  check_circuit "circuit" "skip_circuit" d.circuit_effect;
  check_action "action" "fix_invocation" d.operator_action;
  check bool "keeper_death_allowed" false d.keeper_death_allowed;
  check string "reason" "test" d.reason
;;

let test_liveness_is_lost_classification () =
  let label_of = function
    | Policy.Recent_heartbeat -> "Recent_heartbeat"
    | Policy.In_turn_progress -> "In_turn_progress"
    | Policy.Watchdog_stale -> "Watchdog_stale"
    | Policy.No_recent_heartbeat -> "No_recent_heartbeat"
    | Policy.Unknown_liveness -> "Unknown_liveness"
  in
  let all_cases =
    [
      Policy.Recent_heartbeat, false;
      Policy.In_turn_progress, false;
      Policy.Watchdog_stale, true;
      Policy.No_recent_heartbeat, true;
      Policy.Unknown_liveness, false;
    ]
  in
  List.iter
    (fun (evidence, expected) ->
       let tag = label_of evidence in
       let actual = Policy.liveness_is_lost evidence in
       check bool (tag ^ " liveness_is_lost") expected actual)
    all_cases
;;

let test_provider_timeout_policy_effect_matrix () =
  let cases =
    [
      (Some Policy.Capacity_backpressure, None, Policy.Recent_heartbeat,
       "soft_fail_turn", "provider_cooldown", "reroute_or_tune_provider", "provider_timeout");
      (Some Policy.Wall_clock, Some 3, Policy.Recent_heartbeat,
       "pause_current_work", "provider_cooldown", "reroute_or_tune_provider", "provider_timeout_loop");
      (Some Policy.Wall_clock, Some 3, Policy.No_recent_heartbeat,
       "pause_keeper", "operator_breaker", "inspect_keeper_liveness", "keeper_liveness_lost_after_timeout");
      (Some (Policy.Stream_idle Policy.Streaming_thinking), None, Policy.In_turn_progress,
       "soft_fail_turn", "provider_cooldown", "inspect_provider_stream", "provider_timeout");
      (None, None, Policy.Recent_heartbeat,
       "soft_fail_turn", "provider_cooldown", "inspect_provider_stream", "provider_timeout");
      (None, Some 1, Policy.Watchdog_stale,
       "soft_fail_turn", "provider_cooldown", "inspect_provider_stream", "provider_timeout");
    ]
  in
  List.iteri
    (fun i (phase, strikes, liveness, exp_life, exp_circ, exp_action, snippet) ->
       let lifecycle, circuit, action, reason =
         Policy.provider_timeout_policy_effect ~phase ~strikes ~liveness
       in
       let prefix = "case_" ^ string_of_int i ^ "_" ^ snippet in
       check_lifecycle (prefix ^ "_lifecycle") exp_life lifecycle;
       check_circuit (prefix ^ "_circuit") exp_circ circuit;
       check_action (prefix ^ "_action") exp_action action;
       check string (prefix ^ "_reason_mentions") snippet reason)
    cases
;;

let () =
  run "keeper_failure_policy"
    [
      ( "timeout_phase",
        [
          test_case "stream_idle:streaming_thinking parses as activity" `Quick
            test_stream_idle_thinking_label_round_trips;
          test_case "awaiting first delta is not activity" `Quick
            test_stream_idle_awaiting_delta_is_not_activity;
          test_case "operational timeout phase aliases parse" `Quick
            test_operational_timeout_phase_aliases;
        ] );
      ( "decision_matrix",
        [
          test_case "provider streaming thinking timeout stays provider-scoped" `Quick
            test_provider_streaming_thinking_timeout_does_not_kill_keeper;
          test_case "provider capacity backpressure reroutes provider" `Quick
            test_provider_capacity_backpressure_reroutes_provider;
          test_case "legacy timeout-budget capacity backpressure reroutes provider" `Quick
            test_provider_timeout_strike_capacity_backpressure_reroutes_provider;
          test_case "live OAS budget loop pauses work, not keeper" `Quick
            test_provider_timeout_loop_with_live_keeper_pauses_work_not_keeper;
          test_case "lost-liveness OAS budget loop pauses keeper without death" `Quick
            test_provider_timeout_loop_with_lost_liveness_pauses_keeper_without_death;
          test_case "workflow rejection skips keeper circuit" `Quick
            test_workflow_rejection_skips_keeper_circuit;
          test_case "keeper death is liveness-only" `Quick
            test_only_liveness_failures_allow_keeper_death;
        ] );
      ( "interface_coverage",
        [
          test_case "make_decision constructs correct record" `Quick
            test_make_decision_constructs_record;
          test_case "liveness_is_lost classifies all evidence variants" `Quick
            test_liveness_is_lost_classification;
          test_case "provider_timeout_policy_effect matrix" `Quick
            test_provider_timeout_policy_effect_matrix;
        ] );
    ]
