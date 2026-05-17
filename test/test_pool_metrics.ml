(** RFC-0107 Phase D.4 — Pool_metrics exporter regression test.

    Pinned-name + scrape-shape checks for the piaf connection pool
    Prometheus exporter.  Verifies:

    - Five metric name constants stay stable (Grafana dashboards pin
      these names).
    - [register ()] is idempotent and does not raise.
    - [current_snapshot ()] returns [None] before the pool is
      lazy-initialized (no HTTP traffic from the test).
    - [Prometheus.to_prometheus_text ()] emits all five metric
      families with the correct TYPE lines once the metrics are
      registered.
*)

open Alcotest
module PM = Masc_mcp.Pool_metrics

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
     [Prometheus.update_pool_metrics_gauges]. *)
  (match PM.current_snapshot () with
   | None -> ()
   | Some _ -> fail "pool snapshot should be None before first HTTP call")

let metric_lines_for name text =
  text
  |> String.split_on_char '\n'
  |> List.filter (fun line ->
       (* Look for "# TYPE <name> ..." or "<name>{...} <value>" /
          "<name> <value>" — both anchor on the same prefix. *)
       String.length line >= String.length name
       && (
         let prefix_match s =
           let plen = String.length s in
           String.length line >= plen
           && String.sub line 0 plen = s
         in
         prefix_match ("# TYPE " ^ name)
         || prefix_match (name ^ " ")
         || prefix_match (name ^ "{")))

let test_to_prometheus_text_contains_metric_families () =
  let text = Masc_mcp.Prometheus.to_prometheus_text () in
  List.iter
    (fun (_, name) ->
      let lines = metric_lines_for name text in
      check bool
        (Printf.sprintf "/metrics output contains %s" name)
        true
        (List.length lines > 0))
    metric_names

let test_inflight_is_gauge_type () =
  (* TYPE line discipline: idle/inflight should render as gauge,
     reuse/evict/create as counter.  Pin a representative for each
     bucket so render-time drift is caught. *)
  let text = Masc_mcp.Prometheus.to_prometheus_text () in
  let contains needle =
    let nlen = String.length needle in
    let len = String.length text in
    let rec scan i =
      if i + nlen > len then false
      else if String.sub text i nlen = needle then true
      else scan (i + 1)
    in
    scan 0
  in
  check bool "inflight_total is gauge" true
    (contains "# TYPE masc_pool_inflight_total gauge");
  check bool "reuse_total is counter" true
    (contains "# TYPE masc_pool_reuse_total counter");
  check bool "create_total is counter" true
    (contains "# TYPE masc_pool_create_total counter")

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
    "prometheus integration", [
      test_case "to_prometheus_text contains all 5 metric families" `Quick
        test_to_prometheus_text_contains_metric_families;
      test_case "metric TYPE lines match gauge/counter intent" `Quick
        test_inflight_is_gauge_type;
    ];
  ]
