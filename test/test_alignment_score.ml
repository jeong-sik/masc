(** Unit tests for Alignment_score (RFC-0035 PR-6,
    Master Report Dim03 P2 section 3.3). *)

open Masc_mcp.Alignment_score

let approx_eq a b = Float.abs (a -. b) <= 0.01

let ideal_metrics : metrics =
  {
    trc = 1.0;
    cov = 1.0;
    cmp = 1.0;
    crn = 1.0;
    dbt = 0.0;
    tmp = 1.0;
    dir = 1.0;
    coh = 1.0;
    bnd = 0.0;
    cnf = 1.0;
  }

let worst_metrics : metrics =
  {
    trc = 0.0;
    cov = 0.0;
    cmp = 5.0;     (* far from 1.0 *)
    crn = 5.0;
    dbt = 1.0;
    tmp = 5.0;
    dir = -1.0;
    coh = 0.0;
    bnd = 1.0;
    cnf = 0.0;
  }

let test_default_weights_sum_to_one () =
  let total = sum_weights default_weights in
  Alcotest.(check bool)
    (Printf.sprintf "default weights sum to 1.0 (got %.4f)" total)
    true (approx_eq total 1.0)

let test_overweight_custom_weights_clamp_final_score () =
  let overweight =
    { default_weights with trc = default_weights.trc +. 0.10 }
  in
  Alcotest.(check bool) "custom weights intentionally exceed 1.0" true
    (sum_weights overweight > 1.0);
  let r = calculate ~weights:overweight ideal_metrics in
  Alcotest.(check int) "overweight score clamps to 100" 100 r.score;
  Alcotest.(check string) "overweight score remains A" "A"
    (grade_to_string r.grade)

let test_ideal_metrics_score_100_grade_A () =
  let r = calculate ideal_metrics in
  Alcotest.(check int) "ideal metrics score 100" 100 r.score;
  Alcotest.(check string) "ideal metrics grade A" "A"
    (grade_to_string r.grade);
  Alcotest.(check int) "ideal metrics no warnings" 0
    (List.length r.warnings)

let test_worst_metrics_score_low_grade_F () =
  let r = calculate worst_metrics in
  Alcotest.(check bool)
    (Printf.sprintf "worst metrics score < 50 (got %d)" r.score)
    true (r.score < 50);
  Alcotest.(check string) "worst metrics grade F" "F"
    (grade_to_string r.grade)

let test_rounded_score_drives_grade () =
  let trc_only : weights =
    {
      trc = 1.0;
      cov = 0.0;
      cmp = 0.0;
      crn = 0.0;
      dbt = 0.0;
      tmp = 0.0;
      dir = 0.0;
      coh = 0.0;
      bnd = 0.0;
      cnf = 0.0;
    }
  in
  let r = calculate ~weights:trc_only { ideal_metrics with trc = 0.896 } in
  Alcotest.(check int) "89.6 rounds to displayed score 90" 90 r.score;
  Alcotest.(check string) "displayed score 90 grades A" "A"
    (grade_to_string r.grade)

let test_normalize_each_axis () =
  let n = normalize ideal_metrics in
  Alcotest.(check bool) "trc 1.0 -> 100" true (approx_eq n.trc 100.0);
  Alcotest.(check bool) "cmp 1.0 -> 100" true (approx_eq n.cmp 100.0);
  Alcotest.(check bool) "dbt 0.0 -> 100" true (approx_eq n.dbt 100.0);
  Alcotest.(check bool) "dir 1.0 -> 100" true (approx_eq n.dir 100.0);
  Alcotest.(check bool) "bnd 0.0 -> 100" true (approx_eq n.bnd 100.0);
  let mid_dir = { ideal_metrics with dir = 0.0 } in
  let n_mid = normalize mid_dir in
  Alcotest.(check bool) "dir 0.0 -> 50" true (approx_eq n_mid.dir 50.0);
  let neg_dir = { ideal_metrics with dir = -1.0 } in
  let n_neg = normalize neg_dir in
  Alcotest.(check bool) "dir -1.0 -> 0" true (approx_eq n_neg.dir 0.0);
  let off_cmp = { ideal_metrics with cmp = 1.5 } in
  let n_off = normalize off_cmp in
  Alcotest.(check bool) "cmp 1.5 -> 50 (|1.5-1| = 0.5)" true
    (approx_eq n_off.cmp 50.0)

let test_normalize_clamps_out_of_range () =
  let m = { ideal_metrics with trc = 2.0 } in
  let n = normalize m in
  Alcotest.(check bool) "trc 2.0 clamps to 100" true (approx_eq n.trc 100.0);
  let m2 = { ideal_metrics with trc = -0.5 } in
  let n2 = normalize m2 in
  Alcotest.(check bool) "trc -0.5 clamps to 0" true (approx_eq n2.trc 0.0);
  let m3 = { ideal_metrics with dbt = 5.0 } in
  let n3 = normalize m3 in
  Alcotest.(check bool) "dbt 5.0 (1-5 = -4) clamps to 0" true
    (approx_eq n3.dbt 0.0)

