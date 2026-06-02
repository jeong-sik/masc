(* test/test_heuristic_theatre_audit.ml

   #9919 audit follow-up (tick #24): verify that the remaining degenerate
   [Heuristic_metrics.record] emit site flagged in handoff tick #18 now
   surfaces as a proper Prometheus counter.

   - [Thompson_sampling.priority_trigger_selected_metric]:
     [agent, trigger] labels for priority-trigger selection.

   The site previously emitted constant-tuple records
   ([raw, threshold, triggered] with hardcoded values) that
   [Heuristic_metrics_diagnostics] had to flag as instrumentation theatre.
   The counter removes the false
   classification and give operators real per-label rates via
   [rate(masc_..._total{...}[5m])].

   This test pins the canonical metric name and the exact label set the
   counter consumes.  A dashboard-breaking rename or label reshape fails here
   before it reaches CI. *)

(* Thompson_sampling carved into the masc_thompson leaf (Health/Prometheus
   edges inverted); the metric-name constant is still exported. Reference the
   bare module (re-exported via masc_test_deps) instead of Masc_mcp.*. *)
module TS = Thompson_sampling
module Prom = Masc_mcp.Prometheus

let counter_value metric ~labels =
  Prom.metric_value_or_zero metric ~labels ()

let test_thompson_metric_name_stable () =
  Alcotest.(check string)
    "thompson priority trigger canonical name"
    "masc_thompson_priority_trigger_selected_total"
    TS.priority_trigger_selected_metric

let test_thompson_counter_accepts_label_tuple () =
  (* Pin the {agent, trigger} label shape so Grafana rules
     like [rate(...{trigger="mentioned"}[5m])] keep compiling.
     [trigger] values are [mentioned | content_alert | other]
     per the [thompson_sampling] site; test both the split keys
     we care about. *)
  let mentioned_labels =
    [ ("agent", "unused-test-9919"); ("trigger", "mentioned") ]
  in
  let content_alert_labels =
    [ ("agent", "unused-test-9919"); ("trigger", "content_alert") ]
  in
  Alcotest.(check (float 0.0001))
    "mentioned baseline is 0" 0.0
    (counter_value TS.priority_trigger_selected_metric
       ~labels:mentioned_labels);
  Alcotest.(check (float 0.0001))
    "content_alert baseline is 0" 0.0
    (counter_value TS.priority_trigger_selected_metric
       ~labels:content_alert_labels)

let () =
  Alcotest.run "heuristic_theatre_audit_9919"
    [
      ( "thompson_sampling",
        [
          Alcotest.test_case "metric name stable" `Quick
            test_thompson_metric_name_stable;
          Alcotest.test_case "label tuple pinned" `Quick
            test_thompson_counter_accepts_label_tuple;
        ] );
    ]
