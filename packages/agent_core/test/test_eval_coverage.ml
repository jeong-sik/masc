(** Tests for the JSON encoders of the Eval run metrics. *)

open Agent_core

(* ── Helpers ──────────────────────────────────────────── *)

let mk_metric ?(unit_ = None) ?(tags = []) name value : Eval.metric =
  { name; value; unit_; tags }
;;

let mk_run ?(run_id = "r1") ?(agent_name = "test") ?(verdicts = []) metrics
  : Eval.run_metrics
  =
  { run_id; agent_name; timestamp = 1000.0; metrics; harness_verdicts = verdicts }
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

(* ── Runner ───────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Eval_coverage"
    [ ( "metric_to_yojson"
      , [ Alcotest.test_case "full" `Quick test_metric_to_yojson_full
        ; Alcotest.test_case "minimal" `Quick test_metric_to_yojson_minimal
        ] )
    ; ( "run_metrics_to_yojson"
      , [ Alcotest.test_case
            "with verdicts"
            `Quick
            test_run_metrics_to_yojson_with_verdicts
        ; Alcotest.test_case "score None" `Quick test_run_metrics_to_yojson_score_none
        ] )
    ]
;;
