(** Extended coverage tests for the Eval module.

    Existing tests cover:
    - metric_value yojson roundtrip, to_float
    - metric yojson roundtrip
    - collector basic, verdict
    - comparison regression/improvement/unchanged
    - threshold pass/fail max/min
    - find_metric
    - run_metrics yojson

    This file targets uncovered paths in:
    - Eval.ml: metric_value_of_yojson error path, compute_delta edge cases
      (baseline zero, non-numeric, custom threshold), pp_* formatters,
      show_run_metrics, metric_of_yojson error path, run_metrics_of_yojson
      error path, find_metric_value *)

open Agent_sdk

(* ── Helpers ──────────────────────────────────────────── *)

let mk_metric ?(unit_ = None) ?(tags = []) name value : Eval.metric =
  { name; value; unit_; tags }
;;

let mk_run ?(run_id = "r1") ?(agent_name = "test") ?(verdicts = []) metrics
  : Eval.run_metrics
  =
  { run_id; agent_name; timestamp = 1000.0; metrics; harness_verdicts = verdicts }
;;

(* ── metric_value_of_yojson error ─────────────────────── *)

let test_metric_value_of_yojson_error () =
  match Eval.metric_value_of_yojson (`List []) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for list"
;;

let test_metric_value_of_yojson_null () =
  match Eval.metric_value_of_yojson `Null with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for null"
;;

(* ── show_metric_value all variants ───────────────────── *)

let test_show_metric_value_int () =
  Alcotest.(check string) "int" "42" (Eval.show_metric_value (Int_val 42))
;;

let test_show_metric_value_bool_false () =
  Alcotest.(check string) "false" "false" (Eval.show_metric_value (Bool_val false))
;;

let test_show_metric_value_string () =
  Alcotest.(check string) "str" "hello" (Eval.show_metric_value (String_val "hello"))
;;

(* ── pp_metric_value ──────────────────────────────────── *)

let test_pp_metric_value () =
  let buf = Buffer.create 16 in
  let fmt = Format.formatter_of_buffer buf in
  Eval.pp_metric_value fmt (Float_val 3.14);
  Format.pp_print_flush fmt ();
  let s = Buffer.contents buf in
  Alcotest.(check bool) "contains 3.14" true (Util.string_contains ~needle:"3.14" s)
;;

(* ── pp_metric ────────────────────────────────────────── *)

let test_pp_metric () =
  let buf = Buffer.create 32 in
  let fmt = Format.formatter_of_buffer buf in
  Eval.pp_metric fmt (mk_metric "latency" (Float_val 1.5));
  Format.pp_print_flush fmt ();
  let s = Buffer.contents buf in
  Alcotest.(check bool) "contains latency" true (Util.string_contains ~needle:"latency" s)
;;

(* ── show_metric ──────────────────────────────────────── *)

let test_show_metric () =
  let s = Eval.show_metric (mk_metric "x" (Int_val 1)) in
  Alcotest.(check string) "format" "x=1" s
;;

(* ── show_run_metrics ─────────────────────────────────── *)

let test_show_run_metrics () =
  let rm = mk_run [ mk_metric "a" (Int_val 1); mk_metric "b" (Float_val 2.5) ] in
  let s = Eval.show_run_metrics rm in
  Alcotest.(check bool) "contains run=" true (Util.string_contains ~needle:"run=" s);
  Alcotest.(check bool) "contains agent=" true (Util.string_contains ~needle:"agent=" s)
;;

(* ── pp_run_metrics ───────────────────────────────────── *)

let test_pp_run_metrics () =
  let buf = Buffer.create 64 in
  let fmt = Format.formatter_of_buffer buf in
  let rm = mk_run [ mk_metric "x" (Int_val 1) ] in
  Eval.pp_run_metrics fmt rm;
  Format.pp_print_flush fmt ();
  let s = Buffer.contents buf in
  Alcotest.(check bool) "non-empty" true (String.length s > 0)
;;

(* ── metric_of_yojson error path ──────────────────────── *)

let test_metric_of_yojson_type_error () =
  let json = `Assoc [ "name", `Int 42 ] in
  match Eval.metric_of_yojson json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for bad name type"
;;

