(* #9770: pin canonical metric name + label vocabulary for the
   bind_required guard counter.  The execute path emits this
   counter whenever an agent calls a bind-gated tool without
   first calling [masc_bind] (or [masc_start]).

   Test exercises the counter directly — the guard's surrounding
   plumbing (audit emit + system-prompt assembly) is not needed
   to pin the metric contract.  Wiring tests for the guard itself
   live elsewhere; this test only protects the metric vocabulary
   so Grafana / alerting rules cannot drift. *)

let counter_for ~tool ~agent_name ~reason =
  Masc.Otel_metric_store.metric_value_or_zero
    Masc.Otel_metric_store.metric_tool_bind_required_guard
    ~labels:[
      ("tool", tool);
      ("agent_name", agent_name);
      ("reason", reason);
    ]
    ()

let test_metric_name_stable () =
  Alcotest.(check string)
    "bind-required guard canonical metric name"
    "masc_tool_bind_required_guard_total"
    Masc.Otel_metric_store.metric_tool_bind_required_guard

let test_increments_workspace_uninitialized () =
  let tool = "keeper_task_claim" in
  let agent_name = "san-test-9770" in
  let reason = "workspace_uninitialized" in
  let before = counter_for ~tool ~agent_name ~reason in
  Masc.Otel_metric_store.inc_counter
    Masc.Otel_metric_store.metric_tool_bind_required_guard
    ~labels:[ ("tool", tool);
              ("agent_name", agent_name);
              ("reason", reason) ]
    ();
  Alcotest.(check (float 0.0001))
    "workspace_uninitialized +1"
    (before +. 1.0)
    (counter_for ~tool ~agent_name ~reason)

let test_increments_agent_not_bound () =
  let tool = "keeper_task_claim" in
  let agent_name = "nic-test-9770" in
  let reason = "agent_not_bound" in
  let before = counter_for ~tool ~agent_name ~reason in
  Masc.Otel_metric_store.inc_counter
    Masc.Otel_metric_store.metric_tool_bind_required_guard
    ~labels:[ ("tool", tool);
              ("agent_name", agent_name);
              ("reason", reason) ]
    ();
  Alcotest.(check (float 0.0001))
    "agent_not_bound +1"
    (before +. 1.0)
    (counter_for ~tool ~agent_name ~reason)

let test_label_isolation_across_reasons () =
  (* Same (tool, agent) but different reason must land in
     different series, otherwise we cannot distinguish the two
     failure modes in operator dashboards. *)
  let tool = "masc_status" in
  let agent_name = "isolation-test-9770" in
  let before_workspace =
    counter_for ~tool ~agent_name ~reason:"workspace_uninitialized"
  in
  Masc.Otel_metric_store.inc_counter
    Masc.Otel_metric_store.metric_tool_bind_required_guard
    ~labels:[ ("tool", tool);
              ("agent_name", agent_name);
              ("reason", "agent_not_bound") ]
    ();
  Alcotest.(check (float 0.0001))
    "workspace_uninitialized counter unchanged when agent_not_bound fires"
    before_workspace
    (counter_for ~tool ~agent_name ~reason:"workspace_uninitialized")

let test_label_isolation_across_agents () =
  let tool = "keeper_task_claim" in
  let reason = "agent_not_bound" in
  let agent_a = "alpha-9770" in
  let agent_b = "beta-9770" in
  let before_a = counter_for ~tool ~agent_name:agent_a ~reason in
  Masc.Otel_metric_store.inc_counter
    Masc.Otel_metric_store.metric_tool_bind_required_guard
    ~labels:[ ("tool", tool);
              ("agent_name", agent_b);
              ("reason", reason) ]
    ();
  Alcotest.(check (float 0.0001))
    "alpha counter unaffected by beta increment"
    before_a
    (counter_for ~tool ~agent_name:agent_a ~reason)

let () =
  Alcotest.run "bind_required_guard_counter_9770" [
    "metric_name", [
      Alcotest.test_case "canonical name stable" `Quick
        test_metric_name_stable;
    ];
    "counter", [
      Alcotest.test_case "workspace_uninitialized increments" `Quick
        test_increments_workspace_uninitialized;
      Alcotest.test_case "agent_not_bound increments" `Quick
        test_increments_agent_not_bound;
    ];
    "isolation", [
      Alcotest.test_case "reasons isolated" `Quick
        test_label_isolation_across_reasons;
      Alcotest.test_case "agents isolated" `Quick
        test_label_isolation_across_agents;
    ];
  ]
