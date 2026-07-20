(** Unit tests for Runtime_lane_preference — sticky lane candidate ordering.

    Each case resets the process-local table first; the TTL case shrinks
    [MASC_LANE_PREFERENCE_TTL_S] via env (re-read per call) instead of
    injecting a clock. *)

let candidates = [ "alpha"; "beta"; "gamma" ]

let test_identity_without_state () =
  Runtime_lane_preference.reset_for_testing ();
  Alcotest.(check (list string)) "no state keeps declared order" candidates
    (Runtime_lane_preference.prefer_order ~lane_id:"lane-1" candidates)

let test_preferred_first_after_success () =
  Runtime_lane_preference.reset_for_testing ();
  Runtime_lane_preference.note_success ~lane_id:"lane-1" ~candidate:"beta";
  Alcotest.(check (list string)) "remembered candidate leads"
    [ "beta"; "alpha"; "gamma" ]
    (Runtime_lane_preference.prefer_order ~lane_id:"lane-1" candidates)

let test_success_on_head_is_harmless () =
  Runtime_lane_preference.reset_for_testing ();
  Runtime_lane_preference.note_success ~lane_id:"lane-1" ~candidate:"alpha";
  Alcotest.(check (list string)) "head success keeps declared order"
    candidates
    (Runtime_lane_preference.prefer_order ~lane_id:"lane-1" candidates)

let test_lane_isolation () =
  Runtime_lane_preference.reset_for_testing ();
  Runtime_lane_preference.note_success ~lane_id:"lane-1" ~candidate:"beta";
  Alcotest.(check (list string)) "other lane unaffected" candidates
    (Runtime_lane_preference.prefer_order ~lane_id:"lane-2" candidates)

let test_non_member_ignored () =
  Runtime_lane_preference.reset_for_testing ();
  Runtime_lane_preference.note_success ~lane_id:"lane-1" ~candidate:"gone";
  Alcotest.(check (list string)) "non-member remembered id keeps order"
    candidates
    (Runtime_lane_preference.prefer_order ~lane_id:"lane-1" candidates)

let test_ttl_expiry_restores_order () =
  Runtime_lane_preference.reset_for_testing ();
  Unix.putenv "MASC_LANE_PREFERENCE_TTL_S" "0.05";
  Fun.protect
    ~finally:(fun () -> Unix.putenv "MASC_LANE_PREFERENCE_TTL_S" "")
    (fun () ->
      Alcotest.(check (float 0.001)) "env ttl applies" 0.05
        (Runtime_lane_preference.ttl_s ());
      Runtime_lane_preference.note_success ~lane_id:"lane-1" ~candidate:"beta";
      Alcotest.(check (list string)) "fresh entry leads"
        [ "beta"; "alpha"; "gamma" ]
        (Runtime_lane_preference.prefer_order ~lane_id:"lane-1" candidates);
      Unix.sleepf 0.1;
      Alcotest.(check (list string)) "expired entry restores declared order"
        candidates
        (Runtime_lane_preference.prefer_order ~lane_id:"lane-1" candidates))

let () =
  Alcotest.run "runtime_lane_preference"
    [
      ( "prefer_order"
      , [ Alcotest.test_case "identity without state" `Quick
            test_identity_without_state
        ; Alcotest.test_case "remembered candidate first" `Quick
            test_preferred_first_after_success
        ; Alcotest.test_case "head success harmless" `Quick
            test_success_on_head_is_harmless
        ; Alcotest.test_case "lane isolation" `Quick test_lane_isolation
        ; Alcotest.test_case "non-member ignored" `Quick test_non_member_ignored
        ; Alcotest.test_case "ttl expiry restores order" `Quick
            test_ttl_expiry_restores_order
        ] )
    ]
