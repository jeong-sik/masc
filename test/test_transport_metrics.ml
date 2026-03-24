(** Tests for Transport_metrics module.
    Verifies metric registration, updates, and JSON snapshot output. *)

open Alcotest

module TM = Masc_mcp.Transport_metrics
module Prometheus = Masc_mcp.Prometheus

(* ============================================================
   Initialization
   ============================================================ *)

let test_init () =
  TM.init ();
  let text = Prometheus.to_prometheus_text () in
  check bool "sse sessions metric registered" true
    (try
       let _ = Str.search_forward
         (Str.regexp_string "masc_sse_sessions_total") text 0 in
       true
     with Not_found -> false);
  check bool "grpc active streams metric registered" true
    (try
       let _ = Str.search_forward
         (Str.regexp_string "masc_grpc_active_streams_total") text 0 in
       true
     with Not_found -> false);
  check bool "agent heartbeat age metric registered" true
    (try
       let _ = Str.search_forward
         (Str.regexp_string "masc_agent_heartbeat_age_seconds") text 0 in
       true
     with Not_found -> false)

(* ============================================================
   SSE Metrics
   ============================================================ *)

let test_sse_sessions () =
  TM.init ();
  TM.set_sse_sessions ~kind:"observer" 10;
  TM.set_sse_sessions ~kind:"coordinator" 5;
  let obs = Prometheus.metric_value_or_zero "masc_sse_sessions_total"
    ~labels:[("kind", "observer")] () in
  let coord = Prometheus.metric_value_or_zero "masc_sse_sessions_total"
    ~labels:[("kind", "coordinator")] () in
  check (float 0.01) "observer sessions" 10.0 obs;
  check (float 0.01) "coordinator sessions" 5.0 coord

let test_broadcast_duration () =
  TM.init ();
  TM.observe_broadcast_duration 0.05;
  TM.observe_broadcast_duration 0.15;
  let sum = Prometheus.metric_value_or_zero
    "masc_sse_broadcast_duration_seconds" () in
  let count = Prometheus.metric_value_or_zero
    "masc_sse_broadcast_duration_seconds_count" () in
  check bool "broadcast sum > 0" true (sum > 0.0);
  check bool "broadcast count >= 2" true (count >= 2.0)

let test_broadcast_events_counter () =
  TM.init ();
  let before = Prometheus.metric_value_or_zero
    "masc_sse_broadcast_events_total" () in
  TM.observe_broadcast_duration 0.01;
  let after = Prometheus.metric_value_or_zero
    "masc_sse_broadcast_events_total" () in
  check bool "broadcast events incremented" true (after > before)

(* ============================================================
   gRPC Metrics
   ============================================================ *)

let test_grpc_active_streams () =
  TM.init ();
  TM.set_grpc_active_streams 3;
  let v = Prometheus.metric_value_or_zero
    "masc_grpc_active_streams_total" () in
  check (float 0.01) "grpc active streams" 3.0 v

let test_grpc_heartbeat_latency () =
  TM.init ();
  TM.observe_grpc_heartbeat_latency 0.002;
  TM.observe_grpc_heartbeat_latency 0.008;
  let sum = Prometheus.metric_value_or_zero
    "masc_grpc_heartbeat_latency_seconds" () in
  check bool "heartbeat latency sum > 0" true (sum > 0.0)

let test_grpc_subscribers () =
  TM.init ();
  TM.set_grpc_subscribers 7;
  let v = Prometheus.metric_value_or_zero
    "masc_grpc_subscribers_total" () in
  check (float 0.01) "grpc subscribers" 7.0 v

let test_grpc_events_delivered () =
  TM.init ();
  let before = Prometheus.metric_value_or_zero
    "masc_grpc_events_delivered_total" () in
  TM.inc_grpc_events_delivered ~delta:5 ();
  let after = Prometheus.metric_value_or_zero
    "masc_grpc_events_delivered_total" () in
  check (float 0.01) "grpc events delta" 5.0 (after -. before)

(* ============================================================
   Agent Health Metrics
   ============================================================ *)

let test_agent_heartbeat_age () =
  TM.init ();
  TM.set_agent_heartbeat_age ~agent_name:"dreamer" 42.5;
  let v = Prometheus.metric_value_or_zero
    "masc_agent_heartbeat_age_seconds"
    ~labels:[("agent_name", "dreamer")] () in
  check (float 0.01) "dreamer heartbeat age" 42.5 v

let test_agent_stale_counter () =
  TM.init ();
  let before = Prometheus.metric_value_or_zero
    "masc_agent_stale_total" () in
  TM.inc_agent_stale ();
  TM.inc_agent_stale ();
  let after = Prometheus.metric_value_or_zero
    "masc_agent_stale_total" () in
  check (float 0.01) "stale count increment" 2.0 (after -. before)

(* ============================================================
   Transport Health JSON
   ============================================================ *)

let test_transport_health_json () =
  TM.init ();
  TM.set_sse_sessions ~kind:"observer" 3;
  TM.set_grpc_active_streams 1;
  let json = TM.transport_health_json () in
  let s = Yojson.Safe.to_string json in
  check bool "contains sse section" true
    (try
       let _ = Str.search_forward (Str.regexp_string "\"sse\"") s 0 in true
     with Not_found -> false);
  check bool "contains grpc section" true
    (try
       let _ = Str.search_forward (Str.regexp_string "\"grpc\"") s 0 in true
     with Not_found -> false);
  check bool "contains agent_health section" true
    (try
       let _ = Str.search_forward (Str.regexp_string "\"agent_health\"") s 0 in true
     with Not_found -> false);
  check bool "contains generated_at" true
    (try
       let _ = Str.search_forward (Str.regexp_string "\"generated_at\"") s 0 in true
     with Not_found -> false)

(* ============================================================
   Test Runner
   ============================================================ *)

let () =
  run "Transport_metrics" [
    ("init", [
      test_case "registers all metric families" `Quick test_init;
    ]);
    ("sse", [
      test_case "set_sse_sessions by kind" `Quick test_sse_sessions;
      test_case "observe_broadcast_duration accumulates" `Quick test_broadcast_duration;
      test_case "broadcast events counter increments" `Quick test_broadcast_events_counter;
    ]);
    ("grpc", [
      test_case "set_grpc_active_streams" `Quick test_grpc_active_streams;
      test_case "observe_grpc_heartbeat_latency" `Quick test_grpc_heartbeat_latency;
      test_case "set_grpc_subscribers" `Quick test_grpc_subscribers;
      test_case "inc_grpc_events_delivered" `Quick test_grpc_events_delivered;
    ]);
    ("agent_health", [
      test_case "set_agent_heartbeat_age" `Quick test_agent_heartbeat_age;
      test_case "inc_agent_stale" `Quick test_agent_stale_counter;
    ]);
    ("json", [
      test_case "transport_health_json structure" `Quick test_transport_health_json;
    ]);
  ]
