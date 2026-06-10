module HK = Masc.Keeper_hooks_oas
module Metrics = Masc.Otel_metric_store

let keeper = "test-keeper-tool-duration-buckets"
let tool = "keeper_board_list"
let provider = HK.runtime_lane_label
let outcome = "ok"

let base_labels =
  [ "keeper", keeper; "provider", provider; "tool", tool; "outcome", outcome ]

let bucket_metric = Keeper_metrics.(to_string ToolCallDurationBucket)
let duration_metric = Keeper_metrics.(to_string ToolCallDuration)

let bucket_count le =
  Metrics.metric_value_or_zero bucket_metric ~labels:(base_labels @ [ "le", le ]) ()

let summary duration_ms =
  HK.tool_execution_summary ~tool_name:tool ~model:"provider-owned-model" ~success:true
    ~duration_ms

let test_metric_names_match_dashboard_queries () =
  Alcotest.(check string)
    "bucket metric"
    "masc_keeper_tool_call_duration_seconds_bucket_total"
    bucket_metric;
  Alcotest.(check string)
    "duration metric"
    "masc_keeper_tool_call_duration_seconds"
    duration_metric

let test_record_emits_sum_count_and_cumulative_buckets () =
  let before_sum = Metrics.metric_value_or_zero duration_metric ~labels:base_labels () in
  let before_count =
    Metrics.metric_value_or_zero (duration_metric ^ "_count") ~labels:base_labels ()
  in
  let before_le_1 = bucket_count "1" in
  let before_le_2_5 = bucket_count "2.5" in
  let before_inf = bucket_count "+Inf" in
  HK.record_keeper_tool_duration_metric ~keeper_name:keeper (summary 1200.0);
  Alcotest.(check (float 0.0001))
    "sum adds seconds"
    (before_sum +. 1.2)
    (Metrics.metric_value_or_zero duration_metric ~labels:base_labels ());
  Alcotest.(check (float 0.0001))
    "count increments"
    (before_count +. 1.0)
    (Metrics.metric_value_or_zero (duration_metric ^ "_count") ~labels:base_labels ());
  Alcotest.(check (float 0.0001))
    "lower bucket remains unchanged"
    before_le_1
    (bucket_count "1");
  Alcotest.(check (float 0.0001))
    "matching upper bucket increments"
    (before_le_2_5 +. 1.0)
    (bucket_count "2.5");
  Alcotest.(check (float 0.0001))
    "+Inf bucket increments"
    (before_inf +. 1.0)
    (bucket_count "+Inf")

let test_record_materializes_zero_lower_bucket () =
  let keeper = "test-keeper-tool-duration-long" in
  let labels =
    [ "keeper", keeper
    ; "provider", provider
    ; "tool", tool
    ; "outcome", outcome
    ]
  in
  let count le =
    Metrics.metric_value_or_zero bucket_metric ~labels:(labels @ [ "le", le ]) ()
  in
  HK.record_keeper_tool_duration_metric ~keeper_name:keeper (summary 65_000.0);
  Alcotest.(check (float 0.0001))
    "finite lower bucket exists at zero"
    0.0
    (count "60");
  Alcotest.(check (float 0.0001)) "+Inf increments" 1.0 (count "+Inf")

let () =
  Alcotest.run
    "keeper_tool_duration_buckets"
    [ ( "names"
      , [ Alcotest.test_case
            "match dashboard metric names"
            `Quick
            test_metric_names_match_dashboard_queries
        ] )
    ; ( "record"
      , [ Alcotest.test_case
            "sum count and cumulative buckets"
            `Quick
            test_record_emits_sum_count_and_cumulative_buckets
        ; Alcotest.test_case
            "long observations materialize lower buckets"
            `Quick
            test_record_materializes_zero_lower_bucket
        ] )
    ]
