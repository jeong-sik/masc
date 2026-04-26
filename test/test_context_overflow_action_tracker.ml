(* test/test_context_overflow_action_tracker.ml

   #9935: detector for imminent→action pairing on context
   overflow events. Mirrors the #9931 stay_silent detector
   pattern (latched per-episode counter + per-keeper state).

   Invariants:
   1. record_imminent increments imminent counter
   2. record_action within grace → action_taken counter,
      pending cleared
   3. New imminent past grace window with prior unanswered →
      no_action counter (latched once per episode)
   4. Latch releases when record_action is called → next
      no-action episode can fire again
   5. Per-keeper isolation
   6. Grace window env var honored *)

module T = Masc_mcp.Context_overflow_action_tracker
module Prom = Masc_mcp.Prometheus

let imminent_count k =
  Prom.metric_value_or_zero
    "masc_context_overflow_imminent_total"
    ~labels:[ "keeper", k ]
    ()
;;

let action_count k =
  Prom.metric_value_or_zero
    "masc_context_overflow_action_taken_total"
    ~labels:[ "keeper", k ]
    ()
;;

let no_action_count k =
  Prom.metric_value_or_zero
    "masc_context_overflow_no_action_total"
    ~labels:[ "keeper", k ]
    ()
;;

let set_grace sec =
  Unix.putenv "MASC_CONTEXT_OVERFLOW_GRACE_SEC" (Printf.sprintf "%.3f" sec)
;;

let clear_grace () = Unix.putenv "MASC_CONTEXT_OVERFLOW_GRACE_SEC" ""

let test_imminent_increments_counter () =
  T.reset_all_for_test ();
  let k = "test-keeper-increments" in
  let before = imminent_count k in
  T.record_imminent ~keeper_name:k ~ts:100.0;
  Alcotest.(check (float 0.0001)) "imminent counter +1" (before +. 1.0) (imminent_count k);
  Alcotest.(check (option (float 0.0001)))
    "pending_since set"
    (Some 100.0)
    (T.current_pending_since ~keeper_name:k)
;;

let test_action_within_grace_clears_pending () =
  T.reset_all_for_test ();
  let k = "test-keeper-action-within-grace" in
  let action_before = action_count k in
  T.record_imminent ~keeper_name:k ~ts:100.0;
  T.record_action ~keeper_name:k;
  Alcotest.(check (option (float 0.0001)))
    "pending cleared"
    None
    (T.current_pending_since ~keeper_name:k);
  Alcotest.(check (float 0.0001))
    "action counter +1"
    (action_before +. 1.0)
    (action_count k)
;;

let test_action_with_no_pending_is_silent () =
  T.reset_all_for_test ();
  let k = "test-keeper-action-no-pending" in
  let before = action_count k in
  T.record_action ~keeper_name:k;
  Alcotest.(check (float 0.0001))
    "action counter unchanged (no pending)"
    before
    (action_count k)
;;

let test_no_action_past_grace_fires_latched () =
  T.reset_all_for_test ();
  let k = "test-keeper-no-action-latch" in
  set_grace 10.0;
  let before = no_action_count k in
  (* First imminent at t=100 *)
  T.record_imminent ~keeper_name:k ~ts:100.0;
  Alcotest.(check (float 0.0001))
    "no no-action fire yet (no new imminent arrived)"
    before
    (no_action_count k);
  (* Second imminent at t=115, grace=10 → prior is 15s old *)
  T.record_imminent ~keeper_name:k ~ts:115.0;
  Alcotest.(check (float 0.0001))
    "no-action counter +1"
    (before +. 1.0)
    (no_action_count k);
  (* Third imminent at t=130, still same unanswered episode *)
  T.record_imminent ~keeper_name:k ~ts:130.0;
  Alcotest.(check (float 0.0001))
    "latched: no-action does NOT re-fire"
    (before +. 1.0)
    (no_action_count k);
  clear_grace ()
;;

