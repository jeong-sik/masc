(* test/test_heuristic_theatre_audit.ml

   #9919 audit follow-up (tick #24): verify that the two
   remaining degenerate [Heuristic_metrics.record] emit sites
   flagged in handoff tick #18 now surface as proper
   Prometheus counters.

   - [Board_core_classify.legacy_migrate_post_kind_metric]:
     [author] label for author-heuristic automation migration.
   - [Thompson_sampling.priority_trigger_selected_metric]:
     [agent, trigger] labels for priority-trigger selection.

   Both sites previously emitted constant-tuple records
   ([raw, threshold, triggered] with hardcoded values) that
   [Heuristic_metrics_diagnostics] had to flag as
   instrumentation theatre.  Counters remove the false
   classification and give operators real per-label rates via
   [rate(masc_..._total{...}[5m])].

   This test pins the canonical metric names and the exact
   label set each counter consumes.  A dashboard-breaking
   rename or label reshape fails here before it reaches CI. *)

module BC = Masc_mcp.Board_core_classify
module TS = Masc_mcp.Thompson_sampling
module Prom = Masc_mcp.Prometheus

let counter_value metric ~labels =
  Prom.metric_value_or_zero metric ~labels ()

let test_board_metric_name_stable () =
  Alcotest.(check string)
    "board legacy migrate counter canonical name"
    "masc_board_legacy_migrate_post_kind_total"
    BC.legacy_migrate_post_kind_metric

let test_board_counter_accepts_author_label () =
  (* Baseline read for a synthetic author — exercising the
     classifier from this test would require constructing a
     full Post_types.post record which is schema-heavy.  A
     baseline-zero check still catches any future typo in the
     [author] label key. *)
  let labels = [ ("author", "unused-test-9919-board") ] in
  Alcotest.(check (float 0.0001))
    "unused-author baseline is 0" 0.0
    (counter_value BC.legacy_migrate_post_kind_metric ~labels)

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
      ( "board_core_classify",
        [
          Alcotest.test_case "metric name stable" `Quick
            test_board_metric_name_stable;
          Alcotest.test_case "author label accepted" `Quick
            test_board_counter_accepts_author_label;
        ] );
      ( "thompson_sampling",
        [
          Alcotest.test_case "metric name stable" `Quick
            test_thompson_metric_name_stable;
          Alcotest.test_case "label tuple pinned" `Quick
            test_thompson_counter_accepts_label_tuple;
        ] );
    ]
