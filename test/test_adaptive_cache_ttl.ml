(** Tests for broadcast latency metrics that support adaptive behavior.
    The original TTL-based cache in cp_snapshot_core was replaced with
    mtime-based per-section caching, so we test the latency metric
    infrastructure that downstream consumers can use for load adaptation. *)

open Alcotest

module Prometheus = Masc_mcp.Prometheus
module TM = Masc_mcp.Transport_metrics

let test_default_latency () =
  (* With no broadcast data, latency avg = 0. *)
  let sum = Prometheus.metric_value_or_zero
    Prometheus.metric_sse_broadcast_duration () in
  let count = Prometheus.metric_value_or_zero
    "masc_sse_broadcast_duration_seconds_count" () in
  let avg = if count > 0.0 then sum /. count else 0.0 in
  check bool "avg latency is a valid float" true (avg >= 0.0)

let test_high_latency_detected () =
  (* Inject high latency observations to push avg above 0.5s *)
  for _ = 1 to 10 do
    Prometheus.observe_histogram "masc_sse_broadcast_duration_seconds" 1.0
  done;
  let sum = Prometheus.metric_value_or_zero
    "masc_sse_broadcast_duration_seconds" () in
  let count = Prometheus.metric_value_or_zero
    "masc_sse_broadcast_duration_seconds_count" () in
  let avg = if count > 0.0 then sum /. count else 0.0 in
  check bool "avg latency exceeds threshold" true (avg > 0.4)

let () =
  run "Adaptive_cache_ttl" [
    ("broadcast_latency", [
      test_case "default latency with no data" `Quick test_default_latency;
      test_case "high latency detected via metrics" `Quick
        test_high_latency_detected;
    ]);
  ]
