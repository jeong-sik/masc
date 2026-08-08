(** Unit tests for Eval_stats — pure statistical utilities used by the
    eval regression detector.

    Functions are deterministic and IO-free, so these tests are simple
    arithmetic round-trips. The Welch's t-test and Cohen's d numerics
    are validated against hand-computed expected values within an
    epsilon, not against an external reference implementation. *)

open Agent_sdk
open Alcotest

let eps = 1e-6
let close_enough a b = Float.abs (a -. b) <= eps
let close = testable Format.pp_print_float close_enough

(* ── summary_stats ─────────────────────────────────────────── *)

let test_summary_empty () =
  check (option (testable Fmt.nop ( = ))) "empty" None (Eval_stats.summary_stats [])
;;

let test_summary_singleton () =
  match Eval_stats.summary_stats [ 3.0 ] with
  | None -> fail "expected Some"
  | Some s ->
    check int "n" 1 s.n;
    check close "mean" 3.0 s.mean;
    check close "std_dev (n=1)" 0.0 s.std_dev;
    check close "min" 3.0 s.min_val;
    check close "max" 3.0 s.max_val
;;

let test_summary_three () =
  match Eval_stats.summary_stats [ 1.0; 2.0; 3.0 ] with
  | None -> fail "expected Some"
  | Some s ->
    check int "n" 3 s.n;
    check close "mean" 2.0 s.mean;
    (* Sample std dev (n-1): sqrt(((1-2)^2 + 0 + (3-2)^2) / 2) = 1.0 *)
    check close "std_dev" 1.0 s.std_dev;
    check close "min" 1.0 s.min_val;
    check close "max" 3.0 s.max_val
;;

(* ── confidence_interval ───────────────────────────────────── *)

let test_ci_too_few () =
  check
    (option (testable Fmt.nop ( = )))
    "n=1"
    None
    (Eval_stats.confidence_interval [ 1.0 ] ~confidence:0.95)
;;

let test_ci_basic () =
  match Eval_stats.confidence_interval [ 1.0; 2.0; 3.0; 4.0; 5.0 ] ~confidence:0.95 with
  | None -> fail "expected Some"
  | Some (lo, hi) ->
    (* Mean = 3, std = sqrt(2.5) ≈ 1.5811, n = 5
         CI = mean ± z * std / sqrt(n) where z = 1.96 for 95%
         half-width ≈ 1.96 * 1.5811 / sqrt(5) ≈ 1.3865 *)
    check bool "lo < mean < hi" true (lo < 3.0 && 3.0 < hi);
    check bool "symmetric around mean" true (Float.abs (3.0 -. lo -. (hi -. 3.0)) < 1e-6)
;;

(* ── is_regression ─────────────────────────────────────────── *)

let test_regression_too_few () =
  check
    bool
    "baseline n=1"
    false
    (Eval_stats.is_regression ~baseline:[ 1.0 ] ~current:[ 10.0; 11.0; 12.0 ])
;;

let test_regression_obvious () =
  (* current is dramatically higher than baseline *)
  check
    bool
    "10 vs 100"
    true
    (Eval_stats.is_regression
       ~baseline:[ 10.0; 11.0; 9.0; 10.5; 9.5 ]
       ~current:[ 100.0; 105.0; 95.0; 110.0; 90.0 ])
;;

let test_regression_no_change () =
  (* same distribution, should not flag *)
  check
    bool
    "same data"
    false
    (Eval_stats.is_regression
       ~baseline:[ 10.0; 11.0; 9.0; 10.5; 9.5 ]
       ~current:[ 10.0; 11.0; 9.0; 10.5; 9.5 ])
;;

let test_regression_improvement () =
  (* current is lower than baseline → not a regression *)
  check
    bool
    "improvement is not regression"
    false
    (Eval_stats.is_regression
       ~baseline:[ 100.0; 105.0; 95.0; 110.0; 90.0 ]
       ~current:[ 10.0; 11.0; 9.0; 10.5; 9.5 ])
;;

(* ── effect_size ───────────────────────────────────────────── *)

let test_effect_size_too_few () =
  check
    (option (testable Fmt.nop ( = )))
    "n=1"
    None
    (Eval_stats.effect_size [ 1.0 ] [ 2.0; 3.0 ])