let test_metric_of_yojson_bad_value () =
  let json = `Assoc [ "name", `String "x"; "value", `List [] ] in
  match Eval.metric_of_yojson json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for bad value"
;;

(* ── metric_of_yojson: no tags, no unit ───────────────── *)

let test_metric_of_yojson_minimal () =
  let json = `Assoc [ "name", `String "x"; "value", `Int 1 ] in
  match Eval.metric_of_yojson json with
  | Ok m ->
    Alcotest.(check string) "name" "x" m.name;
    Alcotest.(check (option string)) "no unit" None m.unit_;
    Alcotest.(check int) "no tags" 0 (List.length m.tags)
  | Error e -> Alcotest.fail e
;;

(* ── metric_to_yojson: with unit and tags ─────────────── *)

let test_metric_to_yojson_full () =
  let m = mk_metric ~unit_:(Some "ms") ~tags:[ "env", "prod" ] "lat" (Float_val 1.5) in
  let json = Eval.metric_to_yojson m in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "unit" "ms" (json |> member "unit" |> to_string);
  let tags = json |> member "tags" in
  Alcotest.(check string) "env tag" "prod" (tags |> member "env" |> to_string)
;;

(* ── metric_to_yojson: no unit no tags ────────────────── *)

let test_metric_to_yojson_minimal () =
  let m = mk_metric "x" (Int_val 1) in
  let json = Eval.metric_to_yojson m in
  let s = Yojson.Safe.to_string json in
  (* No "unit" or "tags" key *)
  Alcotest.(check bool) "no unit" false (Util.string_contains ~needle:"\"unit\"" s);
  Alcotest.(check bool) "no tags" false (Util.string_contains ~needle:"\"tags\"" s)
;;

(* ── run_metrics_of_yojson error path ─────────────────── *)

let test_run_metrics_of_yojson_type_error () =
  let json = `String "bad" in
  match Eval.run_metrics_of_yojson json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"
;;

let test_run_metrics_of_yojson_bad_metric () =
  let json =
    `Assoc
      [ "run_id", `String "r"
      ; "agent_name", `String "a"
      ; "timestamp", `Float 0.0
      ; "metrics", `List [ `Assoc [ "name", `Int 42 ] ]
      ]
  in
  match Eval.run_metrics_of_yojson json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for bad metric"
;;

(* ── run_metrics_to_yojson with verdicts ──────────────── *)

let test_run_metrics_to_yojson_with_verdicts () =
  let v : Harness.verdict =
    { passed = false; score = None; evidence = [ "e1" ]; detail = Some "d1" }
  in
  let rm = mk_run ~verdicts:[ v ] [ mk_metric "x" (Int_val 1) ] in
  let json = Eval.run_metrics_to_yojson rm in
  let open Yojson.Safe.Util in
  let verdicts = json |> member "harness_verdicts" |> to_list in
  Alcotest.(check int) "1 verdict" 1 (List.length verdicts);
  let v0 = List.hd verdicts in
  Alcotest.(check bool) "passed false" false (v0 |> member "passed" |> to_bool);
  Alcotest.(check string) "detail" "d1" (v0 |> member "detail" |> to_string)
;;

