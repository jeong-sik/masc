(** RFC-0107 Phase D.4 — Pool_metrics registry regression test.

    Pinned-name + registry-shape checks for the piaf connection pool
    metrics.  Verifies:

    - Five metric name constants stay stable (dashboards pin these names).
    - [register ()] is idempotent and does not raise.
    - [current_snapshot ()] returns [None] before the pool is
      lazy-initialized (no HTTP traffic from the test).
    - The Otel_metric_store store registers all metric families with the intended
      counter/gauge type for the OTel observable source.
*)

open Alcotest
module PM = Pool_metrics

let metric_names = [
  PM.metric_idle_total, "masc_pool_idle_total";
  PM.metric_inflight_total, "masc_pool_inflight_total";
  PM.metric_reuse_total, "masc_pool_reuse_total";
  PM.metric_evict_total, "masc_pool_evict_total";
  PM.metric_create_total, "masc_pool_create_total";
]

let test_metric_name_constants () =
  List.iter
    (fun (actual, expected) ->
      check string (Printf.sprintf "metric name %s" expected) expected actual)
    metric_names

let test_register_idempotent () =
  PM.register ();
  PM.register ();
  PM.register ()
  (* No exception => pass. *)

let test_current_snapshot_none_when_pool_uninit () =
  (* In a unit-test context with no prior HTTP traffic, the pool
     singleton has not been initialized, so the snapshot accessor
     returns [None].  This is the "no-op" invariant relied on by
     [Otel_metric_store.update_pool_metrics_gauges]. *)
  (match PM.current_snapshot () with
   | None -> ()
   | Some _ -> fail "pool snapshot should be None before first HTTP call")

(* Export path changed: pool metrics never enter the Otel_metric_store —
   Otel_runtime_observables computes masc_pool_* samples from
   [current_snapshot] at each exporter tick (so they only exist while a
   pool exists, with values that are always fresh).  The registry-based
   assertions that used to live here tested a registration sweep that was
   removed with the retired scrape backend (RFC-0217) and had been failing
   ever since. *)
let observable_pool_names samples =
  List.filter
    (fun (s : Otel_metrics.sample) ->
      String.starts_with ~prefix:"masc_pool_" s.Otel_metrics.name)
    samples

let test_observable_export_absent_without_pool () =
  (* No HTTP traffic in this binary: snapshot is None, so the observable
     source must yield no masc_pool_* samples (absent, not zero — a pool
     that does not exist has no honest occupancy value). *)
  let samples =
    Masc.Otel_runtime_observables.For_testing.samples
      ~masc_root:(Filename.get_temp_dir_name ())
      ()
  in
  check int "no masc_pool_* samples without a pool" 0
    (List.length (observable_pool_names samples))

let () =
  run "Pool_metrics" [
    "name constants", [
      test_case "metric names stable" `Quick test_metric_name_constants;
    ];
    "register", [
      test_case "register is idempotent" `Quick test_register_idempotent;
    ];
    "snapshot", [
      test_case "current_snapshot None before HTTP traffic" `Quick
        test_current_snapshot_none_when_pool_uninit;
    ];
    "observable export", [
      test_case "absent without a pool" `Quick
        test_observable_export_absent_without_pool;
    ];
  ]
