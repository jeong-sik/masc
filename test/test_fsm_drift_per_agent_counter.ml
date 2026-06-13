(* #9795 follow-up: per-agent FSM drift counter.

   Pins the canonical metric name + label shape for the
   per-agent breakout, and verifies that
   [Workspace_hooks.fsm_drift_observer_fn] emits to BOTH the existing
   variant-only counter and the new per-agent counter without
   double-counting either side. *)

let () = Masc.Workspace_metric_hooks.install ()

let fsm_drift_metric = "masc_task_fsm_drift_total"
let fsm_drift_per_agent_metric = "masc_task_fsm_drift_per_agent_total"

let record_fsm_drift_with_agent ~variant ~force ~agent_name =
  (Atomic.get Workspace_hooks.fsm_drift_observer_fn) ~variant ~force ~agent_name
;;

let counter_for_per_agent ~variant ~agent_name ~force =
  Masc.Otel_metric_store.metric_value_or_zero
    fsm_drift_per_agent_metric
    ~labels:[
      ("variant", variant);
      ("agent_name", agent_name);
      ("force", if force then "true" else "false");
    ]
    ()

let counter_for_variant ~variant ~force =
  Masc.Otel_metric_store.metric_value_or_zero
    fsm_drift_metric
    ~labels:[
      ("variant", variant);
      ("force", if force then "true" else "false");
    ]
    ()

let test_metric_name_stable () =
  let metric =
    Masc.Otel_metric_store.snapshot ()
    |> List.find_opt (fun (m : Masc.Otel_metric_store.metric) ->
      String.equal m.name fsm_drift_per_agent_metric && m.labels = [])
  in
  Alcotest.(check bool)
    "per-agent registered as counter"
    true
    (match metric with
     | Some m -> m.metric_type = Masc.Otel_metric_store.Counter
     | None -> false)

let test_emits_both_counters () =
  let variant =
    Workspace_task.drift_variant_label
      Workspace_task_lifecycle.Claimed_to_done_skip
  in
  let agent = "kaboo-test-agent" in
  let before_variant = counter_for_variant ~variant ~force:false in
  let before_per_agent =
    counter_for_per_agent ~variant ~agent_name:agent ~force:false
  in
  record_fsm_drift_with_agent ~variant ~force:false ~agent_name:agent;
  Alcotest.(check (float 0.0001))
    "variant counter +1"
    (before_variant +. 1.0)
    (counter_for_variant ~variant ~force:false);
  Alcotest.(check (float 0.0001))
    "per-agent counter +1"
    (before_per_agent +. 1.0)
    (counter_for_per_agent ~variant ~agent_name:agent ~force:false)

let test_per_agent_isolation () =
  (* Different agents must land in different series. *)
  let variant =
    Workspace_task.drift_variant_label
      Workspace_task_lifecycle.Claimed_to_done_skip
  in
  let agent_a = "alpha-test-agent" in
  let agent_b = "beta-test-agent" in
  let before_a =
    counter_for_per_agent ~variant ~agent_name:agent_a ~force:false
  in
  record_fsm_drift_with_agent ~variant ~force:false ~agent_name:agent_b;
  Alcotest.(check (float 0.0001))
    "agent_a counter unchanged when agent_b drifts"
    before_a
    (counter_for_per_agent ~variant ~agent_name:agent_a ~force:false)

let test_force_label_isolation () =
  (* force=true and force=false land in different series within
     the same agent. *)
  let variant =
    Workspace_task.drift_variant_label
      Workspace_task_lifecycle.Claimed_to_done_skip
  in
  let agent = "force-isolation-agent" in
  let before_true =
    counter_for_per_agent ~variant ~agent_name:agent ~force:true
  in
  record_fsm_drift_with_agent ~variant ~force:false ~agent_name:agent;
  Alcotest.(check (float 0.0001))
    "force=true counter unchanged when force=false event lands"
    before_true
    (counter_for_per_agent ~variant ~agent_name:agent ~force:true)

let () =
  Alcotest.run "fsm_drift_per_agent_counter_9795" [
    "metric_name", [
      Alcotest.test_case "canonical name stable" `Quick test_metric_name_stable;
    ];
    "emit", [
      Alcotest.test_case "emits to both counters" `Quick
        test_emits_both_counters;
    ];
    "isolation", [
      Alcotest.test_case "per-agent label isolation" `Quick
        test_per_agent_isolation;
      Alcotest.test_case "force label isolation" `Quick
        test_force_label_isolation;
    ];
  ]