let test_grade_boundaries () =
  Alcotest.(check string) "score 90 -> A" "A" (grade_to_string (grade_of_score 90.0));
  Alcotest.(check string) "score 89.99 -> B" "B"
    (grade_to_string (grade_of_score 89.99));
  Alcotest.(check string) "score 75 -> B" "B" (grade_to_string (grade_of_score 75.0));
  Alcotest.(check string) "score 74.99 -> C" "C"
    (grade_to_string (grade_of_score 74.99));
  Alcotest.(check string) "score 60 -> C" "C" (grade_to_string (grade_of_score 60.0));
  Alcotest.(check string) "score 59.99 -> D" "D"
    (grade_to_string (grade_of_score 59.99));
  Alcotest.(check string) "score 40 -> D" "D" (grade_to_string (grade_of_score 40.0));
  Alcotest.(check string) "score 39.99 -> F" "F"
    (grade_to_string (grade_of_score 39.99));
  Alcotest.(check string) "score 0 -> F" "F" (grade_to_string (grade_of_score 0.0))

let test_grade_boundary_float_precision () =
  Alcotest.(check string) "90.000000001 -> A" "A"
    (grade_to_string (grade_of_score 90.000000001));
  Alcotest.(check string) "89.999999999 -> B" "B"
    (grade_to_string (grade_of_score 89.999999999));
  Alcotest.(check string) "75.000000001 -> B" "B"
    (grade_to_string (grade_of_score 75.000000001));
  Alcotest.(check string) "74.999999999 -> C" "C"
    (grade_to_string (grade_of_score 74.999999999))

let test_warning_low_traceability () =
  let m = { ideal_metrics with trc = 0.4 } in
  let r = calculate m in
  Alcotest.(check bool)
    "trc < 0.5 raises Low_traceability" true
    (List.mem Low_traceability r.warnings)

let test_warning_low_coverage () =
  let m = { ideal_metrics with cov = 0.3 } in
  let r = calculate m in
  Alcotest.(check bool)
    "cov < 0.5 raises Low_coverage" true (List.mem Low_coverage r.warnings)

let test_warning_high_debt () =
  let m = { ideal_metrics with dbt = 0.6 } in
  let r = calculate m in
  Alcotest.(check bool)
    "dbt > 0.5 raises High_debt" true (List.mem High_debt r.warnings)

let test_warning_behind_schedule () =
  let m = { ideal_metrics with tmp = 1.6 } in
  let r = calculate m in
  Alcotest.(check bool)
    "tmp > 1.5 raises Behind_schedule" true
    (List.mem Behind_schedule r.warnings)

let test_warning_wrong_direction () =
  let m = { ideal_metrics with dir = -0.1 } in
  let r = calculate m in
  Alcotest.(check bool)
    "dir < 0 raises Wrong_direction" true
    (List.mem Wrong_direction r.warnings)

let test_no_false_warnings_for_ideal () =
  let r = calculate ideal_metrics in
  Alcotest.(check int) "ideal metrics raise zero warnings" 0
    (List.length r.warnings)

let test_json_codec_shape () =
  let r = calculate ideal_metrics in
  let json = result_to_yojson r in
  let s = Yojson.Safe.to_string json in
  let must_contain needle =
    let len_n = String.length needle in
    let len_s = String.length s in
    let rec scan i =
      if i + len_n > len_s then false
      else if String.sub s i len_n = needle then true
      else scan (i + 1)
    in
    Alcotest.(check bool)
      (Printf.sprintf "json must contain %s" needle) true (scan 0)
  in
  must_contain "\"score\"";
  must_contain "\"grade\"";
  must_contain "\"warnings\"";
  must_contain "\"normalized\"";
  must_contain "\"trc\"";
  must_contain "\"A\""

let () =
  Alcotest.run "alignment_score"
    [
      ( "weights",
        [
          Alcotest.test_case "default sums to 1.0" `Quick
            test_default_weights_sum_to_one;
          Alcotest.test_case "overweight custom weights clamp final score" `Quick
            test_overweight_custom_weights_clamp_final_score;
        ] );
      ( "scoring",
        [
          Alcotest.test_case "ideal -> 100/A/no warnings" `Quick
            test_ideal_metrics_score_100_grade_A;
          Alcotest.test_case "worst -> low/F" `Quick
            test_worst_metrics_score_low_grade_F;
          Alcotest.test_case "rounded score drives grade" `Quick
            test_rounded_score_drives_grade;
        ] );
      ( "normalization",
        [
          Alcotest.test_case "each axis" `Quick test_normalize_each_axis;
          Alcotest.test_case "clamps out of range" `Quick
            test_normalize_clamps_out_of_range;
        ] );
      ( "grade",
        [
          Alcotest.test_case "boundaries 90/75/60/40" `Quick
            test_grade_boundaries;
          Alcotest.test_case "floating precision at boundaries" `Quick
            test_grade_boundary_float_precision;
        ] );
      ( "warnings",
        [
          Alcotest.test_case "low_traceability" `Quick
            test_warning_low_traceability;
          Alcotest.test_case "low_coverage" `Quick test_warning_low_coverage;
          Alcotest.test_case "high_debt (raw threshold)" `Quick
            test_warning_high_debt;
          Alcotest.test_case "behind_schedule (raw threshold)" `Quick
            test_warning_behind_schedule;
          Alcotest.test_case "wrong_direction" `Quick
            test_warning_wrong_direction;
          Alcotest.test_case "no false warnings on ideal" `Quick
            test_no_false_warnings_for_ideal;
        ] );
      ( "json",
        [ Alcotest.test_case "shape contract" `Quick test_json_codec_shape ] );
    ]
