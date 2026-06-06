open Masc

module KH = Keeper_heartbeat_loop
module KFP = Keeper_failure_policy
module KK = Keeper_keepalive
module KCB = Keeper_turn_runtime_budget
module KAL = Keeper_attempt_liveness_config
module KTD = Keeper_turn_driver
module EC = Keeper_error_classify

let with_reset keeper f =
  KK.reset_budget_exhaustion ~keeper_name:keeper;
  Fun.protect
    ~finally:(fun () -> KK.reset_budget_exhaustion ~keeper_name:keeper)
    f

let test_seeded_bump_increments_from_prior () =
  with_reset "seeded" (fun () ->
    let strikes =
      KK.bump_budget_exhaustion_seeded
        ~keeper_name:"seeded"
        ~prior_strikes:2
    in
    Alcotest.(check int) "bump increments from 2 to 3" 3 strikes;
    Alcotest.(check int) "peek sees persisted in-process count" 3
      (KK.peek_budget_exhaustion_for_test ~keeper_name:"seeded"))

let test_in_process_bump_accumulates () =
  with_reset "in-process" (fun () ->
    Alcotest.(check int) "first" 1
      (KK.bump_budget_exhaustion ~keeper_name:"in-process");
    Alcotest.(check int) "second" 2
      (KK.bump_budget_exhaustion ~keeper_name:"in-process"))

let test_seeded_bump_uses_higher_persisted_count () =
  with_reset "seed-max" (fun () ->
    KK.set_budget_exhaustion_for_test ~keeper_name:"seed-max" ~strikes:1;
    let strikes =
      KK.bump_budget_exhaustion_seeded
        ~keeper_name:"seed-max"
        ~prior_strikes:4
    in
    Alcotest.(check int) "seed catches up to persisted count" 5 strikes)

let test_reset_clears () =
  KK.set_budget_exhaustion_for_test ~keeper_name:"reset" ~strikes:2;
  KK.reset_budget_exhaustion ~keeper_name:"reset";
  Alcotest.(check int) "reset clears" 0
    (KK.peek_budget_exhaustion_for_test ~keeper_name:"reset")

let test_strike_limit_is_soft_backoff () =
  (match KK.classify_provider_timeout_strike ~strikes:1 with
   | KK.Provider_timeout_warn -> ()
   | KK.Provider_timeout_soft_backoff -> failwith "strike 1 should warn");
  (match
     KK.classify_provider_timeout_strike
       ~strikes:KK.provider_timeout_strike_limit
   with
   | KK.Provider_timeout_soft_backoff -> ()
   | KK.Provider_timeout_warn ->
     failwith "strike limit should soft-backoff, not crash")

let provider_timeout_error ~phase =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Provider_timeout
       { budget_sec = 90.0
       ; keeper_turn_timeout_sec = 1200.0
       ; estimated_input_tokens = 10_000
       ; source = "test"
       ; remaining_turn_budget_sec = Some 42.0
       ; min_required_sec = 15.0
       ; phase
       })

let turn_timeout_error () =
  KTD.sdk_error_of_masc_internal_error (KTD.Turn_timeout { elapsed_sec = 600.0 })

let tls_handshake_internal_error () =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Internal_unhandled_exception
       { site = "runtime_runner.execute"
       ; exn_repr = "TLS alert from peer: handshake failure"
       })

let test_cycle_failed_log_level_is_policy_aware () =
  Alcotest.(check bool)
    "provider timeout cycle failure is warn"
    true
    (EC.should_warn_keeper_cycle_failed
       (provider_timeout_error ~phase:"runtime_attempt_watchdog"));
  Alcotest.(check bool)
    "turn timeout remains error"
    false
    (EC.should_warn_keeper_cycle_failed (turn_timeout_error ()))

let test_tls_handshake_internal_error_is_transient () =
  let err = tls_handshake_internal_error () in
  Alcotest.(check bool)
    "runtime_runner TLS handshake failure is a transient runner error"
    true
    (EC.is_transient_internal_runner_error err);
  Alcotest.(check bool)
    "runtime_runner TLS handshake failure enters transient network retry"
    true
    (EC.is_transient_network_error err);
  Alcotest.(check bool)
    "runtime_runner TLS handshake failure is auto-recoverable at turn level"
    true
    (EC.is_auto_recoverable_turn_error err)