let test_latch_releases_on_action () =
  T.reset_all_for_test ();
  let k = "test-keeper-latch-release" in
  set_grace 10.0;
  let before = no_action_count k in
  (* Episode 1: imminent -> no action -> late imminent fires counter *)
  T.record_imminent ~keeper_name:k ~ts:100.0;
  T.record_imminent ~keeper_name:k ~ts:115.0;
  Alcotest.(check (float 0.0001)) "episode 1 fired" (before +. 1.0) (no_action_count k);
  (* Action arrives — latch should release *)
  T.record_action ~keeper_name:k;
  (* Episode 2: imminent, then another past-grace imminent *)
  T.record_imminent ~keeper_name:k ~ts:200.0;
  T.record_imminent ~keeper_name:k ~ts:215.0;
  Alcotest.(check (float 0.0001))
    "episode 2 fires once more"
    (before +. 2.0)
    (no_action_count k);
  clear_grace ()
;;

let test_action_within_grace_does_not_fire_no_action () =
  T.reset_all_for_test ();
  let k = "test-keeper-within-grace-clean" in
  set_grace 30.0;
  let before = no_action_count k in
  T.record_imminent ~keeper_name:k ~ts:100.0;
  (* Action arrives within grace, then a fresh imminent much later *)
  T.record_action ~keeper_name:k;
  T.record_imminent ~keeper_name:k ~ts:300.0;
  Alcotest.(check (float 0.0001))
    "no_action NOT fired (prior was cleared)"
    before
    (no_action_count k);
  clear_grace ()
;;

let test_per_keeper_isolation () =
  T.reset_all_for_test ();
  let a = "test-keeper-A" in
  let b = "test-keeper-B" in
  set_grace 10.0;
  T.record_imminent ~keeper_name:a ~ts:100.0;
  T.record_imminent ~keeper_name:b ~ts:100.0;
  T.record_action ~keeper_name:a;
  Alcotest.(check (option (float 0.0001)))
    "A cleared"
    None
    (T.current_pending_since ~keeper_name:a);
  Alcotest.(check (option (float 0.0001)))
    "B still pending"
    (Some 100.0)
    (T.current_pending_since ~keeper_name:b);
  clear_grace ()
;;

let test_grace_default () =
  clear_grace ();
  Alcotest.(check (float 0.01)) "default 60s" 60.0 (T.grace_window_seconds ())
;;

let test_grace_custom () =
  set_grace 15.0;
  Alcotest.(check (float 0.01)) "custom 15s" 15.0 (T.grace_window_seconds ());
  Unix.putenv "MASC_CONTEXT_OVERFLOW_GRACE_SEC" "bogus";
  Alcotest.(check (float 0.01)) "invalid → default" 60.0 (T.grace_window_seconds ());
  Unix.putenv "MASC_CONTEXT_OVERFLOW_GRACE_SEC" "-5";
  Alcotest.(check (float 0.01)) "negative → default" 60.0 (T.grace_window_seconds ());
  clear_grace ()
;;

let () =
  Alcotest.run
    "context_overflow_action_tracker"
    [ ( "imminent"
      , [ Alcotest.test_case "increments counter" `Quick test_imminent_increments_counter
        ] )
    ; ( "action pairing"
      , [ Alcotest.test_case
            "within grace clears pending"
            `Quick
            test_action_within_grace_clears_pending
        ; Alcotest.test_case
            "no pending → silent"
            `Quick
            test_action_with_no_pending_is_silent
        ; Alcotest.test_case
            "action within grace does NOT fire no-action"
            `Quick
            test_action_within_grace_does_not_fire_no_action
        ] )
    ; ( "no-action latch"
      , [ Alcotest.test_case
            "past grace fires once"
            `Quick
            test_no_action_past_grace_fires_latched
        ; Alcotest.test_case
            "latch releases on action"
            `Quick
            test_latch_releases_on_action
        ] )
    ; ( "per-keeper isolation"
      , [ Alcotest.test_case "A and B independent" `Quick test_per_keeper_isolation ] )
    ; ( "grace env var"
      , [ Alcotest.test_case "default 60s" `Quick test_grace_default
        ; Alcotest.test_case "custom + invalid fallback" `Quick test_grace_custom
        ] )
    ]
;;