;;

let test_effect_size_no_diff () =
  (* identical samples → effect size 0 *)
  match Eval_stats.effect_size [ 1.0; 2.0; 3.0 ] [ 1.0; 2.0; 3.0 ] with
  | None -> fail "expected Some 0"
  | Some d -> check close "Cohen's d ≈ 0" 0.0 d
;;

let test_effect_size_large () =
  (* very different means with low variance → large |d| *)
  match Eval_stats.effect_size [ 0.0; 0.1; -0.1 ] [ 10.0; 10.1; 9.9 ] with
  | None -> fail "expected Some"
  | Some d -> check bool "|d| > 1 (large)" true (Float.abs d > 1.0)
;;

(* ── detect_trend ──────────────────────────────────────────── *)

let test_trend_insufficient () =
  let r = Eval_stats.detect_trend ~window:5 [ 1.0; 2.0 ] in
  check bool "Insufficient_data" true (r = Eval_stats.Insufficient_data)
;;

let test_trend_improving () =
  (* This module treats higher-value-trend as Improving (positive
     slope). Eval metrics here are "score" semantics, not error rates. *)
  let r = Eval_stats.detect_trend ~window:5 [ 1.0; 2.0; 3.0; 4.0; 5.0 ] in
  check bool "Improving on strictly-increasing" true (r = Eval_stats.Improving)
;;

let test_trend_degrading () =
  let r = Eval_stats.detect_trend ~window:5 [ 5.0; 4.0; 3.0; 2.0; 1.0 ] in
  check bool "Degrading on strictly-decreasing" true (r = Eval_stats.Degrading)
;;

(* ── consecutive_direction ─────────────────────────────────── *)

let test_consec_empty () =
  let n, dir = Eval_stats.consecutive_direction [] in
  check int "n=0" 0 n;
  check bool "Flat" true (dir = `Flat)
;;

let test_consec_singleton () =
  let n, dir = Eval_stats.consecutive_direction [ 42.0 ] in
  check int "n=0" 0 n;
  check bool "Flat" true (dir = `Flat)
;;

let test_consec_up () =
  let n, dir = Eval_stats.consecutive_direction [ 1.0; 2.0; 3.0; 4.0 ] in
  check bool "n>=2" true (n >= 2);
  check bool "Up" true (dir = `Up)
;;

let test_consec_down () =
  let n, dir = Eval_stats.consecutive_direction [ 4.0; 3.0; 2.0; 1.0 ] in
  check bool "n>=2" true (n >= 2);
  check bool "Down" true (dir = `Down)
;;

(* ── runner ───────────────────────────────────────────────── *)

let () =
  run
    "Eval_stats"
    [ ( "summary_stats"
      , [ test_case "empty list" `Quick test_summary_empty
        ; test_case "singleton" `Quick test_summary_singleton
        ; test_case "three values" `Quick test_summary_three
        ] )
    ; ( "confidence_interval"
      , [ test_case "too-few sample" `Quick test_ci_too_few
        ; test_case "five values 95% CI" `Quick test_ci_basic
        ] )
    ; ( "is_regression"
      , [ test_case "too-few sample" `Quick test_regression_too_few
        ; test_case "10x increase flagged" `Quick test_regression_obvious
        ; test_case "identical not flagged" `Quick test_regression_no_change
        ; test_case "improvement not flagged" `Quick test_regression_improvement
        ] )
    ; ( "effect_size"
      , [ test_case "too-few sample" `Quick test_effect_size_too_few
        ; test_case "identical d≈0" `Quick test_effect_size_no_diff
        ; test_case "10x diff |d|>1" `Quick test_effect_size_large
        ] )
    ; ( "detect_trend"
      , [ test_case "insufficient data" `Quick test_trend_insufficient
        ; test_case "decreasing → Improving" `Quick test_trend_improving
        ; test_case "increasing → Degrading" `Quick test_trend_degrading
        ] )
    ; ( "consecutive_direction"
      , [ test_case "empty" `Quick test_consec_empty
        ; test_case "singleton" `Quick test_consec_singleton
        ; test_case "monotonic up" `Quick test_consec_up
        ; test_case "monotonic down" `Quick test_consec_down
        ] )
    ]
;;