let test_run_metrics_to_yojson_score_none () =
  let v : Harness.verdict =
    { passed = true; score = None; evidence = []; detail = None }
  in
  let rm = mk_run ~verdicts:[ v ] [] in
  let json = Eval.run_metrics_to_yojson rm in
  let open Yojson.Safe.Util in
  let verdicts = json |> member "harness_verdicts" |> to_list in
  let v0 = List.hd verdicts in
  Alcotest.(check bool) "score null" true (v0 |> member "score" = `Null)
;;

(* ── find_metric_value ────────────────────────────────── *)

let test_find_metric_value_found () =
  let rm = mk_run [ mk_metric "score" (Float_val 0.95) ] in
  match Eval.find_metric_value rm "score" with
  | Some (Float_val f) -> Alcotest.(check (float 0.01)) "value" 0.95 f
  | _ -> Alcotest.fail "expected Float_val"
;;

let test_find_metric_value_missing () =
  let rm = mk_run [] in
  Alcotest.(check bool) "None" true (Eval.find_metric_value rm "nonexistent" = None)
;;

(* ── compute_delta edge cases ─────────────────────────── *)

let test_compute_delta_baseline_zero () =
  let dir, pct =
    Eval.compute_delta ~baseline_val:(Float_val 0.0) ~candidate_val:(Float_val 5.0) ()
  in
  Alcotest.(check bool) "regression for zero baseline" true (dir = Eval.Regression);
  Alcotest.(check bool) "no pct" true (pct = None)
;;

let test_compute_delta_both_zero () =
  let dir, _ =
    Eval.compute_delta ~baseline_val:(Float_val 0.0) ~candidate_val:(Float_val 0.0) ()
  in
  Alcotest.(check bool) "unchanged" true (dir = Eval.Unchanged)
;;

let test_compute_delta_zero_baseline_negative () =
  let dir, _ =
    Eval.compute_delta ~baseline_val:(Float_val 0.0) ~candidate_val:(Float_val (-1.0)) ()
  in
  Alcotest.(check bool) "improvement" true (dir = Eval.Improvement)
;;

let test_compute_delta_non_numeric () =
  let dir, pct =
    Eval.compute_delta ~baseline_val:(String_val "a") ~candidate_val:(String_val "b") ()
  in
  Alcotest.(check bool) "unchanged for strings" true (dir = Eval.Unchanged);
  Alcotest.(check bool) "no pct" true (pct = None)
;;

let test_compute_delta_custom_threshold () =
  let dir, _ =
    Eval.compute_delta
      ~threshold_pct:1.0
      ~baseline_val:(Float_val 100.0)
      ~candidate_val:(Float_val 102.0)
      ()
  in
  Alcotest.(check bool) "regression with 1% threshold" true (dir = Eval.Regression)
;;

let test_compute_delta_bool_values () =
  let dir, _ =
    Eval.compute_delta ~baseline_val:(Bool_val false) ~candidate_val:(Bool_val true) ()
  in
  Alcotest.(check bool) "regression false->true" true (dir = Eval.Regression)
;;

(* ── compare: missing metric in candidate ─────────────── *)

let test_compare_missing_candidate_metric () =
  let baseline =
    mk_run [ mk_metric "a" (Float_val 1.0); mk_metric "b" (Float_val 2.0) ]
  in
  let candidate = mk_run ~run_id:"r2" [ mk_metric "a" (Float_val 1.0) ] in
  let specs =
    [ { Eval.name = "a"; goal = Lower; tolerance_pct = Eval.default_delta_threshold_pct }
    ; { Eval.name = "b"; goal = Lower; tolerance_pct = Eval.default_delta_threshold_pct }
    ]
  in
  match Eval.compare_with_specs ~specs ~baseline ~candidate with
  | Error (Eval.Missing_candidate_metric name) ->
    Alcotest.(check string) "missing metric" "b" name
  | Ok _ | Error _ -> Alcotest.fail "expected Missing_candidate_metric"
;;

(* ── compare: string metric unchanged ─────────────────── *)

let test_compare_string_metric () =
  let baseline = mk_run [ mk_metric "name" (String_val "test") ] in
  let candidate = mk_run ~run_id:"r2" [ mk_metric "name" (String_val "test") ] in
  let specs = [ { Eval.name = "name"; goal = Exact; tolerance_pct = 0.0 } ] in
  match Eval.compare_with_specs ~specs ~baseline ~candidate with
  | Ok cmp -> Alcotest.(check int) "unchanged" 1 (List.length cmp.unchanged)
  | Error _ -> Alcotest.fail "expected comparison"
;;

(* ── threshold: no matching metric ────────────────────── *)

let test_threshold_no_matching_metric () =
  let rm = mk_run [ mk_metric "x" (Int_val 1) ] in
  let ths =
    [ { Eval.metric_name = "missing"; max_value = Some (Int_val 10); min_value = None } ]
  in
  let v = Eval.check_thresholds rm ths in
  Alcotest.(check bool) "pass when metric absent" true v.passed
;;

(* ── threshold: non-numeric values ────────────────────── *)

let test_threshold_non_numeric () =
  let rm = mk_run [ mk_metric "name" (String_val "test") ] in
  let ths =
    [ { Eval.metric_name = "name"; max_value = Some (String_val "z"); min_value = None } ]
  in
  let v = Eval.check_thresholds rm ths in
  Alcotest.(check bool) "pass for non-numeric" true v.passed
;;

(* ── threshold: both max and min ──────────────────────── *)

let test_threshold_both_pass () =
  let rm = mk_run [ mk_metric "x" (Float_val 50.0) ] in
  let ths =
    [ { Eval.metric_name = "x"
      ; max_value = Some (Float_val 100.0)
      ; min_value = Some (Float_val 10.0)
      }
    ]
  in
  let v = Eval.check_thresholds rm ths in
  Alcotest.(check bool) "both pass" true v.passed
;;

let test_threshold_both_fail_min () =
  let rm = mk_run [ mk_metric "x" (Float_val 5.0) ] in
  let ths =
    [ { Eval.metric_name = "x"
      ; max_value = Some (Float_val 100.0)
      ; min_value = Some (Float_val 10.0)
      }
    ]
  in
  let v = Eval.check_thresholds rm ths in
  Alcotest.(check bool) "fail min" false v.passed
;;

(* ── Test runner ───────────────────────────────────────── *)

let () =
  Alcotest.run
    "Eval_coverage"
    [ ( "metric_value_of_yojson"
      , [ Alcotest.test_case "list error" `Quick test_metric_value_of_yojson_error
        ; Alcotest.test_case "null error" `Quick test_metric_value_of_yojson_null
        ] )
    ; ( "show_metric_value"
      , [ Alcotest.test_case "int" `Quick test_show_metric_value_int
        ; Alcotest.test_case "bool false" `Quick test_show_metric_value_bool_false
        ; Alcotest.test_case "string" `Quick test_show_metric_value_string
        ] )
    ; ( "formatters"
      , [ Alcotest.test_case "pp_metric_value" `Quick test_pp_metric_value
        ; Alcotest.test_case "pp_metric" `Quick test_pp_metric
        ; Alcotest.test_case "show_metric" `Quick test_show_metric
        ; Alcotest.test_case "show_run_metrics" `Quick test_show_run_metrics
        ; Alcotest.test_case "pp_run_metrics" `Quick test_pp_run_metrics
        ] )
    ; ( "metric_of_yojson"
      , [ Alcotest.test_case "type error" `Quick test_metric_of_yojson_type_error
        ; Alcotest.test_case "bad value" `Quick test_metric_of_yojson_bad_value
        ; Alcotest.test_case "minimal" `Quick test_metric_of_yojson_minimal
        ] )
    ; ( "metric_to_yojson"
      , [ Alcotest.test_case "full" `Quick test_metric_to_yojson_full
        ; Alcotest.test_case "minimal" `Quick test_metric_to_yojson_minimal
        ] )
    ; ( "run_metrics_of_yojson"
      , [ Alcotest.test_case "type error" `Quick test_run_metrics_of_yojson_type_error
        ; Alcotest.test_case "bad metric" `Quick test_run_metrics_of_yojson_bad_metric
        ] )
    ; ( "run_metrics_to_yojson"
      , [ Alcotest.test_case
            "with verdicts"
            `Quick
            test_run_metrics_to_yojson_with_verdicts
        ; Alcotest.test_case "score None" `Quick test_run_metrics_to_yojson_score_none
        ] )
    ; ( "find_metric_value"
      , [ Alcotest.test_case "found" `Quick test_find_metric_value_found
        ; Alcotest.test_case "missing" `Quick test_find_metric_value_missing
        ] )
    ; ( "compute_delta"
      , [ Alcotest.test_case "baseline zero" `Quick test_compute_delta_baseline_zero
        ; Alcotest.test_case "both zero" `Quick test_compute_delta_both_zero
        ; Alcotest.test_case
            "zero negative"
            `Quick
            test_compute_delta_zero_baseline_negative
        ; Alcotest.test_case "non-numeric" `Quick test_compute_delta_non_numeric
        ; Alcotest.test_case "custom threshold" `Quick test_compute_delta_custom_threshold
        ; Alcotest.test_case "bool values" `Quick test_compute_delta_bool_values
        ] )
    ; ( "compare_extra"
      , [ Alcotest.test_case
            "missing candidate"
            `Quick
            test_compare_missing_candidate_metric
        ; Alcotest.test_case "string metric" `Quick test_compare_string_metric
        ] )
    ; ( "threshold_extra"
      , [ Alcotest.test_case "no matching metric" `Quick test_threshold_no_matching_metric
        ; Alcotest.test_case "non-numeric" `Quick test_threshold_non_numeric
        ; Alcotest.test_case "both pass" `Quick test_threshold_both_pass
        ; Alcotest.test_case "both fail min" `Quick test_threshold_both_fail_min
        ] )
    ]
;;
