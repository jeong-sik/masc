(** test_keeper_fsm_guard_actions — verify the runtime safety wrapper
    [Keeper_fsm_guard_runtime.wrap_unit] used by KeeperHeartbeat /
    KeeperTaskAcquisition spec-action guards.

    The PPX [@@fsm_guard] itself is exercised by the smoke test at
    [keeper_turn_fsm.ml:118] (Cycle 12 / Tier I3); this file pins the
    surrounding policy contract:

    1. The Prometheus counter constant matches the documented series.
    2. An honest thunk (no assert raised) leaves the counter alone.
    3. A buggy thunk (raises [Assert_failure], simulating a PPX-injected
       guard that observed a spec violation) bumps the counter by one
       and re-raises.
    4. [MASC_FSM_GUARD_ASSERT=0] no longer enables counter-only mode.
    5. Non-[Assert_failure] exceptions propagate unchanged — only the
       spec-violation channel is intercepted. *)

module P = Masc_mcp.Prometheus
module G = Masc_mcp.Keeper_fsm_guard_runtime

let counter_name = P.metric_fsm_guard_violation

let read_count ~action ~stage =
  P.metric_value_or_zero counter_name
    ~labels:[ ("action", action); ("stage", stage) ]
    ()

let test_counter_constant_is_stable () =
  Alcotest.(check string)
    "metric name matches the documented Prometheus series"
    "masc_fsm_guard_violation_total"
    counter_name

let test_honest_thunk_leaves_counter_alone () =
  let action = "TestAction" in
  let stage = "honest" in
  let before = read_count ~action ~stage in
  G.wrap_unit ~action ~stage (fun () -> ());
  let after = read_count ~action ~stage in
  Alcotest.(check (float 0.0001))
    "honest thunk does not bump the counter"
    before after

(* Verify the env-invariance contract: [MASC_FSM_GUARD_ASSERT] is no
   longer a runtime escape hatch (PR #17974 removed the soft-mode
   pathway). [wrap_unit] always re-raises [Assert_failure] and bumps
   the counter regardless of the env value. Replaces three earlier
   tests (env=0 / env="" / env=1) that exercised the now-removed env
   switch through [refresh_policy_for_test] / [assert_mode_for_test]
   test backdoors. *)
let test_assert_mode_invariant_under_env () =
  let action = "TestAction" in
  let stage = "env_invariant" in
  List.iter
    (fun env_value ->
      Unix.putenv "MASC_FSM_GUARD_ASSERT" env_value;
      let before = read_count ~action ~stage in
      let raised =
        try
          G.wrap_unit ~action ~stage (fun () -> assert false);
          false
        with Assert_failure _ -> true
      in
      let after = read_count ~action ~stage in
      Alcotest.(check bool)
        (Printf.sprintf "Assert_failure propagates with env=%S" env_value)
        true raised;
      Alcotest.(check (float 0.0001))
        (Printf.sprintf "counter bumped before re-raise with env=%S" env_value)
        (before +. 1.0) after)
    [ "0"; ""; "1" ];
  Unix.putenv "MASC_FSM_GUARD_ASSERT" ""

let test_non_assert_exception_propagates_unchanged () =
  let action = "TestAction" in
  let stage = "non_assert" in
  let before = read_count ~action ~stage in
  let raised =
    try
      G.wrap_unit ~action ~stage (fun () -> failwith "domain error");
      false
    with Failure _ -> true
  in
  let after = read_count ~action ~stage in
  Alcotest.(check bool)
    "Failure propagates without being swallowed"
    true raised;
  Alcotest.(check (float 0.0001))
    "counter is NOT bumped for non-Assert_failure exceptions"
    before after

let test_distinct_action_label_isolation () =
  let stage = "iso" in
  let action_a = "ActionA" in
  let action_b = "ActionB" in
  let a_before = read_count ~action:action_a ~stage in
  let b_before = read_count ~action:action_b ~stage in
  let raised =
    try
      G.wrap_unit ~action:action_a ~stage (fun () -> assert false);
      false
    with Assert_failure _ -> true
  in
  let a_after = read_count ~action:action_a ~stage in
  let b_after = read_count ~action:action_b ~stage in
  Alcotest.(check bool)
    "action A violation re-raises"
    true raised;
  Alcotest.(check (float 0.0001))
    "action A counter bumped"
    (a_before +. 1.0) a_after;
  Alcotest.(check (float 0.0001))
    "action B counter unchanged when only A is exercised"
    b_before b_after

let () =
  let open Alcotest in
  run "keeper_fsm_guard_actions" [
    "metric constant", [
      test_case "name matches documented series" `Quick
        test_counter_constant_is_stable;
    ];
    "fail closed", [
      test_case "honest thunk does not bump" `Quick
        test_honest_thunk_leaves_counter_alone;
      test_case "non-assert exception propagates" `Quick
        test_non_assert_exception_propagates_unchanged;
      test_case "action label isolation" `Quick
        test_distinct_action_label_isolation;
    ];
    "assert mode", [
      test_case "assert behavior invariant under MASC_FSM_GUARD_ASSERT env" `Quick
        test_assert_mode_invariant_under_env;
    ];
  ]
