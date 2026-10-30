(** test_keeper_fsm_guard_actions — verify the runtime safety wrapper
    [Keeper_fsm_guard_runtime.wrap_unit] used by Keeper heartbeat actions.

    The PPX [@@fsm_guard] itself is exercised by the smoke test at
    [keeper_turn_fsm.ml:118] (Cycle 12 / Tier I3); this file pins the
    surrounding policy contract:

    1. The Otel_metric_store counter constant matches the documented series.
    2. An honest thunk (no assert raised) leaves the counter alone.
    3. A buggy thunk (raises [Assert_failure], simulating a PPX-injected
       guard that observed a spec violation) bumps the counter by one
       and re-raises.
    4. [MASC_FSM_GUARD_ASSERT=0] no longer enables counter-only mode.
    5. Non-[Assert_failure] exceptions propagate unchanged — only the
       spec-violation channel is intercepted. *)

module P = Masc.Otel_metric_store
module G = Masc.Keeper_fsm_guard_runtime

let counter_name = P.metric_fsm_guard_violation

let read_count ~action ~stage =
  P.metric_value_or_zero counter_name
    ~labels:[ ("action", action); ("stage", stage) ]
    ()

let test_counter_constant_is_stable () =
  Alcotest.(check string)
    "metric name matches the documented Otel_metric_store series"
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

let test_env_zero_still_reraises_and_bumps () =
  Unix.putenv "MASC_FSM_GUARD_ASSERT" "0";
  let action = "TestAction" in
  let stage = "env_zero_assert" in
  let before = read_count ~action ~stage in
  let raised =
    try
      G.wrap_unit ~action ~stage (fun () -> assert false);
      false
    with Assert_failure _ -> true
  in
  let after = read_count ~action ~stage in
  Alcotest.(check bool)
    "Assert_failure propagates even with env zero"
    true raised;
  Alcotest.(check (float 0.0001))
    "Assert_failure counter bumped by one before re-raise"
    (before +. 1.0) after

(* [Unix.putenv NAME ""] is the repo convention for clearing env in tests
   (matched in [test_board_vote_quarantine.ml:17] and siblings). *)
let test_default_is_assert_mode_when_env_cleared () =
  Unix.putenv "MASC_FSM_GUARD_ASSERT" "";
  let action = "TestAction" in
  let stage = "default_assert" in
  let before = read_count ~action ~stage in
  let raised =
    try
      G.wrap_unit ~action ~stage (fun () -> assert false);
      false
    with Assert_failure _ -> true
  in
  let after = read_count ~action ~stage in
  Alcotest.(check bool)
    "buggy thunk re-raises under default assert mode"
    true raised;
  Alcotest.(check (float 0.0001))
    "counter is bumped before re-raise under default mode"
    (before +. 1.0) after

let test_buggy_thunk_reraises () =
  Unix.putenv "MASC_FSM_GUARD_ASSERT" "1";
  let action = "TestAction" in
  let stage = "buggy_assert" in
  let before = read_count ~action ~stage in
  let raised =
    try
      G.wrap_unit ~action ~stage (fun () -> assert false);
      false
    with Assert_failure _ -> true
  in
  let after = read_count ~action ~stage in
  Alcotest.(check bool)
    "Assert_failure propagates in assert mode"
    true raised;
  Alcotest.(check (float 0.0001))
    "counter is bumped before re-raise"
    (before +. 1.0) after;
  (* Restore default assert mode for any subsequent tests. *)
  Unix.putenv "MASC_FSM_GUARD_ASSERT" ""

let test_non_assert_exception_propagates_unchanged () =
  (* RFC-0072 Phase 5 widened the catch to all exceptions so typed
     transition violations (Runtime_transition_violation /
     Turn_phase_transition_violation, which would otherwise create a
     Keeper_registry → this-module dependency cycle if named) are also
     captured. That means any exception escaping the thunk bumps the
     counter and re-raises with the backtrace intact — the no-bump
     guarantee from the pre-Phase-5 narrow catch no longer holds. *)
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
    "counter bumps for any exception under widened catch"
    (before +. 1.0) after

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
      test_case "env zero still re-raises + bumps" `Quick
        test_env_zero_still_reraises_and_bumps;
      test_case "non-assert exception propagates" `Quick
        test_non_assert_exception_propagates_unchanged;
      test_case "action label isolation" `Quick
        test_distinct_action_label_isolation;
    ];
    "assert mode", [
      test_case "default with cleared env is assert mode" `Quick
        test_default_is_assert_mode_when_env_cleared;
      test_case "buggy thunk re-raises after bumping" `Quick
        test_buggy_thunk_reraises;
    ];
  ]