let test_attempt_watchdog_timeout_reclassifies_as_provider_timeout () =
  let budget : KCB.provider_timeout_budget =
    { effective_timeout_sec = 555.0
    ; adaptive_timeout_sec = 600.0
    ; keeper_turn_timeout_sec = 600.0
    ; remaining_turn_budget_sec = 571.0
    ; estimated_input_tokens = 10_000
    ; max_turns = 6
    ; source = "turn_budget_capped"
    }
  in
  let err =
    Agent_sdk.Error.Api
      (Timeout
         { message =
             "Turn wall-clock budget exhausted during runtime attempt \
              (budget=555.0s, watchdog=570.0s)"
         })
  in
  let reclassified =
    KCB.reclassify_provider_timeout_for_attempt
      ~provider_timeout_budget:(Some budget)
      err
  in
  (match KTD.classify_masc_internal_error reclassified with
   | Some (KTD.Provider_timeout timeout) ->
     Alcotest.(check string)
       "phase"
       "runtime_attempt_watchdog"
       timeout.phase;
     Alcotest.(check (float 0.001))
       "budget"
       555.0
       timeout.budget_sec
   | Some other ->
     Alcotest.failf
       "expected Provider_timeout, got %s"
       (Option.value
          ~default:"<no summary>"
          (KTD.summary_of_masc_internal_error other))
   | None -> Alcotest.fail "expected structured Provider_timeout");
  Alcotest.(check bool)
    "provider timeout cycle failure is warn"
    true
    (EC.should_warn_keeper_cycle_failed reclassified)

let test_stream_liveness_disables_outer_attempt_watchdog () =
  let budget : KCB.provider_timeout_budget =
    { effective_timeout_sec = 555.0
    ; adaptive_timeout_sec = 600.0
    ; keeper_turn_timeout_sec = 600.0
    ; remaining_turn_budget_sec = 571.0
    ; estimated_input_tokens = 10_000
    ; max_turns = 6
    ; source = "turn_budget_capped"
    }
  in
  let select mode =
    KCB.attempt_watchdog_timeout_sec_opt
      ~liveness_mode:mode
      ~remaining_turn_budget_s:571.0
      budget
  in
  (match select KAL.Off with
   | Some actual ->
     Alcotest.(check (float 0.001)) "legacy off-mode watchdog" 570.0 actual
   | None -> Alcotest.fail "off mode should preserve the legacy watchdog");
  Alcotest.(check bool)
    "observe mode lets stream liveness own the attempt"
    true
    (Option.is_none (select KAL.Observe));
  Alcotest.(check bool)
    "enforce mode lets stream liveness own the attempt"
    true
    (Option.is_none (select KAL.Enforce))

let test_provider_timeout_is_not_ambiguous_side_effect () =
  Alcotest.(check bool)
    "provider timeout is not ambiguous without committed tools"
    false
    (EC.is_ambiguous_side_effect_error
       (provider_timeout_error ~phase:"runtime_attempt_watchdog"))

let test_turn_timeout_is_not_ambiguous_side_effect () =
  Alcotest.(check bool)
    "turn timeout is not ambiguous without committed tools"
    false
    (EC.is_ambiguous_side_effect_error (turn_timeout_error ()))

