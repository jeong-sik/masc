(** Tests for Transport_metrics module.
    Verifies metric registration, updates, and JSON snapshot output. *)

open Alcotest

module TM = Masc_mcp.Transport_metrics
module Prometheus = Masc_mcp.Prometheus
module U = Yojson.Safe.Util

let temp_dir () =
  let dir = Filename.temp_file "test_transport_metrics_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      (match value_opt with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "");
      f ())

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

let test_grpc_runtime_listening_cache () =
  TM.init ();
  TM.set_grpc_runtime_listening true;
  check bool "grpc listening uses runtime cache" true (TM.grpc_listening ());
  TM.set_grpc_runtime_listening false;
  check bool "grpc listening resets" false (TM.grpc_listening ())

let test_ws_sessions () =
  TM.init ();
  TM.set_ws_sessions 4;
  let v = Prometheus.metric_value_or_zero
    "masc_ws_sessions_total" () in
  check (float 0.01) "ws sessions" 4.0 v

let test_ws_enabled_blank_env_matches_runtime () =
  with_env "MASC_WS_ENABLED" (Some "") (fun () ->
    check bool "transport metrics treats blank as enabled" true
      (TM.ws_enabled ());
    check bool "runtime server treats blank as enabled" true
      (Masc_mcp.Server_ws_standalone.is_enabled ()))

let test_ws_enabled_normalized_env_matches_runtime () =
  with_env "MASC_WS_ENABLED" (Some " FALSE ") (fun () ->
    check bool "transport metrics normalizes false env" false
      (TM.ws_enabled ());
    check bool "runtime server normalizes false env" false
      (Masc_mcp.Server_ws_standalone.is_enabled ()))

