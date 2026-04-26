(* #9770: pin canonical metric name + label vocabulary for the
   join_required guard counter.  The execute path emits this
   counter whenever an agent calls a join-required tool without
   first calling [masc_join] (or [masc_start]).

   Test exercises the counter directly — the guard's surrounding
   plumbing (audit emit + system-prompt assembly) is not needed
   to pin the metric contract.  Wiring tests for the guard itself
   live elsewhere; this test only protects the metric vocabulary
   so Grafana / alerting rules cannot drift. *)

let counter_for ~tool ~agent_name ~reason =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_tool_join_required_guard
    ~labels:[ "tool", tool; "agent_name", agent_name; "reason", reason ]
    ()
;;

let test_metric_name_stable () =
  Alcotest.(check string)
    "join-required guard canonical metric name"
    "masc_tool_join_required_guard_total"
    Masc_mcp.Prometheus.metric_tool_join_required_guard
;;

let test_increments_room_uninitialized () =
  let tool = "masc_claim_next" in
  let agent_name = "san-test-9770" in
  let reason = "room_uninitialized" in
  let before = counter_for ~tool ~agent_name ~reason in
  Masc_mcp.Prometheus.inc_counter
    Masc_mcp.Prometheus.metric_tool_join_required_guard
    ~labels:[ "tool", tool; "agent_name", agent_name; "reason", reason ]
    ();
  Alcotest.(check (float 0.0001))
    "room_uninitialized +1"
    (before +. 1.0)
    (counter_for ~tool ~agent_name ~reason)
;;

let test_increments_agent_not_joined () =
  let tool = "masc_claim_next" in
  let agent_name = "nic-test-9770" in
  let reason = "agent_not_joined" in
  let before = counter_for ~tool ~agent_name ~reason in
  Masc_mcp.Prometheus.inc_counter
    Masc_mcp.Prometheus.metric_tool_join_required_guard
    ~labels:[ "tool", tool; "agent_name", agent_name; "reason", reason ]
    ();
  Alcotest.(check (float 0.0001))
    "agent_not_joined +1"
    (before +. 1.0)
    (counter_for ~tool ~agent_name ~reason)
;;

let test_label_isolation_across_reasons () =
  (* Same (tool, agent) but different reason must land in
     different series, otherwise we cannot distinguish the two
     failure modes in operator dashboards. *)
  let tool = "masc_status" in
  let agent_name = "isolation-test-9770" in
  let before_room = counter_for ~tool ~agent_name ~reason:"room_uninitialized" in
  Masc_mcp.Prometheus.inc_counter
    Masc_mcp.Prometheus.metric_tool_join_required_guard
    ~labels:[ "tool", tool; "agent_name", agent_name; "reason", "agent_not_joined" ]
    ();
  Alcotest.(check (float 0.0001))
    "room_uninitialized counter unchanged when agent_not_joined fires"
    before_room
    (counter_for ~tool ~agent_name ~reason:"room_uninitialized")
;;

let test_label_isolation_across_agents () =
  let tool = "masc_claim_next" in
  let reason = "agent_not_joined" in
  let agent_a = "alpha-9770" in
  let agent_b = "beta-9770" in
  let before_a = counter_for ~tool ~agent_name:agent_a ~reason in
  Masc_mcp.Prometheus.inc_counter
    Masc_mcp.Prometheus.metric_tool_join_required_guard
    ~labels:[ "tool", tool; "agent_name", agent_b; "reason", reason ]
    ();
  Alcotest.(check (float 0.0001))
    "alpha counter unaffected by beta increment"
    before_a
    (counter_for ~tool ~agent_name:agent_a ~reason)
;;

let () =
  Alcotest.run
    "join_required_guard_counter_9770"
    [ ( "metric_name"
      , [ Alcotest.test_case "canonical name stable" `Quick test_metric_name_stable ] )
    ; ( "counter"
      , [ Alcotest.test_case
            "room_uninitialized increments"
            `Quick
            test_increments_room_uninitialized
        ; Alcotest.test_case
            "agent_not_joined increments"
            `Quick
            test_increments_agent_not_joined
        ] )
    ; ( "isolation"
      , [ Alcotest.test_case "reasons isolated" `Quick test_label_isolation_across_reasons
        ; Alcotest.test_case "agents isolated" `Quick test_label_isolation_across_agents
        ] )
    ]
;;