let test_strike_limit_routes_through_policy_without_keeper_death () =
  let err = provider_timeout_error ~phase:"stream_idle:streaming_thinking" in
  match
    KH.provider_timeout_policy_decision
      ~strikes:KK.provider_timeout_strike_limit
      err
  with
  | None -> Alcotest.fail "expected provider timeout policy decision"
  | Some decision ->
    Alcotest.(check bool) "keeper death denied" false decision.keeper_death_allowed;
    Alcotest.(check string)
      "lifecycle"
      "pause_current_work"
      (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
    Alcotest.(check string)
      "circuit"
      "provider_cooldown"
      (KFP.circuit_effect_to_label decision.circuit_effect);
    Alcotest.(check string)
      "reason preserves streaming thinking"
      "provider_timeout_loop:stream_idle:streaming_thinking"
      decision.reason

let test_capacity_phase_routes_to_provider_tuning () =
  let err = provider_timeout_error ~phase:"capacity_backpressure" in
  match KH.provider_timeout_policy_decision ~strikes:1 err with
  | None -> Alcotest.fail "expected provider timeout policy decision"
  | Some decision ->
    Alcotest.(check bool) "keeper death denied" false decision.keeper_death_allowed;
    Alcotest.(check string)
      "lifecycle"
      "soft_fail_turn"
      (KFP.lifecycle_effect_to_label decision.lifecycle_effect);
    Alcotest.(check string)
      "circuit"
      "provider_cooldown"
      (KFP.circuit_effect_to_label decision.circuit_effect);
    Alcotest.(check string)
      "operator action"
      "reroute_or_tune_provider"
      (KFP.operator_action_to_label decision.operator_action);
    Alcotest.(check string)
      "reason preserves capacity phase"
      "provider_timeout:capacity_backpressure"
      decision.reason

let test_concurrent_bumps_do_not_lose_updates () =
  let keeper = "parallel-bumps" in
  with_reset keeper (fun () ->
    let workers = 4 in
    let bumps_per_worker = 25 in
    let domains =
      List.init workers (fun _ ->
        Domain.spawn (fun () ->
          for _ = 1 to bumps_per_worker do
            ignore (KK.bump_budget_exhaustion ~keeper_name:keeper : int)
          done))
    in
    List.iter Domain.join domains;
    Alcotest.(check int) "all bumps accounted"
      (workers * bumps_per_worker)
      (KK.peek_budget_exhaustion_for_test ~keeper_name:keeper))

let read_file path = In_channel.with_open_text path In_channel.input_all

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

let test_keeper_turn_has_no_total_wall_clock_kill () =
  let source = read_file "lib/keeper/keeper_unified_turn_execution.ml" in
  Alcotest.(check bool)
    "no cumulative keeper turn with_timeout"
    false
    (contains_substring source "Eio.Time.with_timeout_exn clock timeout_sec")

let test_keeper_oas_path_has_no_bridge_total_timeout () =
  let source = read_file "lib/keeper/keeper_agent_run.ml" in
  Alcotest.(check bool)
    "keeper run_named path is not bridge-timeout wrapped"
    false
    (contains_substring source "Keeper_llm_bridge.run_with_timeout_and_fallback")

let () =
  Alcotest.run "provider_timeout_strike"
  [
    ( "strike ledger",
      [
        Alcotest.test_case "seeded bump increments" `Quick
          test_seeded_bump_increments_from_prior;
        Alcotest.test_case "in-process bump accumulates" `Quick
          test_in_process_bump_accumulates;
        Alcotest.test_case "seeded bump uses higher persisted count" `Quick
          test_seeded_bump_uses_higher_persisted_count;
        Alcotest.test_case "reset clears" `Quick test_reset_clears;
        Alcotest.test_case "strike limit soft-backoffs without crash" `Quick
          test_strike_limit_is_soft_backoff;
        Alcotest.test_case "cycle failure log level is policy-aware" `Quick
          test_cycle_failed_log_level_is_policy_aware;
        Alcotest.test_case "TLS handshake internal error is transient" `Quick
          test_tls_handshake_internal_error_is_transient;
        Alcotest.test_case
          "attempt watchdog timeout reclassifies as provider timeout"
          `Quick
          test_attempt_watchdog_timeout_reclassifies_as_provider_timeout;
        Alcotest.test_case
          "stream liveness disables outer attempt watchdog"
          `Quick
          test_stream_liveness_disables_outer_attempt_watchdog;
        Alcotest.test_case
          "provider timeout is not ambiguous partial commit"
          `Quick
          test_provider_timeout_is_not_ambiguous_side_effect;
        Alcotest.test_case
          "turn timeout is not ambiguous partial commit"
          `Quick
          test_turn_timeout_is_not_ambiguous_side_effect;
        Alcotest.test_case "strike limit uses policy, not keeper death" `Quick
          test_strike_limit_routes_through_policy_without_keeper_death;
        Alcotest.test_case "capacity phase routes to provider tuning" `Quick
          test_capacity_phase_routes_to_provider_tuning;
        Alcotest.test_case "concurrent bumps do not lose updates" `Quick
          test_concurrent_bumps_do_not_lose_updates;
        Alcotest.test_case "keeper turn has no total wall-clock kill" `Quick
          test_keeper_turn_has_no_total_wall_clock_kill;
        Alcotest.test_case "keeper OAS path has no bridge total timeout" `Quick
          test_keeper_oas_path_has_no_bridge_total_timeout;
      ] );
  ]
