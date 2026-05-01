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
       and is swallowed by default (counter mode).
    4. With [MASC_FSM_GUARD_ASSERT=1], the same buggy thunk re-raises
       after bumping the counter (assert mode for tests / CI).
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
  Unix.putenv "MASC_FSM_GUARD_ASSERT" "0";
  G.refresh_policy_for_test ();
  let action = "TestAction" in
  let stage = "honest" in
  let before = read_count ~action ~stage in
  G.wrap_unit ~action ~stage (fun () -> ());
  let after = read_count ~action ~stage in
  Alcotest.(check (float 0.0001))
    "honest thunk does not bump the counter"
    before after

let test_buggy_thunk_in_counter_mode_swallows_and_bumps () =
  Unix.putenv "MASC_FSM_GUARD_ASSERT" "0";
  G.refresh_policy_for_test ();
  let action = "TestAction" in
  let stage = "buggy_counter" in
  let before = read_count ~action ~stage in
  (* Should not raise — the wrapper catches Assert_failure. *)
  G.wrap_unit ~action ~stage (fun () -> assert false);
  let after = read_count ~action ~stage in
  Alcotest.(check (float 0.0001))
    "Assert_failure is caught and counter bumped by one"
    (before +. 1.0) after

let test_buggy_thunk_in_assert_mode_reraises () =
  Unix.putenv "MASC_FSM_GUARD_ASSERT" "1";
  G.refresh_policy_for_test ();
  Alcotest.(check bool)
    "policy is now assert mode"
    true (G.assert_mode_for_test ());
  let action = "TestAction" in
  let stage = "buggy_assert" in
  let before = read_count ~action ~stage in
  (* Should raise — assert mode bumps then re-raises. *)
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
  Unix.putenv "MASC_FSM_GUARD_ASSERT" "";
  G.refresh_policy_for_test ()

let test_non_assert_exception_propagates_unchanged () =
  Unix.putenv "MASC_FSM_GUARD_ASSERT" "0";
  G.refresh_policy_for_test ();
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
  Unix.putenv "MASC_FSM_GUARD_ASSERT" "0";
  G.refresh_policy_for_test ();
  let stage = "iso" in
  let action_a = "ActionA" in
  let action_b = "ActionB" in
  let a_before = read_count ~action:action_a ~stage in
  let b_before = read_count ~action:action_b ~stage in
  G.wrap_unit ~action:action_a ~stage (fun () -> assert false);
  let a_after = read_count ~action:action_a ~stage in
  let b_after = read_count ~action:action_b ~stage in
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
    "counter mode (default)", [
      test_case "honest thunk does not bump" `Quick
        test_honest_thunk_leaves_counter_alone;
      test_case "buggy thunk swallows + bumps" `Quick
        test_buggy_thunk_in_counter_mode_swallows_and_bumps;
      test_case "non-assert exception propagates" `Quick
        test_non_assert_exception_propagates_unchanged;
      test_case "action label isolation" `Quick
        test_distinct_action_label_isolation;
    ];
    "assert mode (MASC_FSM_GUARD_ASSERT=1)", [
      test_case "buggy thunk re-raises after bumping" `Quick
        test_buggy_thunk_in_assert_mode_reraises;
    ];
  ]