let test_ws_runtime_listening_cache () =
  TM.init ();
  TM.set_ws_runtime_listening true;
  check bool "ws listening uses runtime cache" true (TM.ws_listening ());
  TM.set_ws_runtime_listening false;
  check bool "ws listening resets" false (TM.ws_listening ())

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
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  TM.init ();
  ignore (Masc_mcp.Sse.close_all_clients ());
  let base_dir = temp_dir () in
  let config = Masc_mcp.Coord.default_config base_dir in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "tester"));
  ignore
    (Masc_mcp.Sse.register ~kind:Masc_mcp.Sse.Observer "observer-session"
       ~push:(fun _ -> ()) ~last_event_id:0);
  ignore
    (Masc_mcp.Sse.register ~kind:Masc_mcp.Sse.Coordinator "coordinator-session"
       ~push:(fun _ -> ()) ~last_event_id:0);
  TM.set_grpc_active_streams 1;
  TM.set_grpc_subscribers 2;
  Prometheus.set_gauge Prometheus.metric_oas_sse_relay_queue_depth 4.0;
  Prometheus.inc_counter Prometheus.metric_oas_sse_relay_retries
    ~labels:[ ("stage", "append") ] ~delta:2.0 ();
  Prometheus.inc_counter Prometheus.metric_oas_sse_relay_retries
    ~labels:[ ("stage", "broadcast") ] ~delta:1.0 ();
  Prometheus.inc_counter Prometheus.metric_oas_sse_relay_drops
    ~labels:[ ("stage", "queue") ] ~delta:3.0 ();
  Prometheus.inc_counter Prometheus.metric_oas_sse_relay_drops
    ~labels:[ ("stage", "append") ] ~delta:1.0 ();
  Prometheus.inc_counter Prometheus.metric_keeper_lifecycle_dispatch_rejections
    ~labels:[ ("event", "compaction_started") ] ~delta:2.0 ();
  Masc_mcp.Sse.broadcast (`Assoc [ ("type", `String "transport-test") ]);
  let json = TM.transport_health_json ~config in
  let sse_json = json |> U.member "sse" in
  let grpc_json = json |> U.member "grpc" in
  let ws_json = json |> U.member "websocket" in
  let webrtc_json = json |> U.member "webrtc" in
  let cluster_json = json |> U.member "cluster" in
  let summary_json = json |> U.member "summary" in
  let agent_health_json = json |> U.member "agent_health" in
  check int "observer sessions" 1
    (sse_json |> U.member "sessions_observer" |> U.to_int);
  check int "coordinator sessions" 1
    (sse_json |> U.member "sessions_coordinator" |> U.to_int);
  check bool "queue depth reflects queued event" true
    ((sse_json |> U.member "queue_max_depth" |> U.to_int) > 0);
  check bool "hot sessions are reported" true
    ((sse_json |> U.member "hot_sessions" |> U.to_list |> List.length) > 0);
  check int "relay queue depth" 4
    (sse_json |> U.member "relay_queue_depth" |> U.to_int);
  check int "relay retries total" 3
    (sse_json |> U.member "relay_retry_total" |> U.to_int);
  check int "relay drops total" 4
    (sse_json |> U.member "relay_drop_total" |> U.to_int);
  check int "grpc active streams" 1
    (grpc_json |> U.member "active_streams" |> U.to_int);
  check int "grpc subscribers" 2
    (grpc_json |> U.member "subscribers" |> U.to_int);
  check bool "grpc listening field exists" true
    (match grpc_json |> U.member "listening" with `Bool _ -> true | _ -> false);
  check bool "grpc listen_status field exists" true
    (match grpc_json |> U.member "listen_status" with `String _ -> true | _ -> false);
  check bool "websocket listening field exists" true
    (match ws_json |> U.member "listening" with `Bool _ -> true | _ -> false);
  check bool "ws listen_status field exists" true
    (match ws_json |> U.member "listen_status" with `String _ -> true | _ -> false);
  check bool "websocket section exists" true
    (match ws_json with `Assoc _ -> true | _ -> false);
  check bool "webrtc section exists" true
    (match webrtc_json with `Assoc _ -> true | _ -> false);
  check bool "webrtc configured field exists" true
    (match webrtc_json |> U.member "configured" with `Bool _ -> true | _ -> false);
  check bool "webrtc signaling_available field exists" true
    (match webrtc_json |> U.member "signaling_available" with `Bool _ -> true | _ -> false);
  check bool "webrtc signaling_mode field exists" true
    (match webrtc_json |> U.member "signaling_mode" with `String _ -> true | _ -> false);
  check string "room id" "default"
    (cluster_json |> U.member "room_id" |> U.to_string);
  check bool "summary primary path exists" true
    (String.length (summary_json |> U.member "primary_path" |> U.to_string) > 0);
  check string "summary queue pressure reflects relay drops" "high"
    (summary_json |> U.member "queue_pressure" |> U.to_string);
  check int "agent lifecycle dispatch rejections surfaced" 2
    (agent_health_json
     |> U.member "lifecycle_dispatch_rejections_total"
     |> U.to_int);
  ignore (Masc_mcp.Sse.close_all_clients ());
  cleanup_dir base_dir

(* ============================================================
   Listen Status (#3408)
   ============================================================ *)

let test_grpc_listen_status_lifecycle () =
  TM.init ();
  check string "grpc status after init" "not_started"
    (Atomic.get TM.grpc_listen_status);
  TM.set_grpc_listen_status "listening";
  TM.set_grpc_runtime_listening true;
  check string "grpc status after listening" "listening"
    (Atomic.get TM.grpc_listen_status);
  check bool "grpc listening returns true" true (TM.grpc_listening ());
  TM.set_grpc_listen_status "stopped";
  TM.set_grpc_runtime_listening false;
  check string "grpc status after stopped" "stopped"
    (Atomic.get TM.grpc_listen_status);
  check bool "grpc listening returns false" false (TM.grpc_listening ())

let test_ws_listen_status_lifecycle () =
  TM.init ();
  check string "ws status after init" "not_started"
    (Atomic.get TM.ws_listen_status);
  TM.set_ws_listen_status "listening";
  TM.set_ws_runtime_listening true;
  check string "ws status after listening" "listening"
    (Atomic.get TM.ws_listen_status);
  check bool "ws listening returns true" true (TM.ws_listening ());
  TM.set_ws_listen_status "stopped";
  TM.set_ws_runtime_listening false;
  check string "ws status after stopped" "stopped"
    (Atomic.get TM.ws_listen_status);
  check bool "ws listening returns false" false (TM.ws_listening ())

let test_listen_status_bind_failed () =
  TM.init ();
  TM.set_grpc_listen_status "bind_failed";
  TM.set_grpc_runtime_listening false;
  TM.set_ws_listen_status "bind_failed";
  TM.set_ws_runtime_listening false;
  check bool "grpc not listening on bind_failed" false (TM.grpc_listening ());
  check bool "ws not listening on bind_failed" false (TM.ws_listening ());
  check string "grpc status is bind_failed" "bind_failed"
    (Atomic.get TM.grpc_listen_status);
  check string "ws status is bind_failed" "bind_failed"
    (Atomic.get TM.ws_listen_status)

let test_listen_status_disabled () =
  TM.init ();
  TM.set_grpc_listen_status "disabled";
  TM.set_ws_listen_status "disabled";
  check string "grpc status disabled" "disabled"
    (Atomic.get TM.grpc_listen_status);
  check string "ws status disabled" "disabled"
    (Atomic.get TM.ws_listen_status)

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
      test_case "runtime listening cache" `Quick test_grpc_runtime_listening_cache;
    ]);
    ("websocket", [
      test_case "set_ws_sessions" `Quick test_ws_sessions;
      test_case "blank env stays enabled" `Quick
        test_ws_enabled_blank_env_matches_runtime;
      test_case "normalized env matches runtime" `Quick
        test_ws_enabled_normalized_env_matches_runtime;
      test_case "runtime listening cache" `Quick
        test_ws_runtime_listening_cache;
    ]);
    ("agent_health", [
      test_case "set_agent_heartbeat_age" `Quick test_agent_heartbeat_age;
      test_case "inc_agent_stale" `Quick test_agent_stale_counter;
    ]);
    ("json", [
      test_case "transport_health_json structure" `Quick test_transport_health_json;
    ]);
    ("listen_status", [
      test_case "grpc listen_status lifecycle" `Quick
        test_grpc_listen_status_lifecycle;
      test_case "ws listen_status lifecycle" `Quick
        test_ws_listen_status_lifecycle;
      test_case "listen_status bind_failed" `Quick
        test_listen_status_bind_failed;
      test_case "listen_status disabled" `Quick
        test_listen_status_disabled;
    ]);
  ]
