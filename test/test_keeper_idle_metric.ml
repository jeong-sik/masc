module HK = Masc.Keeper_hooks_oas_idle
module Metrics = Masc.Otel_metric_store

let make_meta_ref name : Masc.Keeper_meta_contract.keeper_meta ref =
  let json : Yojson.Safe.t =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String name
      ; "trace_id", `String "keeper-idle-metric-test"
      ; "tool_access", Json_util.json_string_list []
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> ref meta
  | Error e -> failwith ("make_meta_ref: " ^ e)

let test_keeper_idle_decision_sets_gauge () =
  let keeper = "test-keeper-idle-metric" in
  let meta_ref = make_meta_ref keeper in
  ignore
    (HK.keeper_idle_decision
       ~meta_ref
       ~consecutive_idle_turns:2
       ~tool_names:[ "keeper_board_list" ]
      : Agent_sdk.Hooks.hook_decision);
  Alcotest.(check (float 0.0001))
    "consecutive idle gauge"
    2.0
    (Metrics.metric_value_or_zero
       Keeper_metrics.(to_string ConsecutiveIdle)
       ~labels:[ "keeper", keeper ]
       ())

let test_keeper_idle_decision_clamps_negative_gauge () =
  let keeper = "test-keeper-idle-metric-negative" in
  let meta_ref = make_meta_ref keeper in
  ignore
    (HK.keeper_idle_decision
       ~meta_ref
       ~consecutive_idle_turns:(-1)
       ~tool_names:[]
      : Agent_sdk.Hooks.hook_decision);
  Alcotest.(check (float 0.0001))
    "negative idle count clamps to zero"
    0.0
    (Metrics.metric_value_or_zero
       Keeper_metrics.(to_string ConsecutiveIdle)
       ~labels:[ "keeper", keeper ]
       ())

let () =
  Alcotest.run
    "keeper_idle_metric"
    [ ( "consecutive_idle"
      , [ Alcotest.test_case
            "keeper_idle_decision sets gauge"
            `Quick
            test_keeper_idle_decision_sets_gauge
        ; Alcotest.test_case
            "negative count clamps to zero"
            `Quick
            test_keeper_idle_decision_clamps_negative_gauge
        ] )
    ]
