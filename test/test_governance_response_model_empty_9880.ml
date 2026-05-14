(** #9880 facet 4: governance compute_judgments emits a
    counter when [response.model] is empty so the operator can
    see WHICH transports leak.  Pre-fix, 17% of yesterday's
    judgment records had [model_used = ""] with zero
    visibility.

    The fallback resolver is tested directly so this cannot
    degrade into a metric-only smoke test that never proves
    [model_used] is actually filled. *)

let () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-governance-empty-model-9880-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir
;;

module Prom = Masc_mcp.Prometheus
module Judge = Masc_mcp.Dashboard_governance_judge

let metric_name = "masc_governance_response_model_empty_total"

let count_for ~source =
  Prom.metric_value_or_zero metric_name ~labels:[ "source", source ] ()
;;

(* Metric is registered at module load via [Prometheus.register_counter
   ~labels:[]] in [dashboard_governance_judge.ml]. [get_metric_value
   ~labels:[] ()] returns [Some 0.0] when registration ran, [None]
   otherwise.

   [metric_total] cannot distinguish "not registered" from "registered
   but no observations yet" — both return [0.0]. *)
let test_metric_registered () =
  let registered = Prom.get_metric_value metric_name () in
  Alcotest.(check bool) "metric registered" true (Option.is_some registered)
;;

(* Direct increment using the documented label shape.  Mirrors
   the call in [compute_judgments] when [response.model] is
   empty and telemetry's [canonical_model_id] resolves it. *)
let test_telemetry_resolved_branch () =
  let before = count_for ~source:"telemetry_resolved" in
  Prom.inc_counter metric_name ~labels:[ "source", "telemetry_resolved" ] ();
  Alcotest.(check (float 0.0001))
    "telemetry_resolved row +1"
    (before +. 1.0)
    (count_for ~source:"telemetry_resolved")
;;

(* When neither [response.model] nor telemetry resolves the model, the writer
   still projects the neutral runtime lane and counts under
   [unknown_sentinel]. Distinct rows let dashboards separate "transport leaked
   but recovered" from "transport leaked and no recovery available" without
   exposing concrete provider/model identity. *)
let test_unknown_sentinel_branch () =
  let before = count_for ~source:"unknown_sentinel" in
  Prom.inc_counter metric_name ~labels:[ "source", "unknown_sentinel" ] ();
  Alcotest.(check (float 0.0001))
    "unknown_sentinel row +1"
    (before +. 1.0)
    (count_for ~source:"unknown_sentinel")
;;

(* Distinct sources land on distinct counter rows.  Necessary
   because operators want to attribute leaks to either
   "telemetry recovered" (transport-only issue) vs
   "no recovery" (deeper provider failure). *)
let test_distinct_sources_separate_rows () =
  let before_t = count_for ~source:"telemetry_resolved" in
  let before_u = count_for ~source:"unknown_sentinel" in
  Prom.inc_counter metric_name ~labels:[ "source", "telemetry_resolved" ] ();
  Prom.inc_counter metric_name ~labels:[ "source", "unknown_sentinel" ] ();
  Alcotest.(check (float 0.0001))
    "telemetry_resolved +1"
    (before_t +. 1.0)
    (count_for ~source:"telemetry_resolved");
  Alcotest.(check (float 0.0001))
    "unknown_sentinel +1"
    (before_u +. 1.0)
    (count_for ~source:"unknown_sentinel")
;;

let check_resolution ~msg ~raw_model ~canonical_model_id ~expected_model ~expected_source =
  let model, source =
    Judge.resolve_governance_model_used ~raw_model ~canonical_model_id
  in
  Alcotest.(check string) (msg ^ " model") expected_model model;
  Alcotest.(check string)
    (msg ^ " source")
    expected_source
    (Judge.governance_model_source_to_string source)
;;

let test_non_empty_raw_model_wins () =
  check_resolution
    ~msg:"raw model"
    ~raw_model:"claude-code:auto"
    ~canonical_model_id:(Some "anthropic:claude-opus-4-7")
    ~expected_model:"runtime"
    ~expected_source:"response_model"
;;

let test_empty_raw_falls_back_to_telemetry () =
  check_resolution
    ~msg:"telemetry fallback"
    ~raw_model:""
    ~canonical_model_id:(Some " anthropic:claude-opus-4-7 ")
    ~expected_model:"runtime"
    ~expected_source:"telemetry_resolved"
;;

let test_empty_everywhere_uses_unknown_sentinel () =
  check_resolution
    ~msg:"unknown sentinel"
    ~raw_model:""
    ~canonical_model_id:None
    ~expected_model:"runtime"
    ~expected_source:"unknown_sentinel"
;;

let test_empty_canonical_id_uses_unknown_sentinel () =
  check_resolution
    ~msg:"empty canonical"
    ~raw_model:""
    ~canonical_model_id:(Some "")
    ~expected_model:"runtime"
    ~expected_source:"unknown_sentinel"
;;

(* Prometheus text export must include the metric name and
   the [source] label key — PromQL queries depend on this. *)
let test_export () =
  Prom.inc_counter metric_name ~labels:[ "source", "telemetry_resolved" ] ();
  let text = Prom.to_prometheus_text () in
  let contains s sub =
    let n = String.length s
    and m = String.length sub in
    let rec loop i =
      if i + m > n then false else if String.sub s i m = sub then true else loop (i + 1)
    in
    loop 0
  in
  Alcotest.(check bool) "metric name in export" true (contains text metric_name);
  Alcotest.(check bool) "source label key in export" true (contains text "source=")
;;

let () =
  Alcotest.run
    "governance_response_model_empty_9880"
    [ ( "registration"
      , [ Alcotest.test_case
            "metric registered at module load"
            `Quick
            test_metric_registered
        ] )
    ; ( "label-shape"
      , [ Alcotest.test_case
            "telemetry_resolved branch"
            `Quick
            test_telemetry_resolved_branch
        ; Alcotest.test_case "unknown_sentinel branch" `Quick test_unknown_sentinel_branch
        ; Alcotest.test_case
            "distinct sources distinct rows"
            `Quick
            test_distinct_sources_separate_rows
        ] )
    ; ( "fallback-tiers"
      , [ Alcotest.test_case "raw model wins" `Quick test_non_empty_raw_model_wins
        ; Alcotest.test_case
            "empty raw -> telemetry canonical"
            `Quick
            test_empty_raw_falls_back_to_telemetry
        ; Alcotest.test_case
            "empty everywhere -> sentinel"
            `Quick
            test_empty_everywhere_uses_unknown_sentinel
        ; Alcotest.test_case
            "empty canonical_model_id -> sentinel"
            `Quick
            test_empty_canonical_id_uses_unknown_sentinel
        ] )
    ; "export", [ Alcotest.test_case "metric + label key in /metrics" `Quick test_export ]
    ]
;;
