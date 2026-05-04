(** Regression tests for Cascade_trust — kill switch + trust computation.

    Tests the trust score formula with controlled provider_info records,
    verifying that:
    - High success + no failures → trust ~1.0
    - Consecutive failures reduce trust proportionally
    - Cooldown further reduces trust multiplicatively
    - Trust never falls below minimum_trust
    - Kill switch (disabled=true) returns 1.0 unconditionally
    - modulated_weight clamps to at least 1 *)

open Alcotest

module CT = Masc_mcp.Cascade_trust
module HT = Masc_mcp.Cascade_health_tracker

let info ?(success_rate = 1.0) ?(consecutive_failures = 0)
    ?(in_cooldown = false) ?(provider_key = "test-provider") () :
  HT.provider_info =
  {
    HT.provider_key = provider_key;
    success_rate;
    consecutive_failures;
    in_cooldown;
    cooldown_expires_at = None;
    events_in_window = 10;
    rejected_in_window = 0;
    top_fingerprints = [];
    last_failure_at = None;
    p50_latency_ms = None;
    p95_latency_ms = None;
    latency_samples = 0;
    avg_confidence = None;
    confidence_samples = 0;
  }

(* --- Trust score computation --- *)

let test_perfect_health () =
  let trust = CT.For_testing.trust_score (info ()) in
  check (float 0.001) "perfect health -> trust ~1.0" 1.0 trust

let test_degraded_success_rate () =
  let trust =
    CT.For_testing.trust_score (info ~success_rate:0.5 ())
  in
  check (float 0.001) "50% success -> trust ~0.5" 0.5 trust

let test_consecutive_failures_reduce_trust () =
  let trust_0 = CT.For_testing.trust_score (info ~consecutive_failures:0 ()) in
  let trust_3 = CT.For_testing.trust_score (info ~consecutive_failures:3 ()) in
  check bool "3 failures < 0 failures" true (trust_3 < trust_0);
  let expected_penalty =
    Float.min CT.For_testing.max_consecutive_penalty
      (3.0 *. CT.For_testing.consecutive_failure_penalty)
  in
  let expected = 1.0 *. (1.0 -. expected_penalty) in
  check (float 0.001) "3 failures trust matches formula"
    expected trust_3

let test_consecutive_penalty_capped () =
  let trust_10 = CT.For_testing.trust_score (info ~consecutive_failures:10 ()) in
  let trust_20 = CT.For_testing.trust_score (info ~consecutive_failures:20 ()) in
  check bool "penalty saturates (10 ≈ 20)" true
    (Float.abs (trust_10 -. trust_20) < 0.001)

let test_cooldown_reduces_trust () =
  let trust_no_cd =
    CT.For_testing.trust_score (info ~in_cooldown:false ())
  in
  let trust_cd =
    CT.For_testing.trust_score (info ~in_cooldown:true ())
  in
  check bool "cooldown reduces trust" true (trust_cd < trust_no_cd)

let test_minimum_trust_floor () =
  let trust =
    CT.For_testing.trust_score
      (info ~success_rate:0.0 ~consecutive_failures:100 ~in_cooldown:true ())
  in
  check bool "trust >= minimum_trust" true
    (trust >= CT.For_testing.minimum_trust)

(* --- modulated_weight --- *)

let test_modulated_weight_clamps_to_1 () =
  let weight =
    CT.For_testing.modulated_weight ~config_weight:10 ~trust:0.01
  in
  check int "weight clamped to 1" 1 weight

let test_modulated_weight_scales () =
  let weight =
    CT.For_testing.modulated_weight ~config_weight:100 ~trust:0.5
  in
  check int "50% trust of 100 -> 50" 50 weight

let test_modulated_weight_uses_config_when_disabled () =
  (* When disabled=true, modulated_weight returns config_weight directly *)
  let weight =
    CT.For_testing.modulated_weight ~config_weight:42 ~trust:0.01
  in
  (* If disabled is true, weight = 42. If false, weight = max(1, int(42*.0.01)) = 1 *)
  if CT.For_testing.disabled then
    check int "disabled -> returns config_weight" 42 weight
  else
    check int "not disabled -> uses trust" 1 weight

(* --- Calibration constants are reasonable --- *)

let test_calibration_constants_in_range () =
  check bool "base_trust = 1.0" true
    (Float.equal CT.For_testing.base_trust 1.0);
  check bool "consecutive_failure_penalty > 0" true
    (CT.For_testing.consecutive_failure_penalty > 0.0);
  check bool "max_consecutive_penalty < 1.0" true
    (CT.For_testing.max_consecutive_penalty < 1.0);
  check bool "cooldown_penalty > 0" true
    (CT.For_testing.cooldown_penalty > 0.0);
  check bool "minimum_trust > 0" true
    (CT.For_testing.minimum_trust > 0.0);
  check bool "minimum_trust < 0.1" true
    (CT.For_testing.minimum_trust < 0.1)

let () =
  run "cascade_trust"
    [
      ( "trust_score",
        [
          test_case "perfect health" `Quick test_perfect_health;
          test_case "degraded success rate" `Quick test_degraded_success_rate;
          test_case "consecutive failures reduce trust" `Quick
            test_consecutive_failures_reduce_trust;
          test_case "consecutive penalty capped" `Quick
            test_consecutive_penalty_capped;
          test_case "cooldown reduces trust" `Quick
            test_cooldown_reduces_trust;
          test_case "minimum trust floor" `Quick test_minimum_trust_floor;
        ] );
      ( "modulated_weight",
        [
          test_case "clamps to 1" `Quick test_modulated_weight_clamps_to_1;
          test_case "scales with trust" `Quick test_modulated_weight_scales;
          test_case "disabled uses config_weight" `Quick
            test_modulated_weight_uses_config_when_disabled;
        ] );
      ( "calibration",
        [
          test_case "constants in range" `Quick test_calibration_constants_in_range;
        ] );
    ]
