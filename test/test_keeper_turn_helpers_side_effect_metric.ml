open Alcotest

module Helpers = Masc_mcp.Keeper_turn_helpers
module Prometheus = Masc_mcp.Prometheus

let test_side_effect_issue_increments_failure_metric () =
  let keeper_name = "side-effect-metric-keeper-0507" in
  let labels =
    [ ("keeper", keeper_name); ("site", "trajectory_finalize") ]
  in
  let before =
    Prometheus.metric_value_or_zero
      Prometheus.metric_keeper_dispatch_event_failures
      ~labels
      ()
  in
  let config =
    Masc_mcp.Coord.default_config
      (Filename.concat (Filename.get_temp_dir_name ())
         "masc-side-effect-metric-0507")
  in
  Helpers.report_keeper_cycle_side_effect_issue
    ~config
    ~keeper_name
    ~side_effect:"trajectory finalize"
    "test failure";
  let after =
    Prometheus.metric_value_or_zero
      Prometheus.metric_keeper_dispatch_event_failures
      ~labels
      ()
  in
  check (float 0.0001) "side-effect metric increments"
    (before +. 1.0)
    after

let () =
  run "keeper_turn_helpers_side_effect_metric"
    [
      ( "side_effect_metric",
        [
          test_case "report side-effect issue increments metric" `Quick
            test_side_effect_issue_increments_failure_metric;
        ] );
    ]
