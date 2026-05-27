(** Unit tests for [Cascade_deadline] (RFC-0192 PR-1).

    Pure math tests use the [_at] variants with explicit [now_s] so no
    Eio runtime is required. The clock-bearing wrappers are exercised by
    integration tests in PR-2 once the scheduler consumes them. *)

open Alcotest

module D = Masc_mcp.Cascade_deadline

let test_remaining_at_future () =
  let d = D.create ~expires_at_s:100.0 in
  check (float 1e-9) "10s remaining" 10.0 (D.remaining_at ~now_s:90.0 d)

let test_remaining_at_now () =
  let d = D.create ~expires_at_s:100.0 in
  check (float 1e-9) "0s remaining at expiry" 0.0 (D.remaining_at ~now_s:100.0 d)

let test_remaining_at_past_clamped_to_zero () =
  let d = D.create ~expires_at_s:100.0 in
  check (float 1e-9) "expired deadline clamps to 0"
    0.0 (D.remaining_at ~now_s:150.0 d)

let test_composed_picks_amplifier_when_deadline_far () =
  (* deadline gives 30s remaining, amplifier 10s → amplifier wins *)
  let d = D.create ~expires_at_s:130.0 in
  check (float 1e-9) "amplifier is lower bound"
    10.0 (D.composed_attempt_budget_at ~now_s:100.0 ~deadline:d ~amplifier:10.0)

let test_composed_picks_deadline_when_amplifier_large () =
  (* deadline gives 5s remaining, amplifier 30s → deadline wins *)
  let d = D.create ~expires_at_s:105.0 in
  check (float 1e-9) "deadline is lower bound"
    5.0 (D.composed_attempt_budget_at ~now_s:100.0 ~deadline:d ~amplifier:30.0)

let test_composed_zero_when_deadline_expired () =
  (* expired deadline → 0 regardless of amplifier *)
  let d = D.create ~expires_at_s:100.0 in
  check (float 1e-9) "expired deadline zeroes budget"
    0.0 (D.composed_attempt_budget_at ~now_s:150.0 ~deadline:d ~amplifier:30.0)

let test_composed_equal_when_both_at_boundary () =
  (* deadline = amplifier = 15 → both 15 *)
  let d = D.create ~expires_at_s:115.0 in
  check (float 1e-9) "equal at boundary"
    15.0 (D.composed_attempt_budget_at ~now_s:100.0 ~deadline:d ~amplifier:15.0)

let test_is_expired_at_matches_remaining_zero () =
  let d = D.create ~expires_at_s:100.0 in
  check bool "not expired before" false (D.is_expired_at ~now_s:50.0 d);
  check bool "expired at exact" true (D.is_expired_at ~now_s:100.0 d);
  check bool "expired after" true (D.is_expired_at ~now_s:150.0 d)

let test_expires_at_roundtrips () =
  let d = D.create ~expires_at_s:1779864000.5 in
  check (float 1e-9) "expires_at preserved" 1779864000.5 (D.expires_at d)

let () =
  run "cascade_deadline"
    [
      ( "pure math (RFC-0192 § 2 invariant)",
        [
          test_case "remaining_at: future" `Quick test_remaining_at_future;
          test_case "remaining_at: at expiry" `Quick test_remaining_at_now;
          test_case "remaining_at: past clamped to 0" `Quick
            test_remaining_at_past_clamped_to_zero;
          test_case "composed_attempt_budget: amplifier upper bound" `Quick
            test_composed_picks_amplifier_when_deadline_far;
          test_case "composed_attempt_budget: deadline lower bound" `Quick
            test_composed_picks_deadline_when_amplifier_large;
          test_case "composed_attempt_budget: expired deadline = 0" `Quick
            test_composed_zero_when_deadline_expired;
          test_case "composed_attempt_budget: equal at boundary" `Quick
            test_composed_equal_when_both_at_boundary;
          test_case "is_expired_at: matches remaining = 0" `Quick
            test_is_expired_at_matches_remaining_zero;
          test_case "expires_at: roundtrips construction" `Quick
            test_expires_at_roundtrips;
        ] );
    ]
