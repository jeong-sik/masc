(* test/test_keeper_tool_use_failure_counter.ml

   #9919: verify that [post_tool_use_failure] in keeper_hooks_oas
   emits a proper Prometheus counter with [keeper] and [tool]
   labels instead of the degenerate [Heuristic_metrics.record]
   that produced 51 identical 1-bit rows in production. *)

module H = Masc_mcp.Keeper_hooks_oas
module Prom = Masc_mcp.Prometheus

let counter_for ~keeper ~tool =
  Prom.metric_value_or_zero
    H.tool_use_failure_metric
    ~labels:[ ("keeper", keeper); ("tool", tool) ]
    ()

let test_metric_name_matches_convention () =
  (* Prometheus _total suffix + masc_ prefix follow the existing
     counter naming in keeper_hooks_oas.  A rename would break
     dashboards and #9880 governance readers. *)
  Alcotest.(check string)
    "tool_use_failure counter uses canonical masc_*_total name"
    "masc_keeper_tool_use_failure_total"
    H.tool_use_failure_metric

let test_record_increments_with_labels () =
  let keeper = "test-keeper-9919-a" in
  let tool = "board_post" in
  let before = counter_for ~keeper ~tool in
  H.record_tool_use_failure ~keeper_name:keeper ~tool_name:tool;
  Alcotest.(check (float 0.0001))
    "counter +1 for (keeper, tool) pair"
    (before +. 1.0) (counter_for ~keeper ~tool)

let test_labels_isolate_keeper_tool_pairs () =
  (* #9919 root complaint: prior emit had no identifying dimension.
     Verify that two distinct (keeper, tool) pairs accumulate
     independently — a single emit on one pair must not increment
     the other. *)
  let a_keeper = "test-keeper-9919-a" in
  let b_keeper = "test-keeper-9919-b" in
  let tool = "keeper_board_comment" in
  let a_before = counter_for ~keeper:a_keeper ~tool in
  let b_before = counter_for ~keeper:b_keeper ~tool in
  H.record_tool_use_failure ~keeper_name:a_keeper ~tool_name:tool;
  Alcotest.(check (float 0.0001))
    "A counter +1" (a_before +. 1.0)
    (counter_for ~keeper:a_keeper ~tool);
  Alcotest.(check (float 0.0001))
    "B counter unchanged" b_before
    (counter_for ~keeper:b_keeper ~tool)

let () =
  Alcotest.run "keeper_tool_use_failure_counter_9919"
    [
      ( "metric_name",
        [
          Alcotest.test_case "masc_*_total convention" `Quick
            test_metric_name_matches_convention;
        ] );
      ( "counter",
        [
          Alcotest.test_case "increments with labels" `Quick
            test_record_increments_with_labels;
          Alcotest.test_case "isolates keeper/tool pairs" `Quick
            test_labels_isolate_keeper_tool_pairs;
        ] );
    ]
