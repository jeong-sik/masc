(** Tests for Transport_metrics module.
    Verifies metric registration, updates, and JSON snapshot output. *)

open Alcotest

module TM = Masc.Transport_metrics
module Otel_metric_store = Masc.Otel_metric_store
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

let check_assoc_keys label expected = function
  | `Assoc fields ->
    check
      (list string)
      label
      (List.sort String.compare expected)
      (fields |> List.map fst |> List.sort String.compare)
  | _ -> fail (label ^ ": expected object")

(* ============================================================
   Initialization
   ============================================================ *)

let test_init () =
  let has_metric name =
    Otel_metric_store.snapshot ()
    |> List.exists (fun (m : Otel_metric_store.metric) -> String.equal m.name name)
  in
  (* Counters zero-fill at module init; gauges and histograms appear on first
     set or observation. *)
  check bool "http accept counter zero-filled" true
    (has_metric "masc_http_accepts_total");
  let rate_limit_cells =
    Otel_metric_store.snapshot ()
    |> List.filter (fun (m : Otel_metric_store.metric) ->
      String.equal m.name "masc_http_rate_limit_responses_total")
  in
  check int "typed HTTP rate-limit cells zero-filled" 6
    (List.length rate_limit_cells);
  TM.set_grpc_active_streams 0;
  check bool "grpc active streams gauge appears once set" true
    (has_metric "masc_grpc_active_streams_total");
  TM.observe_ws_dashboard_hello_latency ~success:true 0.0;
  check bool "ws hello latency appears once observed" true
    (has_metric "masc_ws_dashboard_hello_latency_seconds")

(* ============================================================
   SSE Metrics
   ============================================================ *)

let test_sse_sessions () =
  TM.set_sse_sessions ~kind:TM.Observer 10;
  TM.set_sse_sessions ~kind:TM.Agent_stream 5;
  let obs = Otel_metric_store.metric_value_or_zero "masc_sse_sessions_total"
    ~labels:[("kind", "observer")] () in
  let workspace = Otel_metric_store.metric_value_or_zero "masc_sse_sessions_total"
    ~labels:[("kind", "agent_stream")] () in
  check (float 0.01) "observer sessions" 10.0 obs;
  check (float 0.01) "agent_stream sessions" 5.0 workspace

let test_broadcast_duration () =
  TM.observe_broadcast_duration 0.05;
  TM.observe_broadcast_duration 0.15;
  let sum = Otel_metric_store.metric_value_or_zero
    "masc_sse_broadcast_duration_seconds" () in
  let count = Otel_metric_store.metric_value_or_zero
    "masc_sse_broadcast_duration_seconds_count" () in
  check bool "broadcast sum > 0" true (sum > 0.0);
  check bool "broadcast count >= 2" true (count >= 2.0)

let test_broadcast_events_counter () =
  let before = Otel_metric_store.metric_value_or_zero
    "masc_sse_broadcast_events_total" () in
  TM.observe_broadcast_duration 0.01;
  let after = Otel_metric_store.metric_value_or_zero
    "masc_sse_broadcast_events_total" () in
  check bool "broadcast events incremented" true (after > before)

let test_sse_idle_evicted () =
  let before = Otel_metric_store.metric_value_or_zero
    "masc_sse_idle_evictions_total" () in
  TM.inc_sse_idle_evicted ();
  TM.inc_sse_idle_evicted ();
  let after = Otel_metric_store.metric_value_or_zero
    "masc_sse_idle_evictions_total" () in
  check (float 0.01) "idle evicted delta" 2.0 (after -. before)

let test_sse_reject_labelled () =
  let before_cooldown = Otel_metric_store.metric_value_or_zero
    "masc_sse_rejects_total" ~labels:[("reason", "session_cooldown")] () in
  let before_window = Otel_metric_store.metric_value_or_zero
    "masc_sse_rejects_total" ~labels:[("reason", "window_limit")] () in
  TM.inc_sse_reject ~reason:"session_cooldown";
  TM.inc_sse_reject ~reason:"window_limit";
  TM.inc_sse_reject ~reason:"session_cooldown";
  let after_cooldown = Otel_metric_store.metric_value_or_zero
    "masc_sse_rejects_total" ~labels:[("reason", "session_cooldown")] () in
  let after_window = Otel_metric_store.metric_value_or_zero
    "masc_sse_rejects_total" ~labels:[("reason", "window_limit")] () in
  check (float 0.01) "session_cooldown delta" 2.0 (after_cooldown -. before_cooldown);
  check (float 0.01) "window_limit delta" 1.0 (after_window -. before_window)

let test_sse_reconnect () =
  let before = Otel_metric_store.metric_value_or_zero
    "masc_sse_reconnects_total" () in
  TM.inc_sse_reconnect ();
  let after = Otel_metric_store.metric_value_or_zero
    "masc_sse_reconnects_total" () in
  check (float 0.01) "reconnect delta" 1.0 (after -. before)

(* ============================================================
   gRPC Metrics
   ============================================================ *)

let test_grpc_active_streams () =
  TM.set_grpc_active_streams 3;
  let v = Otel_metric_store.metric_value_or_zero
    "masc_grpc_active_streams_total" () in
  check (float 0.01) "grpc active streams" 3.0 v

let test_grpc_heartbeat_latency () =
  TM.observe_grpc_heartbeat_latency 0.002;
  TM.observe_grpc_heartbeat_latency 0.008;
  let sum = Otel_metric_store.metric_value_or_zero
    "masc_grpc_heartbeat_latency_seconds" () in
  check bool "heartbeat latency sum > 0" true (sum > 0.0)

let test_grpc_subscribers () =
  TM.set_grpc_subscribers 7;
  let v = Otel_metric_store.metric_value_or_zero
    "masc_grpc_subscribers_total" () in
  check (float 0.01) "grpc subscribers" 7.0 v

let test_grpc_events_delivered () =
  let before = Otel_metric_store.metric_value_or_zero
    "masc_grpc_events_delivered_total" () in
  TM.inc_grpc_events_delivered ~delta:5 ();
  let after = Otel_metric_store.metric_value_or_zero
    "masc_grpc_events_delivered_total" () in
  check (float 0.01) "grpc events delta" 5.0 (after -. before)

let test_grpc_events_dropped () =
  let before = Otel_metric_store.metric_value_or_zero
    "masc_grpc_events_dropped_total" () in
  TM.inc_grpc_events_dropped ();
  TM.inc_grpc_events_dropped ();
  TM.inc_grpc_events_dropped ();
  let after = Otel_metric_store.metric_value_or_zero
    "masc_grpc_events_dropped_total" () in
  check (float 0.01) "three drop observations advance counter by 3"
    3.0 (after -. before)

let test_grpc_runtime_listening_cache () =
  (* [grpc_listening] is [grpc_enabled () && runtime_listening], and the flag
     is off by default, so the runtime half only shows with the config half
     named. The test used to rely on the default being on, which made it a
     test of two things while reading as a test of one. *)
  let previous = Sys.getenv_opt "MASC_GRPC_ENABLED" in
  Unix.putenv "MASC_GRPC_ENABLED" "1";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_GRPC_ENABLED" (Option.value previous ~default:"0"))
    (fun () ->
      TM.set_grpc_runtime_listening true;
      check bool "grpc listening uses runtime cache" true (TM.grpc_listening ());
      TM.set_grpc_runtime_listening false;
      check bool "grpc listening resets" false (TM.grpc_listening ()));
  (* And the config half alone is not enough either. *)
  TM.set_grpc_runtime_listening true;
  check bool "a disabled flag keeps it not listening" false (TM.grpc_listening ());
  TM.set_grpc_runtime_listening false

let test_ws_sessions () =
  TM.set_ws_sessions 4;
  let v = Otel_metric_store.metric_value_or_zero
    "masc_ws_sessions_total" () in
  check (float 0.01) "ws sessions" 4.0 v

let test_ws_dashboard_hello_latency () =
  let metric = Otel_metric_store.metric_ws_dashboard_hello_latency_seconds in
  let success_labels = [ ("outcome", "success") ] in
  let error_labels = [ ("outcome", "error") ] in
  let success_before = Otel_metric_store.metric_value_or_zero metric ~labels:success_labels () in
  let success_count_before =
    Otel_metric_store.metric_value_or_zero (metric ^ "_count") ~labels:success_labels ()
  in
  let error_before = Otel_metric_store.metric_value_or_zero metric ~labels:error_labels () in
  let error_count_before =
    Otel_metric_store.metric_value_or_zero (metric ^ "_count") ~labels:error_labels ()
  in
  TM.observe_ws_dashboard_hello_latency ~success:true 0.25;
  TM.observe_ws_dashboard_hello_latency ~success:false (-1.0);
  let success_after = Otel_metric_store.metric_value_or_zero metric ~labels:success_labels () in
  let success_count_after =
    Otel_metric_store.metric_value_or_zero (metric ^ "_count") ~labels:success_labels ()
  in
  let error_after = Otel_metric_store.metric_value_or_zero metric ~labels:error_labels () in
  let error_count_after =
    Otel_metric_store.metric_value_or_zero (metric ^ "_count") ~labels:error_labels ()
  in
  check (float 0.001) "success latency sum delta" 0.25 (success_after -. success_before);
  check
    (float 0.001)
    "success latency count delta"
    1.0
    (success_count_after -. success_count_before);
  check (float 0.001) "negative error latency clamped" 0.0 (error_after -. error_before);
  check
    (float 0.001)
    "error latency count delta"
    1.0
    (error_count_after -. error_count_before)

let test_ws_enabled_blank_env_matches_runtime () =
  with_env "MASC_WS_ENABLED" (Some "") (fun () ->
    check bool "transport metrics treats blank as enabled" true
      (TM.ws_enabled ()))

let test_ws_enabled_normalized_env_matches_runtime () =
  with_env "MASC_WS_ENABLED" (Some " FALSE ") (fun () ->
    check bool "transport metrics normalizes false env" false
      (TM.ws_enabled ()))

let test_http_listener_state_json () =
  let accepts_before =
    Otel_metric_store.metric_total Otel_metric_store.metric_http_accepts
  in
  let errors_before =
    Otel_metric_store.metric_total Otel_metric_store.metric_http_accept_errors
  in
  TM.record_http_listener_started ~mode:"auto";
  TM.record_http_accept ~mode:"auto";
  let accepted = TM.http_listener_json () in
  check_assoc_keys
    "http listener exact keys"
    [ "mode"
    ; "status"
    ; "active_connections"
    ; "accepted_total"
    ; "accept_errors_total"
    ; "rate_limit_responses_total"
    ; "rate_limit_responses"
    ; "last_accept_unix"
    ; "last_accept_age_seconds"
    ; "last_error"
    ]
    accepted;
  check string "http listener mode" "auto"
    (accepted |> U.member "mode" |> U.to_string);
  check string "http listener listening" "listening"
    (accepted |> U.member "status" |> U.to_string);
  check int "http listener active connection" 1
    (accepted |> U.member "active_connections" |> U.to_int);
  check bool "http listener accepted total advanced" true
    (float_of_int (accepted |> U.member "accepted_total" |> U.to_int)
     >= accepts_before +. 1.0);
  check bool "last accept age present" true
    (match accepted |> U.member "last_accept_age_seconds" with
    | `Float _ | `Int _ -> true
    | _ -> false);
  TM.record_http_accept_error ~mode:"auto" ~error:"accept failed";
  let errored = TM.http_listener_json () in
  check string "http listener accept error status" "accept_error"
    (errored |> U.member "status" |> U.to_string);
  check string "http listener last error" "accept failed"
    (errored |> U.member "last_error" |> U.to_string);
  check bool "http listener accept error total advanced" true
    (float_of_int (errored |> U.member "accept_errors_total" |> U.to_int)
     >= errors_before +. 1.0);
  TM.record_http_connection_closed ~mode:"auto";
  TM.record_http_listener_stopped ~mode:"auto";
  let stopped = TM.http_listener_json () in
  check string "http listener stopped" "stopped"
    (stopped |> U.member "status" |> U.to_string);
  check int "http listener active connection released" 0
    (stopped |> U.member "active_connections" |> U.to_int)

let http_rate_limit_value ~protocol ~scope =
  Otel_metric_store.metric_value_or_zero
    Otel_metric_store.metric_http_rate_limit_responses
    ~labels:[ "protocol", protocol; "scope", scope ]
    ()

let test_http_rate_limit_response_counter () =
  let h1_ip_before = http_rate_limit_value ~protocol:"h1" ~scope:"client_ip" in
  let h2_agent_before = http_rate_limit_value ~protocol:"h2" ~scope:"agent" in
  let total_before =
    Otel_metric_store.metric_total
      Otel_metric_store.metric_http_rate_limit_responses
  in
  TM.record_http_rate_limit_response
    ~acceptance:TM.Rejected_by_writer
    ~protocol:TM.H1
    ~scope:TM.Client_ip;
  check (float 0.01) "a rejected writer does not count a response" 0.0
    (http_rate_limit_value ~protocol:"h1" ~scope:"client_ip"
     -. h1_ip_before);
  TM.record_http_rate_limit_response
    ~acceptance:TM.Accepted_by_writer
    ~protocol:TM.H1
    ~scope:TM.Client_ip;
  TM.record_http_rate_limit_response
    ~acceptance:TM.Accepted_by_writer
    ~protocol:TM.H1
    ~scope:TM.Client_ip;
  TM.record_http_rate_limit_response
    ~acceptance:TM.Accepted_by_writer
    ~protocol:TM.H2
    ~scope:TM.Agent;
  check (float 0.01) "H1 client-IP responses only increase" 2.0
    (http_rate_limit_value ~protocol:"h1" ~scope:"client_ip"
     -. h1_ip_before);
  check (float 0.01) "H2 agent responses only increase" 1.0
    (http_rate_limit_value ~protocol:"h2" ~scope:"agent"
     -. h2_agent_before);
  let listener = TM.http_listener_json ~now:0.0 () in
  let projected_total =
    listener |> U.member "rate_limit_responses_total" |> U.to_int
  in
  check int "listener total advances monotonically" 3
    (projected_total - int_of_float total_before);
  let rows =
    listener |> U.member "rate_limit_responses" |> U.to_list
  in
  check int "closed protocol/scope matrix" 6 (List.length rows);
  List.iter
    (check_assoc_keys "rate-limit response row"
       [ "protocol"; "scope"; "total" ])
    rows;
  let labels =
    rows
    |> List.map (fun row ->
      row |> U.member "protocol" |> U.to_string,
      row |> U.member "scope" |> U.to_string)
    |> List.sort compare
  in
  check
    (list (pair string string))
    "closed protocol/scope labels"
    [ "h1", "agent"
    ; "h1", "client_ip"
    ; "h1", "sse_connection"
    ; "h2", "agent"
    ; "h2", "client_ip"
    ; "h2", "sse_connection"
    ]
    labels

(* ============================================================
   Agent Health Metrics
   ============================================================ *)

let test_agent_heartbeat_age () =
  TM.set_agent_heartbeat_age ~agent_name:"alice" 42.5;
  let v = Otel_metric_store.metric_value_or_zero
    "masc_agent_heartbeat_age_seconds"
    ~labels:[("agent_name", "alice")] () in
  check (float 0.01) "alice heartbeat age" 42.5 v

let test_agent_stale_counter () =
  let before = Otel_metric_store.metric_value_or_zero
    "masc_agent_stale_total" () in
  TM.inc_agent_stale ();
  TM.inc_agent_stale ();
  let after = Otel_metric_store.metric_value_or_zero
    "masc_agent_stale_total" () in
  check (float 0.01) "stale count increment" 2.0 (after -. before)

(* ============================================================
   Transport Health JSON
   ============================================================ *)

let test_transport_health_json () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (Masc.Sse.close_all_clients ());
  let base_dir = temp_dir () in
  let config = Masc.Workspace.default_config base_dir in
  ignore (Masc.Workspace.init config ~agent_name:(Some "tester"));
  let auth =
    Masc_test_deps.make_sse_auth base_dir "transport-metrics-agent"
  in
  let register_exn ?kind session_id ~last_event_id =
    (* Pre-create the MCP session so registration validates an existing
       session rather than auto-bootstrapping one (security/sse-auth-validation). *)
    let (_ : Masc.Session.McpSessionStore.mcp_session) =
      Masc.Session.McpSessionStore.get_or_create ~id:session_id ()
    in
    match Masc.Sse.register ?kind ~auth session_id ~last_event_id with
    | Ok result -> result
    | Error e ->
        fail
          (Printf.sprintf "Sse.register failed: %s"
             (Masc.Sse.registration_error_to_string e))
  in
  ignore
    (register_exn ~kind:Masc.Sse.Observer "observer-session"
       ~last_event_id:0);
  ignore
    (register_exn ~kind:Masc.Sse.Agent_stream "agent_stream-session"
       ~last_event_id:0);
  ignore
    (register_exn ~kind:Masc.Sse.Presence "presence-session"
       ~last_event_id:0);
  TM.set_grpc_active_streams 1;
  TM.set_grpc_subscribers 2;
  Otel_metric_store.set_gauge Otel_metric_store.metric_agent_core_sse_relay_queue_depth 4.0;
  Otel_metric_store.inc_counter Otel_metric_store.metric_agent_core_sse_relay_retries
    ~labels:[ ("stage", "append") ] ~delta:2.0 ();
  Otel_metric_store.inc_counter Otel_metric_store.metric_agent_core_sse_relay_retries
    ~labels:[ ("stage", "broadcast") ] ~delta:1.0 ();
  Otel_metric_store.inc_counter Otel_metric_store.metric_agent_core_sse_relay_drops
    ~labels:[ ("stage", "queue") ] ~delta:3.0 ();
  Otel_metric_store.inc_counter Otel_metric_store.metric_agent_core_sse_relay_drops
    ~labels:[ ("stage", "append") ] ~delta:1.0 ();
  Otel_metric_store.inc_counter Keeper_metrics.(to_string LifecycleDispatchRejections)
    ~labels:[ ("event", "turn_started") ] ~delta:2.0 ();
  Masc.Sse.broadcast (`Assoc [ ("type", `String "transport-test") ]);
  Masc.Sse.sync_transport_snapshot ~force:true ();
  with_env "MASC_USE_H2" (Some "h1_only") (fun () ->
    ignore (Env_config.Transport.configure_h2_from_env ()););
  let json =
    with_env "MASC_USE_H2" (Some "h2_only") (fun () ->
      TM.transport_health_json ())
  in
  let sse_json = json |> U.member "sse" in
  let streamable_json = json |> U.member "streamable_http" in
  let grpc_json = json |> U.member "grpc" in
  let ws_json = json |> U.member "websocket" in
  let http2_json = json |> U.member "http2" in
  let summary_json = json |> U.member "summary" in
  let http_listener_json = json |> U.member "http_listener" in
  let agent_health_json = json |> U.member "agent_health" in
  check_assoc_keys
    "transport-health exact top-level keys"
    [ "summary"
    ; "http_listener"
    ; "sse"
    ; "grpc"
    ; "websocket"
    ; "streamable_http"
    ; "http2"
    ; "agent_health"
    ; "generated_at"
    ]
    json;
  check int "transport health reuses listener rate-limit total"
    (TM.http_listener_json ()
     |> U.member "rate_limit_responses_total"
     |> U.to_int)
    (http_listener_json
     |> U.member "rate_limit_responses_total"
     |> U.to_int);
  check_assoc_keys
    "summary exact keys"
    [ "primary_path"; "queue_pressure"; "external_fanout_targets" ]
    summary_json;
  check_assoc_keys
    "grpc exact keys"
    [ "configured"
    ; "listening"
    ; "port"
    ; "active_streams"
    ; "subscribers"
    ; "heartbeat_avg_seconds"
    ; "events_delivered"
    ; "events_dropped"
    ]
    grpc_json;
  check_assoc_keys
    "SSE exact keys"
    [ "sessions_observer"
    ; "sessions_agent_stream"
    ; "sessions_presence"
    ; "sessions_total"
    ; "external_subscribers"
    ; "broadcast_avg_seconds"
    ; "broadcast_count"
    ; "queue_avg_depth"
    ; "queue_max_depth"
    ; "relay_queue_depth"
    ; "relay_retry_total"
    ; "relay_retry_append"
    ; "relay_retry_broadcast"
    ; "relay_drop_total"
    ; "relay_drop_queue"
    ; "relay_drop_append"
    ; "relay_drop_broadcast"
    ; "hot_sessions"
    ]
    sse_json;
  check_assoc_keys
    "WebSocket exact keys"
    [ "configured"
    ; "listening"
    ; "mode"
    ; "sessions"
    ; "relay_source"
    ; "delivery"
    ]
    ws_json;
  check_assoc_keys
    "WebSocket delivery exact keys"
    [ "bytes_cache_hits"
    ; "bytes_cache_misses"
    ; "client_acks"
    ; "throttled_deliveries"
    ; "client_buffered_bytes_sum"
    ; "client_buffered_bytes_count"
    ]
    (ws_json |> U.member "delivery");
  check_assoc_keys
    "streamable HTTP exact keys"
    [ "endpoint"
    ; "observer_stream"
    ; "presence_stream"
    ; "supports_post"
    ; "supports_sse_upgrade"
    ; "auth_rejects_total"
    ]
    streamable_json;
  check_assoc_keys
    "HTTP/2 exact keys"
    [ "listener_mode"; "multiplex_ready" ]
    http2_json;
  check int "observer sessions" 1
    (sse_json |> U.member "sessions_observer" |> U.to_int);
  check int "agent_stream sessions" 1
    (sse_json |> U.member "sessions_agent_stream" |> U.to_int);
  check int "presence sessions" 1
    (sse_json |> U.member "sessions_presence" |> U.to_int);
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
  check string "presence stream endpoint" "/events/presence"
    (streamable_json |> U.member "presence_stream" |> U.to_string);
  check int "grpc active streams" 1
    (grpc_json |> U.member "active_streams" |> U.to_int);
  check int "grpc subscribers" 2
    (grpc_json |> U.member "subscribers" |> U.to_int);
  check bool "grpc events_dropped field present" true
    (match grpc_json |> U.member "events_dropped" with
     | `Int _ -> true | _ -> false);
  check bool "grpc listening field exists" true
    (match grpc_json |> U.member "listening" with `Bool _ -> true | _ -> false);
  check bool "websocket listening field exists" true
    (match ws_json |> U.member "listening" with `Bool _ -> true | _ -> false);
  check bool "websocket section exists" true
    (match ws_json with `Assoc _ -> true | _ -> false);
  check string "http2 reports the startup mode" "h1_only"
    (http2_json |> U.member "listener_mode" |> U.to_string);
  check bool "h1-only is not multiplex ready" false
    (http2_json |> U.member "multiplex_ready" |> U.to_bool);
  check bool "summary primary path exists" true
    (String.length (summary_json |> U.member "primary_path" |> U.to_string) > 0);
  (* The fixture queues 4 events and records 4 lifetime relay drops. Nothing is
     backing up -- 4 is under the watch threshold -- so the reading is steady.
     It used to be "high" because a lifetime drop counter fed this field, and
     that counter never decrements, so one drop held the reading there until
     the process restarted (#27652). The drops are still reported, as totals. *)
  check string "queue pressure reads the current depth" "steady"
    (summary_json |> U.member "queue_pressure" |> U.to_string);
  check int "the lifetime relay drops are still reported" 4
    (sse_json |> U.member "relay_drop_total" |> U.to_int);
  check int "agent lifecycle dispatch rejections surfaced" 2
    (agent_health_json
     |> U.member "lifecycle_dispatch_rejections_total"
     |> U.to_int);
  let delivery_json = ws_json |> U.member "delivery" in
  check bool "websocket delivery sub-object present" true
    (match delivery_json with `Assoc _ -> true | _ -> false);
  List.iter (fun (field, label) ->
    check bool (Printf.sprintf "%s field present (int)" label) true
      (match delivery_json |> U.member field with `Int _ -> true | _ -> false))
    [ "bytes_cache_hits", "bytes_cache_hits"
    ; "bytes_cache_misses", "bytes_cache_misses"
    ; "client_acks", "client_acks"
    ; "throttled_deliveries", "throttled_deliveries"
    ; "client_buffered_bytes_count", "client_buffered_bytes_count"
    ];
  check bool "client_buffered_bytes_sum field present (float)" true
    (match delivery_json |> U.member "client_buffered_bytes_sum" with
     | `Float _ | `Int _ -> true | _ -> false);
  ignore (Masc.Sse.close_all_clients ());
  cleanup_dir base_dir

(* ============================================================
   Listen Status (#3408)
   ============================================================ *)

let test_grpc_listen_status_lifecycle () =
  (* The status string is independent of the flag; [grpc_listening] is not, so
     the enabling half is named here rather than inherited from a default. *)
  let previous = Sys.getenv_opt "MASC_GRPC_ENABLED" in
  Unix.putenv "MASC_GRPC_ENABLED" "1";
  Fun.protect ~finally:(fun () ->
    Unix.putenv "MASC_GRPC_ENABLED" (Option.value previous ~default:"0"))
  @@ fun () ->
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

let test_listen_status_bind_failed () =
  TM.set_grpc_listen_status "bind_failed";
  TM.set_grpc_runtime_listening false;
  check bool "grpc not listening on bind_failed" false (TM.grpc_listening ());
  check string "grpc status is bind_failed" "bind_failed"
    (Atomic.get TM.grpc_listen_status)

let test_listen_status_disabled () =
  TM.set_grpc_listen_status "disabled";
  check string "grpc status disabled" "disabled"
    (Atomic.get TM.grpc_listen_status)

(* ============================================================
   Test Runner
   ============================================================ *)

(* Pressure has to answer "is anything backing up right now". Reading it off a
   lifetime drop counter froze it at "high" after the first drop, so the depths
   below could no longer move it either way (#27652). *)
let test_queue_pressure_tracks_current_depth () =
  Eio_main.run @@ fun _env ->
  let pressure_at depth =
    Otel_metric_store.set_gauge
      Otel_metric_store.metric_agent_core_sse_relay_queue_depth
      (float_of_int depth);
    TM.transport_health_json ()
    |> U.member "summary"
    |> U.member "queue_pressure"
    |> U.to_string
  in
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_agent_core_sse_relay_drops
    ~labels:[ ("stage", "queue") ]
    ~delta:7.0
    ();
  check string "an empty queue is steady even after drops" "steady" (pressure_at 0);
  check string "a filling queue is watched" "watch" (pressure_at 8);
  check string "a deep queue is high" "high" (pressure_at 32);
  check string "and it comes back down" "steady" (pressure_at 0)
;;

(* The wire words and the type are one set. A value the producer can emit and
   the reader cannot name is exactly the drift this pair was split to stop, so
   both directions are walked rather than spot-checked (#27652). *)
let test_summary_words_round_trip () =
  List.iter
    (fun kind ->
       let word = Masc.Transport_metrics.primary_path_kind_to_string kind in
       Alcotest.(check bool)
         (Printf.sprintf "primary_path %s round trips" word)
         true
         (Masc.Transport_metrics.primary_path_kind_of_string word = Some kind))
    [ Masc.Transport_metrics.Grpc_subscribe
    ; Masc.Transport_metrics.Websocket
    ; Masc.Transport_metrics.Sse
    ; Masc.Transport_metrics.Streamable_http
    ];
  List.iter
    (fun kind ->
       let word = Masc.Transport_metrics.queue_pressure_kind_to_string kind in
       Alcotest.(check bool)
         (Printf.sprintf "queue_pressure %s round trips" word)
         true
         (Masc.Transport_metrics.queue_pressure_kind_of_string word = Some kind))
    [ Masc.Transport_metrics.Steady
    ; Masc.Transport_metrics.Watch
    ; Masc.Transport_metrics.High
    ]
;;

(* A word from outside the set does not become a value. Before the split the
   TUI printed whatever arrived in this field. *)
let test_unknown_summary_word_is_refused () =
  Alcotest.(check bool)
    "an unknown primary_path is refused"
    true
    (Masc.Transport_metrics.primary_path_kind_of_string "carrier_pigeon" = None);
  Alcotest.(check bool)
    "an unknown queue_pressure is refused"
    true
    (Masc.Transport_metrics.queue_pressure_kind_of_string "panicking" = None)
;;

let () =
  run "Transport_metrics" [
    ("init", [
      test_case "registers all metric families" `Quick test_init;
    ]);
    ("sse", [
      test_case "set_sse_sessions by kind" `Quick test_sse_sessions;
      test_case "observe_broadcast_duration accumulates" `Quick test_broadcast_duration;
      test_case "broadcast events counter increments" `Quick test_broadcast_events_counter;
      test_case "inc_sse_idle_evicted increments" `Quick test_sse_idle_evicted;
      test_case "inc_sse_reject by reason label" `Quick test_sse_reject_labelled;
      test_case "inc_sse_reconnect increments" `Quick test_sse_reconnect;
    ]);
    ("grpc", [
      test_case "set_grpc_active_streams" `Quick test_grpc_active_streams;
      test_case "observe_grpc_heartbeat_latency" `Quick test_grpc_heartbeat_latency;
      test_case "set_grpc_subscribers" `Quick test_grpc_subscribers;
      test_case "inc_grpc_events_delivered" `Quick test_grpc_events_delivered;
      test_case "inc_grpc_events_dropped" `Quick test_grpc_events_dropped;
      test_case "runtime listening cache" `Quick test_grpc_runtime_listening_cache;
    ]);
    ("websocket", [
      test_case "set_ws_sessions" `Quick test_ws_sessions;
      test_case "observe dashboard hello latency" `Quick
        test_ws_dashboard_hello_latency;
      test_case "blank env stays enabled" `Quick
        test_ws_enabled_blank_env_matches_runtime;
      test_case "normalized env matches runtime" `Quick
        test_ws_enabled_normalized_env_matches_runtime;
    ]);
    ("http_listener", [
      test_case "primary listener state json" `Quick
        test_http_listener_state_json;
      test_case "typed rate-limit response counter" `Quick
        test_http_rate_limit_response_counter;
    ]);
    ("agent_health", [
      test_case "set_agent_heartbeat_age" `Quick test_agent_heartbeat_age;
      test_case "inc_agent_stale" `Quick test_agent_stale_counter;
    ]);
    ("json", [
      test_case "transport_health_json structure" `Quick test_transport_health_json;
      test_case "queue pressure tracks the current depth" `Quick
        test_queue_pressure_tracks_current_depth;
    ]);
    ("summary vocabulary", [
      test_case "wire words round trip" `Quick test_summary_words_round_trip;
      test_case "an unknown word is refused" `Quick
        test_unknown_summary_word_is_refused;
    ]);
    ("listen_status", [
      test_case "grpc listen_status lifecycle" `Quick
        test_grpc_listen_status_lifecycle;
      test_case "listen_status bind_failed" `Quick
        test_listen_status_bind_failed;
      test_case "listen_status disabled" `Quick
        test_listen_status_disabled;
    ]);
  ]
