open Masc_mcp

module KH = Keeper_heartbeat_loop
module KFP = Keeper_failure_policy
module KK = Keeper_keepalive
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
  (match KK.classify_oas_timeout_budget_strike ~strikes:1 with
   | KK.Oas_timeout_budget_warn -> ()
   | KK.Oas_timeout_budget_soft_backoff -> failwith "strike 1 should warn");
  (match
     KK.classify_oas_timeout_budget_strike
       ~strikes:KK.oas_timeout_budget_strike_limit
   with
   | KK.Oas_timeout_budget_soft_backoff -> ()
   | KK.Oas_timeout_budget_warn ->
     failwith "strike limit should soft-backoff, not crash")

let oas_timeout_budget_error ~phase =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Oas_timeout_budget
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

let test_cycle_failed_log_level_is_policy_aware () =
  Alcotest.(check bool)
    "oas timeout budget cycle failure is warn"
    true
    (EC.should_warn_keeper_cycle_failed
       (oas_timeout_budget_error ~phase:"cascade_attempt_watchdog"));
  Alcotest.(check bool)
    "turn wall-clock timeout remains error"
    false
    (EC.should_warn_keeper_cycle_failed (turn_timeout_error ()))

let test_strike_limit_routes_through_policy_without_keeper_death () =
  let err = oas_timeout_budget_error ~phase:"stream_idle:streaming_thinking" in
  match
    KH.oas_timeout_budget_policy_decision
      ~strikes:KK.oas_timeout_budget_strike_limit
      err
  with
  | None -> Alcotest.fail "expected OAS timeout budget policy decision"
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
      "oas_timeout_budget_loop:stream_idle:streaming_thinking"
      decision.reason

let test_capacity_phase_routes_to_provider_tuning () =
  let err = oas_timeout_budget_error ~phase:"capacity_backpressure" in
  match KH.oas_timeout_budget_policy_decision ~strikes:1 err with
  | None -> Alcotest.fail "expected OAS timeout budget policy decision"
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
      "oas_timeout_budget:capacity_backpressure"
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

let () =
  Alcotest.run "oas_timeout_budget_strike"
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
        Alcotest.test_case "strike limit uses policy, not keeper death" `Quick
          test_strike_limit_routes_through_policy_without_keeper_death;
        Alcotest.test_case "capacity phase routes to provider tuning" `Quick
          test_capacity_phase_routes_to_provider_tuning;
        Alcotest.test_case "concurrent bumps do not lose updates" `Quick
          test_concurrent_bumps_do_not_lose_updates;
      ] );
  ]
