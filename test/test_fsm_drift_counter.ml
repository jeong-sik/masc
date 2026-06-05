(* test/test_fsm_drift_counter.ml

   #9795: pin the canonical Otel_metric_store metric name + label
   shape for task FSM drift observability.  The single current
   [Workspace_task_lifecycle.drift] variant ([Claimed_to_done_skip])
   was warn-only until this counter was added; now ratchet
   readiness (promoting the skip to a hard error) can be
   measured instead of scraped from logs.

   Layering: [masc_workspace] (home of [Workspace_task]) sits below
   [masc.Otel_metric_store] in the library dep graph, so the emit
   runs through [Workspace_hooks.fsm_drift_observer_fn] which
   [Workspace_metric_hooks.install] wires to the Otel_metric_store adapter. This test
   exercises the wired observer directly for
   counter mechanics, and [Workspace_task.drift_variant_label]
   for the enum→label mapping that keeps Grafana rules
   aligned with the sealed [drift] variant. *)

let () = Masc.Workspace_metric_hooks.install ()

let fsm_drift_metric = "masc_task_fsm_drift_total"

let record_fsm_drift ~variant ~force =
  (Atomic.get Workspace_hooks.fsm_drift_observer_fn)
    ~variant ~force ~agent_name:"fsm-drift-counter-test"
;;

let counter_for ~variant ~force =
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
      String.equal m.name fsm_drift_metric && m.labels = [])
  in
  Alcotest.(check bool)
    "fsm drift registered as counter"
    true
    (match metric with
     | Some m -> m.metric_type = Masc.Otel_metric_store.Counter
     | None -> false)

(* Exhaustive enum → label mapping.  Adding a new
   [Workspace_task_lifecycle.drift] variant forces the reviewer to
   update [drift_variant_label] (compile error on the pattern
   match) and this test (assertion failure) at the same time,
   which keeps the Grafana label vocabulary in sync with the
   sealed enum. *)
let test_variant_label_claimed_to_done_skip () =
  Alcotest.(check string)
    "claimed_to_done_skip → canonical label"
    "claimed_to_done_skip"
    (Workspace_task.drift_variant_label Workspace_task_lifecycle.Claimed_to_done_skip)

let test_record_increments_variant_and_force () =
  let variant =
    Workspace_task.drift_variant_label Workspace_task_lifecycle.Claimed_to_done_skip
  in
  let before_false = counter_for ~variant ~force:false in
  let before_true = counter_for ~variant ~force:true in
  record_fsm_drift ~variant ~force:false;
  Alcotest.(check (float 0.0001))
    "force=false +1"
    (before_false +. 1.0)
    (counter_for ~variant ~force:false);
  Alcotest.(check (float 0.0001))
    "force=true unchanged"
    before_true
    (counter_for ~variant ~force:true);
  record_fsm_drift ~variant ~force:true;
  Alcotest.(check (float 0.0001))
    "force=true +1"
    (before_true +. 1.0)
    (counter_for ~variant ~force:true)

let test_label_isolation () =
  (* Unknown variant label must not bleed into the known
     variant's count — validates the label-key split. *)
  let known =
    Workspace_task.drift_variant_label Workspace_task_lifecycle.Claimed_to_done_skip
  in
  let unknown = "unused_test_variant_9795" in
  let before_known = counter_for ~variant:known ~force:false in
  record_fsm_drift ~variant:unknown ~force:false;
  Alcotest.(check (float 0.0001))
    "known variant counter unchanged"
    before_known
    (counter_for ~variant:known ~force:false)

let () =
  Alcotest.run "fsm_drift_counter_9795"
    [
      ( "metric_name",
        [
          Alcotest.test_case "canonical name stable" `Quick
            test_metric_name_stable;
        ] );
      ( "variant_label",
        [
          Alcotest.test_case "claimed_to_done_skip" `Quick
            test_variant_label_claimed_to_done_skip;
        ] );
      ( "counter",
        [
          Alcotest.test_case "increments with variant + force" `Quick
            test_record_increments_variant_and_force;
          Alcotest.test_case "label isolation" `Quick
            test_label_isolation;
        ] );
    ]
