(* test/test_fsm_drift_counter.ml

   #9795: pin the canonical Prometheus metric name + label
   shape for task FSM drift observability.  The single current
   [Coord_task_lifecycle.drift] variant ([Claimed_to_done_skip])
   was warn-only until this counter was added; now ratchet
   readiness (promoting the skip to a hard error) can be
   measured instead of scraped from logs.

   Layering: [masc_coord] (home of [Coord_task]) sits below
   [masc_mcp.Prometheus] in the library dep graph, so the emit
   runs through [Coord_hooks.fsm_drift_observer_fn] which
   [lib/coord.ml] wires to [Masc_mcp.Coord.record_fsm_drift].  This test
   exercises the wired pair — [record_fsm_drift] directly for
   counter mechanics, and [Coord_task.drift_variant_label]
   for the enum→label mapping that keeps Grafana rules
   aligned with the sealed [drift] variant. *)

let counter_for ~variant ~force =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Coord.fsm_drift_metric
    ~labels:[
      ("variant", variant);
      ("force", if force then "true" else "false");
    ]
    ()

let test_metric_name_stable () =
  Alcotest.(check string)
    "fsm drift canonical metric name"
    "masc_task_fsm_drift_total"
    Masc_mcp.Coord.fsm_drift_metric

(* Exhaustive enum → label mapping.  Adding a new
   [Coord_task_lifecycle.drift] variant forces the reviewer to
   update [drift_variant_label] (compile error on the pattern
   match) and this test (assertion failure) at the same time,
   which keeps the Grafana label vocabulary in sync with the
   sealed enum. *)
let test_variant_label_claimed_to_done_skip () =
  Alcotest.(check string)
    "claimed_to_done_skip → canonical label"
    "claimed_to_done_skip"
    (Coord_task.drift_variant_label Coord_task_lifecycle.Claimed_to_done_skip)

let test_record_increments_variant_and_force () =
  let variant =
    Coord_task.drift_variant_label Coord_task_lifecycle.Claimed_to_done_skip
  in
  let before_false = counter_for ~variant ~force:false in
  let before_true = counter_for ~variant ~force:true in
  Masc_mcp.Coord.record_fsm_drift ~variant ~force:false;
  Alcotest.(check (float 0.0001))
    "force=false +1"
    (before_false +. 1.0)
    (counter_for ~variant ~force:false);
  Alcotest.(check (float 0.0001))
    "force=true unchanged"
    before_true
    (counter_for ~variant ~force:true);
  Masc_mcp.Coord.record_fsm_drift ~variant ~force:true;
  Alcotest.(check (float 0.0001))
    "force=true +1"
    (before_true +. 1.0)
    (counter_for ~variant ~force:true)

let test_label_isolation () =
  (* Unknown variant label must not bleed into the known
     variant's count — validates the label-key split. *)
  let known =
    Coord_task.drift_variant_label Coord_task_lifecycle.Claimed_to_done_skip
  in
  let unknown = "unused_test_variant_9795" in
  let before_known = counter_for ~variant:known ~force:false in
  Masc_mcp.Coord.record_fsm_drift ~variant:unknown ~force:false;
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
