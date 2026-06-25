open Masc

module KH = Keeper_heartbeat_loop
module KFP = Keeper_failure_policy
module KK = Keeper_turn_holders
module KCB = Keeper_turn_runtime_budget
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

let raw_provider_timeout_error ~phase =
  Agent_sdk.Error.Provider
    (Llm_provider.Error.Timeout
       { provider = "test_provider"
       ; timeout_phase = phase
       ; detail = "provider timeout"
       })

let raw_api_timeout_error () =
  Agent_sdk.Error.Api
    (Llm_provider.Retry.Timeout
       { message = "Per-provider timeout after 90.0s"; phase = None })

let turn_timeout_error () =
  KTD.sdk_error_of_masc_internal_error (KTD.Turn_timeout { elapsed_sec = 600.0 })

let ambiguous_post_commit_error () =
  KTD.sdk_error_of_masc_internal_error
    (KTD.Ambiguous_post_commit
       { is_timeout = true
       ; tools = [ "keeper_board_post" ]
       ; original_error = "provider timeout after board post"
       })

let legacy_ambiguous_internal_error () =
  Agent_sdk.Error.Internal
    "turn outcome ambiguous after committed mutating tool call(s): []; \
     original_error=provider_timeout"

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

let test_raw_oas_provider_timeout_uses_same_policy () =
  let err =
    raw_provider_timeout_error
      ~phase:
        (Some
           (Llm_provider.Http_client.Stream_idle
              Llm_provider.Http_client.Streaming_thinking))
  in
  Alcotest.(check bool)
    "raw provider timeout is a provider timeout"
    true
    (EC.is_provider_timeout_error err);
  Alcotest.(check bool)
    "raw provider timeout cycle failure is warn"
    true
    (EC.should_warn_keeper_cycle_failed err);
  match
    KH.provider_timeout_policy_decision
      ~strikes:KK.provider_timeout_strike_limit
      err
  with
  | None -> Alcotest.fail "expected provider timeout policy decision"
  | Some decision ->
    Alcotest.(check string)
      "reason preserves OAS timeout phase"
      "provider_timeout_loop:stream_idle:streaming_thinking"
      decision.reason

let test_raw_oas_api_timeout_uses_same_policy () =
  let err = raw_api_timeout_error () in
  Alcotest.(check bool)
    "raw API timeout is a provider timeout"
    true
    (EC.is_provider_timeout_error err);
  match KH.provider_timeout_policy_decision ~strikes:1 err with
  | None -> Alcotest.fail "expected provider timeout policy decision"
  | Some decision ->
    Alcotest.(check string)
      "phase-free API timeout keeps generic reason"
      "provider_timeout"
      decision.reason

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

let test_retry_timeout_budget_ignores_expired_outer_turn_budget () =
  let budget =
    KCB.resolve_bounded_provider_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:true
      ~estimated_input_tokens:10_000
      ~remaining_turn_budget_s:0.0
  in
  Alcotest.(check string)
    "retry source"
    "retry_adaptive_timeout"
    budget.source;
  Alcotest.(check bool)
    "retry keeps an actionable provider timeout"
    true
    (budget.effective_timeout_sec >= KCB.min_provider_timeout_budget_sec);
  Alcotest.(check (float 0.001))
    "remaining turn budget is telemetry only"
    0.0
    budget.remaining_turn_budget_sec

let test_first_attempt_timeout_ignores_expired_outer_turn_budget () =
  let budget =
    KCB.resolve_bounded_provider_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:false
      ~estimated_input_tokens:10_000
      ~remaining_turn_budget_s:0.0
  in
  Alcotest.(check string)
    "first attempt source"
    "first_attempt_adaptive_timeout"
    budget.source;
  Alcotest.(check bool)
    "first attempt keeps an actionable provider timeout"
    true
    (budget.effective_timeout_sec >= KCB.min_provider_timeout_budget_sec);
  Alcotest.(check (float 0.001))
    "remaining turn budget is telemetry only"
    0.0
    budget.remaining_turn_budget_sec

let test_provider_timeout_is_not_ambiguous_side_effect () =
  Alcotest.(check bool)
    "provider timeout is not ambiguous without committed tools"
    false
    (EC.is_ambiguous_side_effect_error
       (provider_timeout_error ~phase:"runtime_attempt_watchdog"))

let test_ambiguous_gate_requires_committed_tool_evidence () =
  Alcotest.(check bool)
    "provider timeout has no ambiguous commit evidence"
    false
    (EC.has_ambiguous_side_effect_commit
       ~tool_names:[]
       (provider_timeout_error ~phase:"runtime_attempt_watchdog"));
  Alcotest.(check bool)
    "legacy ambiguous string without committed tools has no gate evidence"
    false
    (EC.has_ambiguous_side_effect_commit
       ~tool_names:[]
       (legacy_ambiguous_internal_error ()));
  Alcotest.(check (list string))
    "structured ambiguous error carries mutating tool evidence"
    [ "keeper_board_post" ]
    (EC.ambiguous_side_effect_commit_tools
       ~tool_names:[]
       (ambiguous_post_commit_error ()))

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

let test_runtime_provider_path_has_no_cumulative_run_timeout () =
  let source = read_file "lib/keeper/keeper_turn_driver_try_provider.ml" in
  Alcotest.(check bool)
    "runtime provider path does not timeout Runtime_agent.run"
    false
    (contains_substring source "Eio.Time.with_timeout_exn clock t run_fn")

let test_runtime_provider_path_does_not_forward_execution_idle_timeout () =
  let source = read_file "lib/keeper/keeper_turn_driver_try_provider.ml" in
  Alcotest.(check bool)
    "runtime provider path does not forward execution idle timeout"
    false
    (contains_substring source "execution_idle_timeout_s = ctx.execution_idle_timeout_s")

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
        Alcotest.test_case "raw OAS provider timeout uses same policy" `Quick
          test_raw_oas_provider_timeout_uses_same_policy;
        Alcotest.test_case "raw OAS API timeout uses same policy" `Quick
          test_raw_oas_api_timeout_uses_same_policy;
        Alcotest.test_case "TLS handshake internal error is transient" `Quick
          test_tls_handshake_internal_error_is_transient;
        Alcotest.test_case
          "retry timeout budget ignores expired outer turn budget"
          `Quick
          test_retry_timeout_budget_ignores_expired_outer_turn_budget;
        Alcotest.test_case
          "first attempt timeout ignores expired outer turn budget"
          `Quick
          test_first_attempt_timeout_ignores_expired_outer_turn_budget;
        Alcotest.test_case
          "provider timeout is not ambiguous partial commit"
          `Quick
          test_provider_timeout_is_not_ambiguous_side_effect;
        Alcotest.test_case
          "ambiguous gate requires committed tool evidence"
          `Quick
          test_ambiguous_gate_requires_committed_tool_evidence;
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
        Alcotest.test_case "runtime provider path has no cumulative timeout" `Quick
          test_runtime_provider_path_has_no_cumulative_run_timeout;
        Alcotest.test_case "runtime provider path does not forward idle timeout" `Quick
          test_runtime_provider_path_does_not_forward_execution_idle_timeout;
      ] );
  ]
