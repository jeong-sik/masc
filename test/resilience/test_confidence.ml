(* Cycle 23 / Tier B7 tests — Resilience.Confidence composite scoring. *)

module C = Shared_types.Confidence
module Conf = Resilience.Confidence

let approx_eq ?(eps = 1e-6) a b = Float.abs (a -. b) < eps

(* ─── Convenience constructors ────────────────────────────────── *)

let test_constructors_match_variants () =
  let a = Conf.artifact ~producer:"executor" ~score:0.8 in
  let v = Conf.verification ~verifier:"verifier" ~score:0.9 ~evidence:"ok" in
  let d = Conf.degradation ~level:2 ~penalty:0.7 in
  let cs = Conf.consensus ~agree_count:5 ~total_count:6 ~method_:"vote" in
  (match a with
   | Conf.Artifact { producer; raw_score } ->
       assert (producer = "executor");
       assert (raw_score = 0.8)
   | _ -> assert false);
  (match v with
   | Conf.Verification { verifier; score; evidence } ->
       assert (verifier = "verifier");
       assert (score = 0.9);
       assert (evidence = "ok")
   | _ -> assert false);
  (match d with
   | Conf.Degradation { level; penalty } ->
       assert (level = 2);
       assert (penalty = 0.7)
   | _ -> assert false);
  match cs with
  | Conf.Consensus { agree_count; total_count; method_ } ->
      assert (agree_count = 5);
      assert (total_count = 6);
      assert (method_ = "vote")
  | _ -> assert false

(* ─── evaluate composition ────────────────────────────────────── *)

let test_evaluate_geometric_mean () =
  let report =
    Conf.evaluate
      ~factors:
        [ Conf.artifact ~producer:"p1" ~score:0.6;
          Conf.artifact ~producer:"p2" ~score:0.8;
        ]
      ~threshold:0.5
  in
  let final = C.to_float report.final in
  assert (approx_eq final (Float.sqrt 0.48));
  assert (not report.below_threshold);
  assert (report.recommendation = None)

let test_evaluate_with_degradation_penalty () =
  let report =
    Conf.evaluate
      ~factors:
        [ Conf.artifact ~producer:"p" ~score:0.9;
          Conf.degradation ~level:3 ~penalty:0.5;
        ]
      ~threshold:0.5
  in
  let final = C.to_float report.final in
  assert (approx_eq final 0.45);
  assert report.below_threshold;
  match report.recommendation with
  | Some (Conf.Degrade { target_level; _ }) -> assert (target_level = 4)
  | _ -> assert false

let test_evaluate_empty_factors () =
  let report = Conf.evaluate ~factors:[] ~threshold:0.5 in
  let final = C.to_float report.final in
  assert (approx_eq final 0.0);
  assert report.below_threshold

let test_evaluate_only_degradation_zeroes () =
  let report =
    Conf.evaluate
      ~factors:[ Conf.degradation ~level:2 ~penalty:0.7 ]
      ~threshold:0.5
  in
  let final = C.to_float report.final in
  assert (approx_eq final 0.0)

let test_evaluate_consensus_factor () =
  let report =
    Conf.evaluate
      ~factors:[ Conf.consensus ~agree_count:4 ~total_count:5 ~method_:"vote" ]
      ~threshold:0.5
  in
  let final = C.to_float report.final in
  assert (approx_eq final 0.8);
  assert (not report.below_threshold)

(* ─── is_acceptable predicate ─────────────────────────────────── *)

let test_is_acceptable_above_threshold () =
  let report =
    Conf.evaluate
      ~factors:[ Conf.artifact ~producer:"p" ~score:0.9 ]
      ~threshold:0.5
  in
  assert (Conf.is_acceptable report)

let test_is_acceptable_below_threshold () =
  let report =
    Conf.evaluate
      ~factors:[ Conf.artifact ~producer:"p" ~score:0.3 ]
      ~threshold:0.5
  in
  assert (not (Conf.is_acceptable report))

(* ─── Recommendation ladder ──────────────────────────────────── *)

let test_recommendation_handoff_when_far_below () =
  let report =
    Conf.evaluate
      ~factors:[ Conf.artifact ~producer:"p" ~score:0.2 ]
      ~threshold:0.5
  in
  match report.recommendation with
  | Some (Conf.Handoff _) -> ()
  | _ -> assert false

let test_recommendation_request_verification_default () =
  let report =
    Conf.evaluate
      ~factors:[ Conf.artifact ~producer:"p" ~score:0.4 ]
      ~threshold:0.5
  in
  match report.recommendation with
  | Some (Conf.RequestVerification _) -> ()
  | _ -> assert false

(* ─── worst_factor ────────────────────────────────────────────── *)

let test_worst_factor_picks_lowest_score () =
  let report =
    Conf.evaluate
      ~factors:
        [ Conf.artifact ~producer:"p1" ~score:0.9;
          Conf.artifact ~producer:"p2" ~score:0.3;
          Conf.verification ~verifier:"v" ~score:0.7 ~evidence:"e";
        ]
      ~threshold:0.1
  in
  match Conf.worst_factor report with
  | Some (Conf.Artifact { producer; raw_score }) ->
      assert (producer = "p2");
      assert (approx_eq raw_score 0.3)
  | _ -> assert false

let test_worst_factor_empty_returns_none () =
  let report = Conf.evaluate ~factors:[] ~threshold:0.5 in
  assert (Conf.worst_factor report = None)

(* ─── Clamping ───────────────────────────────────────────────── *)

let test_evaluate_clamps_out_of_range_inputs () =
  let report =
    Conf.evaluate
      ~factors:
        [ Conf.artifact ~producer:"high" ~score:1.5;
          Conf.artifact ~producer:"neg" ~score:(-0.3);
        ]
      ~threshold:0.5
  in
  let final = C.to_float report.final in
  assert (approx_eq final 0.0)

let () =
  test_constructors_match_variants ();
  test_evaluate_geometric_mean ();
  test_evaluate_with_degradation_penalty ();
  test_evaluate_empty_factors ();
  test_evaluate_only_degradation_zeroes ();
  test_evaluate_consensus_factor ();
  test_is_acceptable_above_threshold ();
  test_is_acceptable_below_threshold ();
  test_recommendation_handoff_when_far_below ();
  test_recommendation_request_verification_default ();
  test_worst_factor_picks_lowest_score ();
  test_worst_factor_empty_returns_none ();
  test_evaluate_clamps_out_of_range_inputs ();
  print_endline "test_confidence: all assertions passed"
