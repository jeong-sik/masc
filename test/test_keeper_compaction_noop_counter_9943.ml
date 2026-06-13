(** #9943 facet 1: compaction-triggered-but-no-savings counter.

    Production audit (2026-04-24) found 956/972 = 98.4% of compaction
    snapshots had [compaction_before_tokens =
    compaction_after_tokens > 0] — the trigger fired but the strategy
    did not reduce the token budget.  [masc_keeper_compactions_total]
    counts trigger fires, not savings, so the noop rate was invisible
    on dashboards.

    [Keeper_unified_metrics.append_metrics_snapshot] now emits
    [masc_keeper_compaction_noop_total{keeper, trigger}] in addition
    to writing the JSONL row.  Full integration testing requires a
    keeper context + run_result + observation, which is heavier than
    a unit test should be — these tests pin the metric surface and
    label shape so a future refactor cannot silently flip the
    cardinality or rename the labels. *)

open Masc

let () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-keeper-compaction-noop-9943-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir
;;

module Prom = Masc.Otel_metric_store

let noop_for ~keeper ~trigger =
  Prom.metric_value_or_zero
    Keeper_metrics.(to_string CompactionNoop)
    ~labels:[ "keeper", keeper; "trigger", trigger ]
    ()
;;

(* Metric is registered at module init via [Otel_metric_store.add ~labels:[]],
   so [get_metric_value ~labels:[] ()] returns [Some 0.0] iff the
   registration ran. If a future refactor accidentally drops the
   [add metric_keeper_compaction_noop ...] call, this returns [None]
   and the dashboard silently flattens — pin the registration.

   [metric_total] is unsuitable as a check: it folds across all
   labelled variants and returns [0.0] for both "not registered" and
   "registered but no observations yet". *)
let test_metric_registered () =
  let registered =
    Prom.get_metric_value Keeper_metrics.(to_string CompactionNoop) ()
  in
  Alcotest.(check bool) "metric registered at init" true (Option.is_some registered)
;;

(* Direct increment using the same call shape
   [append_metrics_snapshot] uses.  Verifies the counter advances
   with the labels in the documented order. *)
let test_counter_advances_for_noop_pattern () =
  let keeper = "test-keeper-compaction-noop-9943" in
  let trigger = "context_overflow_imminent" in
  let before = noop_for ~keeper ~trigger in
  Prom.inc_counter
    Keeper_metrics.(to_string CompactionNoop)
    ~labels:[ "keeper", keeper; "trigger", trigger ]
    ();
  Alcotest.(check (float 0.0001))
    "noop counter +1 with correct labels"
    (before +. 1.0)
    (noop_for ~keeper ~trigger)
;;

(* Different triggers land on different counter rows so dashboards
   can attribute noops to the source trigger.  Pre-fix the only
   signal was [compactions_total] aggregated across all triggers. *)
let test_distinct_triggers_separate_rows () =
  let keeper = "test-keeper-compaction-noop-9943-trigger" in
  let before_overflow = noop_for ~keeper ~trigger:"context_overflow_imminent" in
  let before_proactive = noop_for ~keeper ~trigger:"proactive_warmup" in
  Prom.inc_counter
    Keeper_metrics.(to_string CompactionNoop)
    ~labels:[ "keeper", keeper; "trigger", "context_overflow_imminent" ]
    ();
  Prom.inc_counter
    Keeper_metrics.(to_string CompactionNoop)
    ~labels:[ "keeper", keeper; "trigger", "proactive_warmup" ]
    ();
  Alcotest.(check (float 0.0001))
    "overflow row +1"
    (before_overflow +. 1.0)
    (noop_for ~keeper ~trigger:"context_overflow_imminent");
  Alcotest.(check (float 0.0001))
    "proactive row +1"
    (before_proactive +. 1.0)
    (noop_for ~keeper ~trigger:"proactive_warmup")
;;

(* Per-keeper isolation — keeper A's noops do not leak into
   keeper B's row.  Necessary because a fleet has 9-15 keepers
   each with their own noop rate; aggregating obscures which
   keeper is suffering. *)
let test_per_keeper_isolation () =
  let a = "test-keeper-compaction-noop-9943-iso-A" in
  let b = "test-keeper-compaction-noop-9943-iso-B" in
  let trigger = "context_overflow_imminent" in
  let before_b = noop_for ~keeper:b ~trigger in
  Prom.inc_counter
    Keeper_metrics.(to_string CompactionNoop)
    ~labels:[ "keeper", a; "trigger", trigger ]
    ();
  Prom.inc_counter
    Keeper_metrics.(to_string CompactionNoop)
    ~labels:[ "keeper", a; "trigger", trigger ]
    ();
  Alcotest.(check (float 0.0001))
    "keeper B unaffected by keeper A increments"
    before_b
    (noop_for ~keeper:b ~trigger)
;;

(* The in-process registry must preserve the metric name and
   keeper / trigger label keys; the OTel exporter reads this snapshot. *)
let test_registry_snapshot_includes_label_shape () =
  let keeper = "test-keeper-compaction-noop-9943-export" in
  let trigger = "context_overflow_imminent" in
  let metric = Keeper_metrics.(to_string CompactionNoop) in
  Prom.inc_counter
    metric
    ~labels:[ "keeper", keeper; "trigger", trigger ]
    ();
  let has_metric =
    Prom.snapshot ()
    |> List.exists (fun (m : Prom.metric) ->
      String.equal m.name metric
      && List.mem ("keeper", keeper) m.labels
      && List.mem ("trigger", trigger) m.labels)
  in
  Alcotest.(check bool) "metric label shape in registry" true has_metric
;;

let () =
  Alcotest.run
    "keeper_compaction_noop_counter_9943"
    [ ( "registration"
      , [ Alcotest.test_case "metric registered at init" `Quick test_metric_registered ] )
    ; ( "label-shape"
      , [ Alcotest.test_case
            "counter advances with (keeper, trigger)"
            `Quick
            test_counter_advances_for_noop_pattern
        ; Alcotest.test_case
            "distinct triggers → distinct rows"
            `Quick
            test_distinct_triggers_separate_rows
        ; Alcotest.test_case "per-keeper isolation" `Quick test_per_keeper_isolation
        ] )
    ; ( "registry"
      , [ Alcotest.test_case
            "metric + labels appear in registry"
            `Quick
            test_registry_snapshot_includes_label_shape
        ] )
    ]
;;
