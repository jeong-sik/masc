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

let find_metric name =
  Otel_metric_store.snapshot ()
  |> List.find_opt (fun (m : Otel_metric_store.metric) ->
    String.equal m.name name && m.labels = [])

let test_registry_contains_metric_families () =
  List.iter
    (fun (_, name) ->
      check bool
        (Printf.sprintf "registry contains %s" name)
        true
        (Option.is_some (find_metric name)))
    metric_names

let test_metric_types_match_intent () =
  let has_type name metric_type =
    match find_metric name with
    | Some m -> m.metric_type = metric_type
    | None -> false
  in
  check bool "inflight_total is gauge" true
    (has_type "masc_pool_inflight_total" Otel_metric_store.Gauge);
  check bool "reuse_total is counter" true
    (has_type "masc_pool_reuse_total" Otel_metric_store.Counter);
  check bool "create_total is counter" true
    (has_type "masc_pool_create_total" Otel_metric_store.Counter)

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
    "metric registry", [
      test_case "registry contains all 5 metric families" `Quick
        test_registry_contains_metric_families;
      test_case "metric types match gauge/counter intent" `Quick
        test_metric_types_match_intent;
    ];
  ]
