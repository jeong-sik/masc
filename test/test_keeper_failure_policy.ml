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
           phase = Some Policy.Caller_budget;
           strikes = Some 6;
           liveness = Policy.Recent_heartbeat;
         })
  in
  check_scope "scope" "provider" decision.failure_scope;
  check_lifecycle "lifecycle" "pause_current_work" decision.lifecycle_effect;
  check_circuit "circuit" "provider_cooldown" decision.circuit_effect;
  check_action "action" "reroute_or_tune_provider" decision.operator_action;
  check bool "keeper death not allowed" false (Policy.should_kill_keeper decision)
;;

let test_provider_timeout_loop_with_lost_liveness_pauses_keeper_without_death () =
  let decision =
    Policy.decide
      (Policy.Provider_timeout
         {
           phase = Some (Policy.Stream_idle Policy.Awaiting_first_event);
           strikes = Some 3;
           liveness = Policy.Watchdog_stale;
         })
  in
  check_lifecycle "lifecycle" "pause_keeper" decision.lifecycle_effect;
  check_circuit "circuit" "operator_breaker" decision.circuit_effect;
  check_action "action" "inspect_keeper_liveness" decision.operator_action;
  check bool "keeper death not allowed" false (Policy.should_kill_keeper decision)
;;

let test_workflow_rejection_skips_keeper_circuit () =
  let decision =
    Policy.decide
      (Policy.Workflow_rejection { rule_id = Some "command_chaining_blocked" })
  in
  check_scope "scope" "invocation" decision.failure_scope;
  check_lifecycle "lifecycle" "keep_running" decision.lifecycle_effect;
  check_circuit "circuit" "skip_circuit" decision.circuit_effect;
  check_action "action" "fix_invocation" decision.operator_action;
  check bool "keeper death not allowed" false (Policy.should_kill_keeper decision)
;;

let test_turn_overflow_pause_is_operator_breaker () =
  let decision = Policy.decide Policy.Turn_overflow_pause in
  check_scope "scope" "turn" decision.failure_scope;
  check_lifecycle "lifecycle" "pause_keeper" decision.lifecycle_effect;
  check_circuit "circuit" "operator_breaker" decision.circuit_effect;
  check_action "action" "inspect_keeper_liveness" decision.operator_action;
  check bool "keeper death not allowed" false (Policy.should_kill_keeper decision);
  check string "reason" "turn_overflow_pause" decision.reason
;;

let test_only_liveness_failures_allow_keeper_death () =
  let non_liveness_failures =
    [
      Policy.Transient_provider_failure;
      Policy.Runtime_exhausted { retryable = false };
      Policy.Stale_turn { progress_seen = true };
      Policy.Stale_termination_storm { count = 6 };
      Policy.Ambiguous_partial_commit;
    ]
  in
  List.iter
    (fun failure ->
       let decision = Policy.decide failure in
       check bool
         ("keeper death blocked for " ^ decision.reason)
         false
         (Policy.should_kill_keeper decision))
    non_liveness_failures;
  let fatal =
    Policy.decide (Policy.Fatal_environment { detail = Some "missing_eio_switch" })
  in
  check bool "fatal env can restart keeper" true (Policy.should_kill_keeper fatal);
  let stale = Policy.decide (Policy.Stale_turn { progress_seen = false }) in
  check bool "stale no progress can restart keeper" true (Policy.should_kill_keeper stale)
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
          test_case "turn overflow pause is an operator breaker" `Quick
            test_turn_overflow_pause_is_operator_breaker;
          test_case "keeper death is liveness-only" `Quick
            test_only_liveness_failures_allow_keeper_death;
        ] );
    ]
