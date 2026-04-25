(* #9662: pin canonical metric name + label vocabulary for the
   timeout-policy overshoot counter.  [Timeout_policy.overshoot_warn]
   emits this counter whenever the actual wall time exceeds the
   declared deadline by more than the slack window.

   Tests verify:
   - canonical metric name stable;
   - within-slack does NOT increment;
   - past-slack DOES increment;
   - per-(layer, origin) label isolation. *)

module TP = Masc_mcp.Timeout_policy

let counter_for ~layer ~origin =
  Masc_mcp.Prometheus.metric_value_or_zero
    TP.metric_overshoot_total
    ~labels:[ ("layer", layer); ("origin", origin) ]
    ()

let make_deadline ~layer ~origin ~wall_cap_s =
  TP.Deadline.make ~layer ~origin ~wall_cap_s ~now:0.0

let test_metric_name_stable () =
  Alcotest.(check string)
    "overshoot canonical metric name"
    "masc_timeout_policy_overshoot_total"
    TP.metric_overshoot_total

let test_within_slack_no_increment () =
  let deadline =
    make_deadline ~layer:TP.Layer.Oas_bridge
      ~origin:"slack-test-9662" ~wall_cap_s:573.0
  in
  let before = counter_for ~layer:"oas_bridge" ~origin:"slack-test-9662" in
  (* 575s vs 573s budget, 2s excess — within default 5s slack. *)
  let warned = TP.overshoot_warn ~deadline ~actual_wall_s:575.0 () in
  Alcotest.(check bool) "no warn within slack" false warned;
  Alcotest.(check (float 0.0001))
    "counter unchanged within slack"
    before
    (counter_for ~layer:"oas_bridge" ~origin:"slack-test-9662")

let test_past_slack_increments () =
  let deadline =
    make_deadline ~layer:TP.Layer.Oas_bridge
      ~origin:"keeper_llm_bridge_9662_test" ~wall_cap_s:573.0
  in
  let before =
    counter_for ~layer:"oas_bridge"
      ~origin:"keeper_llm_bridge_9662_test"
  in
  (* The exact #9662 reported case: 596.6s vs 573s = 23.6s excess
     well past the 5s default slack. *)
  let warned = TP.overshoot_warn ~deadline ~actual_wall_s:596.6 () in
  Alcotest.(check bool) "warned past slack" true warned;
  Alcotest.(check (float 0.0001))
    "counter +1"
    (before +. 1.0)
    (counter_for ~layer:"oas_bridge"
       ~origin:"keeper_llm_bridge_9662_test")

let test_layer_isolation () =
  (* Same origin but different layer must land in different
     series — operators distinguish OAS bridge overshoot from
     tool-layer overshoot. *)
  let origin = "layer-iso-9662" in
  let oas =
    make_deadline ~layer:TP.Layer.Oas_bridge ~origin ~wall_cap_s:60.0
  in
  let tool =
    make_deadline ~layer:TP.Layer.Tool ~origin ~wall_cap_s:60.0
  in
  let before_tool = counter_for ~layer:"tool" ~origin in
  let _ = TP.overshoot_warn ~deadline:oas ~actual_wall_s:90.0 () in
  Alcotest.(check (float 0.0001))
    "tool counter unchanged when oas overshoots"
    before_tool
    (counter_for ~layer:"tool" ~origin);
  let _ = TP.overshoot_warn ~deadline:tool ~actual_wall_s:90.0 () in
  Alcotest.(check (float 0.0001))
    "tool counter +1 after tool overshoot"
    (before_tool +. 1.0)
    (counter_for ~layer:"tool" ~origin)

let test_origin_isolation () =
  let layer = TP.Layer.Keeper_turn in
  let alpha =
    make_deadline ~layer ~origin:"alpha-9662" ~wall_cap_s:60.0
  in
  let _beta =
    make_deadline ~layer ~origin:"beta-9662" ~wall_cap_s:60.0
  in
  let before_beta = counter_for ~layer:"keeper_turn" ~origin:"beta-9662" in
  let _ = TP.overshoot_warn ~deadline:alpha ~actual_wall_s:90.0 () in
  Alcotest.(check (float 0.0001))
    "beta counter unchanged after alpha overshoot"
    before_beta
    (counter_for ~layer:"keeper_turn" ~origin:"beta-9662")

let () =
  Alcotest.run "timeout_policy_overshoot_counter_9662" [
    "metric_name", [
      Alcotest.test_case "canonical name stable" `Quick
        test_metric_name_stable;
    ];
    "increment", [
      Alcotest.test_case "within slack → no increment" `Quick
        test_within_slack_no_increment;
      Alcotest.test_case "past slack → +1 (exact #9662 case)" `Quick
        test_past_slack_increments;
    ];
    "isolation", [
      Alcotest.test_case "layer labels isolated" `Quick
        test_layer_isolation;
      Alcotest.test_case "origin labels isolated" `Quick
        test_origin_isolation;
    ];
  ]
