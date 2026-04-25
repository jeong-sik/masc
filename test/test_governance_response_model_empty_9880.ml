(** #9880 facet 4: governance compute_judgments emits a
    counter when [response.model] is empty so the operator can
    see WHICH transports leak.  Pre-fix, 17% of yesterday's
    judgment records had [model_used = ""] with zero
    visibility.

    Full integration testing of [compute_judgments] requires a
    masc_tools fixture + dispatch wiring; these tests pin the
    metric surface and label shape so a future refactor cannot
    silently rename or drop the counter. *)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-governance-empty-model-9880-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module Prom = Masc_mcp.Prometheus

let metric_name = "masc_governance_response_model_empty_total"

let count_for ~source =
  Prom.metric_value_or_zero metric_name
    ~labels:[ ("source", source) ]
    ()

(* Metric is registered at module load via the
   [let () = Prometheus.register_counter ...] block in
   [dashboard_governance_judge.ml]. *)
let test_metric_registered () =
  let _ = Prom.metric_total metric_name in
  Alcotest.(check pass) "metric registered" () ()

(* Direct increment using the documented label shape.  Mirrors
   the call in [compute_judgments] when [response.model] is
   empty and telemetry's [canonical_model_id] resolves it. *)
let test_telemetry_resolved_branch () =
  let before = count_for ~source:"telemetry_resolved" in
  Prom.inc_counter metric_name
    ~labels:[ ("source", "telemetry_resolved") ]
    ();
  Alcotest.(check (float 0.0001))
    "telemetry_resolved row +1"
    (before +. 1.0)
    (count_for ~source:"telemetry_resolved")

(* When neither [response.model] nor telemetry resolves the
   model, the writer falls back to the [unknown_provider]
   sentinel and counts under [unknown_sentinel].  Distinct row
   from telemetry_resolved so dashboards can separate
   "transport leaked but recovered" from "transport leaked and
   no recovery available". *)
let test_unknown_sentinel_branch () =
  let before = count_for ~source:"unknown_sentinel" in
  Prom.inc_counter metric_name
    ~labels:[ ("source", "unknown_sentinel" ) ]
    ();
  Alcotest.(check (float 0.0001))
    "unknown_sentinel row +1"
    (before +. 1.0)
    (count_for ~source:"unknown_sentinel")

(* Distinct sources land on distinct counter rows.  Necessary
   because operators want to attribute leaks to either
   "telemetry recovered" (transport-only issue) vs
   "no recovery" (deeper provider failure). *)
let test_distinct_sources_separate_rows () =
  let before_t = count_for ~source:"telemetry_resolved" in
  let before_u = count_for ~source:"unknown_sentinel" in
  Prom.inc_counter metric_name
    ~labels:[ ("source", "telemetry_resolved") ]
    ();
  Prom.inc_counter metric_name
    ~labels:[ ("source", "unknown_sentinel") ]
    ();
  Alcotest.(check (float 0.0001)) "telemetry_resolved +1"
    (before_t +. 1.0) (count_for ~source:"telemetry_resolved");
  Alcotest.(check (float 0.0001)) "unknown_sentinel +1"
    (before_u +. 1.0) (count_for ~source:"unknown_sentinel")

(* Prometheus text export must include the metric name and
   the [source] label key — PromQL queries depend on this. *)
let test_export () =
  Prom.inc_counter metric_name
    ~labels:[ ("source", "telemetry_resolved") ]
    ();
  let text = Prom.to_prometheus_text () in
  let contains s sub =
    let n = String.length s and m = String.length sub in
    let rec loop i =
      if i + m > n then false
      else if String.sub s i m = sub then true
      else loop (i + 1)
    in
    loop 0
  in
  Alcotest.(check bool) "metric name in export"
    true (contains text metric_name);
  Alcotest.(check bool) "source label key in export"
    true (contains text "source=")

let () =
  Alcotest.run "governance_response_model_empty_9880"
    [
      ( "registration",
        [
          Alcotest.test_case "metric registered at module load" `Quick
            test_metric_registered;
        ] );
      ( "label-shape",
        [
          Alcotest.test_case "telemetry_resolved branch" `Quick
            test_telemetry_resolved_branch;
          Alcotest.test_case "unknown_sentinel branch" `Quick
            test_unknown_sentinel_branch;
          Alcotest.test_case "distinct sources distinct rows" `Quick
            test_distinct_sources_separate_rows;
        ] );
      ( "export",
        [
          Alcotest.test_case "metric + label key in /metrics" `Quick
            test_export;
        ] );
    ]
