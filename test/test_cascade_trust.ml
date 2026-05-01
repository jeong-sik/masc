(** Unit tests for [Cascade_trust].

    Exercises kill-switch reading, calibration constant invariants,
    [apply_success], and [apply_failure]. *)

open Alcotest
module T = Masc_mcp.Cascade_trust

(* ── Kill-switch tests ────────────────────────────── *)

let test_default_rotation_off () =
  (* Without MASC_CASCADE_TRUST_ROTATION=on the kill switch defaults to off.
     The env is read at module load time, so we just verify the value in
     the current process (which CI sets to the default / unset state). *)
  (* NOTE: if MASC_CASCADE_TRUST_ROTATION=on is set in the test environment
     this test would fail.  CI must not set that variable. *)
  match Sys.getenv_opt "MASC_CASCADE_TRUST_ROTATION" with
  | Some "on" ->
    (* environment override — skip rather than fail *)
    ()
  | _ ->
    check bool "rotation disabled by default" false T.trust_rotation_enabled

(* ── Calibration constant invariants ─────────────── *)

let test_initial_trust_is_ceiling () =
  check (float 1e-10) "initial_trust equals ceiling"
    T.ceiling T.initial_trust

let test_ceiling_is_one () =
  check (float 1e-10) "ceiling = 1.0" 1.0 T.ceiling

let test_reward_in_range () =
  check bool "reward_on_success > 0" true (T.reward_on_success > 0.0);
  check bool "reward_on_success < 1" true (T.reward_on_success < 1.0)

let test_decay_transient_in_range () =
  check bool "decay_transient > 0" true (T.decay_transient > 0.0);
  check bool "decay_transient < 1" true (T.decay_transient < 1.0)

let test_decay_persistent_in_range () =
  check bool "decay_persistent > 0" true (T.decay_persistent > 0.0);
  check bool "decay_persistent < decay_transient" true
    (T.decay_persistent < T.decay_transient)

let test_persistent_threshold_positive () =
  check bool "persistent_threshold >= 2" true (T.persistent_threshold >= 2)

let test_persistent_window_positive () =
  check bool "persistent_window_sec > 0" true (T.persistent_window_sec > 0.0)

(* ── apply_success ────────────────────────────────── *)

let test_apply_success_increases_trust () =
  let start = 0.5 in
  let after = T.apply_success start in
  check bool "trust increased" true (after > start)

let test_apply_success_capped_at_ceiling () =
  let after = T.apply_success T.ceiling in
  check (float 1e-10) "trust capped at ceiling" T.ceiling after

let test_apply_success_from_zero () =
  let after = T.apply_success 0.0 in
  check (float 1e-10) "trust = reward_on_success from zero"
    T.reward_on_success after

let test_apply_success_near_ceiling () =
  (* A value just below ceiling + reward should not exceed ceiling *)
  let start = T.ceiling -. (T.reward_on_success /. 2.0) in
  let after = T.apply_success start in
  check bool "trust capped, not above ceiling" true (after <= T.ceiling)

(* ── apply_failure ────────────────────────────────── *)

let test_apply_failure_transient_decreases_trust () =
  let start = 1.0 in
  let after = T.apply_failure ~persistent:false start in
  check bool "trust decreased on transient failure" true (after < start)

let test_apply_failure_persistent_more_aggressive () =
  let start = 1.0 in
  let transient = T.apply_failure ~persistent:false start in
  let persistent = T.apply_failure ~persistent:true start in
  check bool "persistent decay < transient decay" true (persistent < transient)

let test_apply_failure_transient_uses_decay_transient () =
  let start = 1.0 in
  let after = T.apply_failure ~persistent:false start in
  check (float 1e-10) "transient uses decay_transient"
    (start *. T.decay_transient) after

let test_apply_failure_persistent_uses_decay_persistent () =
  let start = 1.0 in
  let after = T.apply_failure ~persistent:true start in
  check (float 1e-10) "persistent uses decay_persistent"
    (start *. T.decay_persistent) after

let test_apply_failure_stays_non_negative () =
  let start = 0.001 in
  let after = T.apply_failure ~persistent:true start in
  check bool "trust stays non-negative after persistent decay"
    true (after >= 0.0)

(* ── Round-trip: decay then recover ──────────────── *)

let test_recovery_after_transient_failure () =
  (* After one transient failure, apply reward_on_success until trust reaches
     initial_trust (ceiling).  Trust should recover within a bounded number
     of successes. *)
  let decayed = T.apply_failure ~persistent:false T.initial_trust in
  let rec recover t steps =
    if steps > 100 then failwith "trust did not recover in 100 steps"
    else if t >= T.ceiling then steps
    else recover (T.apply_success t) (steps + 1)
  in
  let steps = recover decayed 0 in
  check bool "recovers in at most 20 successes" true (steps <= 20)

(* ── Suite ─────────────────────────────────────────── *)

let () =
  run "cascade_trust" [
    "kill_switch", [
      test_case "rotation disabled by default" `Quick
        test_default_rotation_off;
    ];
    "constants", [
      test_case "initial_trust equals ceiling" `Quick
        test_initial_trust_is_ceiling;
      test_case "ceiling = 1.0" `Quick
        test_ceiling_is_one;
      test_case "reward_on_success in (0, 1)" `Quick
        test_reward_in_range;
      test_case "decay_transient in (0, 1)" `Quick
        test_decay_transient_in_range;
      test_case "decay_persistent < decay_transient" `Quick
        test_decay_persistent_in_range;
      test_case "persistent_threshold >= 2" `Quick
        test_persistent_threshold_positive;
      test_case "persistent_window_sec > 0" `Quick
        test_persistent_window_positive;
    ];
    "apply_success", [
      test_case "increases trust" `Quick
        test_apply_success_increases_trust;
      test_case "capped at ceiling" `Quick
        test_apply_success_capped_at_ceiling;
      test_case "from zero = reward_on_success" `Quick
        test_apply_success_from_zero;
      test_case "near ceiling stays at ceiling" `Quick
        test_apply_success_near_ceiling;
    ];
    "apply_failure", [
      test_case "transient decreases trust" `Quick
        test_apply_failure_transient_decreases_trust;
      test_case "persistent more aggressive than transient" `Quick
        test_apply_failure_persistent_more_aggressive;
      test_case "transient uses decay_transient constant" `Quick
        test_apply_failure_transient_uses_decay_transient;
      test_case "persistent uses decay_persistent constant" `Quick
        test_apply_failure_persistent_uses_decay_persistent;
      test_case "trust stays non-negative" `Quick
        test_apply_failure_stays_non_negative;
    ];
    "round_trip", [
      test_case "recovers from transient failure within 20 successes" `Quick
        test_recovery_after_transient_failure;
    ];
  ]
