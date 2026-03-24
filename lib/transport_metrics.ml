(** Transport Observability Metrics for 50-agent monitoring.

    Collects SSE, gRPC, and agent-health transport metrics in
    Prometheus text format via the existing Prometheus module.

    Metric naming follows Prometheus conventions:
    - masc_sse_* for SSE transport
    - masc_grpc_* for gRPC transport
    - masc_agent_heartbeat_* for agent liveness *)

(** {1 SSE Metrics} *)

type hot_queue_session = {
  session_id : string;
  kind : string;
  queue_depth : int;
  last_event_id : int;
  idle_seconds : float;
}

let sse_hot_sessions : hot_queue_session list ref = ref []

let register_sse_metrics () =
  Prometheus.register_gauge ~name:"masc_sse_sessions_total"
    ~help:"Active SSE sessions by kind" ();
  Prometheus.register_histogram ~name:"masc_sse_broadcast_duration_seconds"
    ~help:"Time to fan-out a broadcast to all SSE clients" ();
  Prometheus.register_counter ~name:"masc_sse_broadcast_events_total"
    ~help:"Total SSE broadcast events emitted" ();
  Prometheus.register_gauge ~name:"masc_sse_stream_queue_depth"
    ~help:"Per-session SSE event stream queue depth" ();
  Prometheus.register_gauge ~name:"masc_sse_queue_depth_avg"
    ~help:"Average SSE event queue depth across live sessions" ();
  Prometheus.register_gauge ~name:"masc_sse_queue_depth_max"
    ~help:"Maximum SSE event queue depth across live sessions" ();
  Prometheus.register_gauge ~name:"masc_sse_external_subscribers_total"
    ~help:"Active non-SSE subscribers bridged from the SSE fanout path" ()

let set_sse_sessions ~kind count =
  Prometheus.set_gauge "masc_sse_sessions_total"
    ~labels:[("kind", kind)] (float_of_int count)

let observe_broadcast_duration seconds =
  Prometheus.observe_histogram "masc_sse_broadcast_duration_seconds" seconds;
  Prometheus.inc_counter "masc_sse_broadcast_events_total" ()

let set_sse_queue_depth ~session_id depth =
  Prometheus.set_gauge "masc_sse_stream_queue_depth"
    ~labels:[("session_id", session_id)] (float_of_int depth)

let set_sse_queue_snapshot ~avg_depth ~max_depth ~hot_sessions =
  Prometheus.set_gauge "masc_sse_queue_depth_avg" avg_depth;
  Prometheus.set_gauge "masc_sse_queue_depth_max" (float_of_int max_depth);
  sse_hot_sessions := hot_sessions

let set_sse_external_subscribers count =
  Prometheus.set_gauge "masc_sse_external_subscribers_total" (float_of_int count)

(** {1 gRPC Metrics} *)

let register_grpc_metrics () =
  Prometheus.register_gauge ~name:"masc_grpc_active_streams_total"
    ~help:"Active gRPC bidirectional streams" ();
  Prometheus.register_histogram ~name:"masc_grpc_heartbeat_latency_seconds"
    ~help:"gRPC heartbeat round-trip latency" ();
  Prometheus.register_gauge ~name:"masc_grpc_subscribers_total"
    ~help:"Active gRPC Subscribe stream subscribers" ();
  Prometheus.register_counter ~name:"masc_grpc_events_delivered_total"
    ~help:"Total events delivered via gRPC streams" ()

let set_grpc_active_streams count =
  Prometheus.set_gauge "masc_grpc_active_streams_total" (float_of_int count)

let observe_grpc_heartbeat_latency seconds =
  Prometheus.observe_histogram "masc_grpc_heartbeat_latency_seconds" seconds

let set_grpc_subscribers count =
  Prometheus.set_gauge "masc_grpc_subscribers_total" (float_of_int count)

let inc_grpc_events_delivered ?(delta=1) () =
  Prometheus.inc_counter "masc_grpc_events_delivered_total"
    ~delta:(float_of_int delta) ()

(** {1 WebSocket Metrics} *)

let register_ws_metrics () =
  Prometheus.register_gauge ~name:"masc_ws_sessions_total"
    ~help:"Active standalone WebSocket sessions" ()

let set_ws_sessions count =
  Prometheus.set_gauge "masc_ws_sessions_total" (float_of_int count)

(** {1 Environment-derived Transport Config} *)

let grpc_enabled () =
  match Sys.getenv_opt "MASC_GRPC_ENABLED" with
  | Some raw -> (
      match String.trim raw |> String.lowercase_ascii with
      | "0" | "false" | "" -> false
      | _ -> true)
  | None -> true

let grpc_port () =
  match Sys.getenv_opt "MASC_GRPC_PORT" with
  | Some raw -> (
      match int_of_string_opt raw with
      | Some port when port > 0 && port < 65536 -> port
      | _ -> 8936)
  | None -> 8936

let grpc_listening () =
  grpc_enabled () && Mitosis_spawn.port_listening (grpc_port ())

(** {1 Agent Health Metrics} *)

let register_agent_metrics () =
  Prometheus.register_gauge ~name:"masc_agent_heartbeat_age_seconds"
    ~help:"Seconds since last heartbeat per agent" ();
  Prometheus.register_counter ~name:"masc_agent_stale_total"
    ~help:"Total agents that became stale (heartbeat age exceeded threshold)" ()

let set_agent_heartbeat_age ~agent_name age_seconds =
  Prometheus.set_gauge "masc_agent_heartbeat_age_seconds"
    ~labels:[("agent_name", agent_name)] age_seconds

let inc_agent_stale () =
  Prometheus.inc_counter "masc_agent_stale_total" ()

(** {1 Initialization} *)

let init () =
  register_sse_metrics ();
  register_grpc_metrics ();
  register_ws_metrics ();
  register_agent_metrics ()

(** {1 Transport Health JSON Snapshot} *)

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let int_field key json =
  match assoc_field key json with
  | Some (`Int value) -> value
  | Some (`Intlit raw) -> Safe_ops.int_of_string_with_default ~default:0 raw
  | _ -> 0

let cluster_summary_json config =
  match Command_plane_v2.topology_json config with
  | `Assoc fields -> (
      match List.assoc_opt "summary" fields with
      | Some (`Assoc _ as json) -> json
      | _ -> `Assoc [])
  | _ -> `Assoc []

let http_listener_mode () =
  match Sys.getenv_opt "MASC_USE_H2" with
  | Some raw -> (
      match String.trim raw |> String.lowercase_ascii with
      | "1" | "true" -> "h2_only"
      | "0" | "false" -> "h1_only"
      | "auto" | "" -> "auto"
      | _ -> "auto")
  | None -> "auto"

let primary_path ~webrtc_channels ~grpc_subscribers ~ws_sessions ~sse_sessions =
  if webrtc_channels > 0 then "webrtc_datachannel"
  else if grpc_subscribers > 0 then "grpc_subscribe"
  else if ws_sessions > 0 then "websocket"
  else if sse_sessions > 0 then "sse"
  else "streamable_http"

let queue_pressure max_queue_depth =
  if max_queue_depth >= 32 then "high"
  else if max_queue_depth >= 8 then "watch"
  else "steady"

let ws_enabled () =
  match Sys.getenv_opt "MASC_WS_ENABLED" with
  | Some raw -> (
      match String.trim raw |> String.lowercase_ascii with
      | "0" | "false" -> false
      | _ -> true)
  | None -> true

let ws_port () =
  match Sys.getenv_opt "MASC_WS_PORT" with
  | Some raw -> (
      match int_of_string_opt raw with
      | Some port when port > 0 && port < 65536 -> port
      | _ -> 8937)
  | None -> 8937

let ws_listening () =
  ws_enabled () && Mitosis_spawn.port_listening (ws_port ())

let hot_session_json (session : hot_queue_session) =
  `Assoc
    [
      ("session_id", `String session.session_id);
      ("kind", `String session.kind);
      ("queue_depth", `Int session.queue_depth);
      ("last_event_id", `Int session.last_event_id);
      ("idle_seconds", `Float session.idle_seconds);
    ]

let transport_health_json ~config =
  let v name ?(labels=[]) () =
    Prometheus.metric_value_or_zero name ~labels ()
  in
  let sse_observer = v "masc_sse_sessions_total" ~labels:[("kind", "observer")] () in
  let sse_coordinator = v "masc_sse_sessions_total" ~labels:[("kind", "coordinator")] () in
  let sse_total = int_of_float (sse_observer +. sse_coordinator) in
  let sse_external_subscribers =
    int_of_float (v "masc_sse_external_subscribers_total" ())
  in
  let sse_queue_avg = v "masc_sse_queue_depth_avg" () in
  let sse_queue_max = int_of_float (v "masc_sse_queue_depth_max" ()) in
  let broadcast_sum = v "masc_sse_broadcast_duration_seconds" () in
  let broadcast_count = v "masc_sse_broadcast_duration_seconds_count" () in
  let broadcast_avg =
    if broadcast_count > 0.0 then broadcast_sum /. broadcast_count else 0.0
  in
  let grpc_streams = v "masc_grpc_active_streams_total" () in
  let grpc_subscribers = v "masc_grpc_subscribers_total" () in
  let grpc_heartbeat_sum = v "masc_grpc_heartbeat_latency_seconds" () in
  let grpc_heartbeat_count = v "masc_grpc_heartbeat_latency_seconds_count" () in
  let grpc_heartbeat_avg =
    if grpc_heartbeat_count > 0.0 then grpc_heartbeat_sum /. grpc_heartbeat_count
    else 0.0
  in
  let grpc_events = v "masc_grpc_events_delivered_total" () in
  let stale_agents = v "masc_agent_stale_total" () in
  let ws_sessions = int_of_float (v "masc_ws_sessions_total" ()) in
  let grpc_configured = grpc_enabled () in
  let grpc_live = grpc_listening () in
  let ws_configured = ws_enabled () in
  let ws_live = ws_listening () in
  let webrtc_pending = Server_webrtc_transport.pending_offer_count () in
  let webrtc_peers = Server_webrtc_transport.active_peer_count () in
  let webrtc_live = Server_webrtc_transport.live_webrtc_count () in
  let webrtc_channels = Server_webrtc_transport.connected_channel_count () in
  let listener_mode = http_listener_mode () in
  let topology_summary = cluster_summary_json config in
  let room_id =
    try Room.current_room_id config
    with exn ->
      Log.Transport.debug "current_room_id failed: %s" (Printexc.to_string exn);
      "default"
  in
  let cluster_name =
    Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")
  in
  let recent_messages =
    try Room.get_messages_raw_in_room config ~room_id ~since_seq:0 ~limit:20 |> List.length
    with exn ->
      Log.Transport.debug "recent_messages count failed: %s" (Printexc.to_string exn);
      0
  in
  let grpc_subscribers_i = int_of_float grpc_subscribers in
  let primary_path =
    primary_path ~webrtc_channels ~grpc_subscribers:grpc_subscribers_i
      ~ws_sessions ~sse_sessions:sse_total
  in
  `Assoc [
    ("summary", `Assoc [
      ("primary_path", `String primary_path);
      ("queue_pressure", `String (queue_pressure sse_queue_max));
      ("recent_messages", `Int recent_messages);
      ("external_fanout_targets", `Int sse_external_subscribers);
    ]);
    ("sse", `Assoc [
      ("sessions_observer", `Int (int_of_float sse_observer));
      ("sessions_coordinator", `Int (int_of_float sse_coordinator));
      ("sessions_total", `Int sse_total);
      ("external_subscribers", `Int sse_external_subscribers);
      ("broadcast_avg_seconds", `Float broadcast_avg);
      ("broadcast_count", `Int (int_of_float broadcast_count));
      ("queue_avg_depth", `Float sse_queue_avg);
      ("queue_max_depth", `Int sse_queue_max);
      ("hot_sessions", `List (List.map hot_session_json !sse_hot_sessions));
    ]);
    ("grpc", `Assoc [
      ("enabled", `Bool grpc_configured);
      ("configured", `Bool grpc_configured);
      ("listening", `Bool grpc_live);
      ("port", `Int (grpc_port ()));
      ("active_streams", `Int (int_of_float grpc_streams));
      ("subscribers", `Int grpc_subscribers_i);
      ("heartbeat_avg_seconds", `Float grpc_heartbeat_avg);
      ("events_delivered", `Int (int_of_float grpc_events));
    ]);
    ("websocket", `Assoc [
      ("enabled", `Bool ws_configured);
      ("configured", `Bool ws_configured);
      ("listening", `Bool ws_live);
      ("mode", `String "standalone");
      ("port", `Int (ws_port ()));
      ("sessions", `Int ws_sessions);
      ("relay_source", `String "sse_external_subscriber");
    ]);
    ("webrtc", `Assoc [
      ("enabled", `Bool (Server_webrtc_transport.is_enabled ()));
      ("pending_offers", `Int webrtc_pending);
      ("active_peers", `Int webrtc_peers);
      ("live_connections", `Int webrtc_live);
      ("connected_channels", `Int webrtc_channels);
      ("ice_server_count",
       `Int (List.length (Server_webrtc_transport.configured_ice_server_urls ())));
    ]);
    ("streamable_http", `Assoc [
      ("endpoint", `String "/mcp");
      ("observer_stream", `String "/mcp?sse_kind=observer");
      ("managed_endpoint", `String "/mcp/managed");
      ("operator_endpoint", `String "/mcp/operator");
      ("delete_endpoint", `String "/mcp");
      ("legacy_sse_endpoint", `String "/sse");
      ("legacy_messages_endpoint", `String "/messages");
      ("default_transport", `String "streamable_http");
      ("supports_post", `Bool true);
      ("supports_sse_upgrade", `Bool true);
      ("supports_delete", `Bool true);
    ]);
    ("http2", `Assoc [
      ("listener_mode", `String listener_mode);
      ("multiplex_ready", `Bool (not (String.equal listener_mode "h1_only")));
      ("prior_knowledge_path", `String "/mcp");
    ]);
    ("cluster", `Assoc [
      ("cluster", `String cluster_name);
      ("room_id", `String room_id);
      ("total_units", `Int (int_field "total_units" topology_summary));
      ("managed_units", `Int (int_field "managed_unit_count" topology_summary));
      ("live_agents", `Int (int_field "live_agent_count" topology_summary));
      ("active_operations", `Int (int_field "active_operation_count" topology_summary));
      ("stale_units", `Int (int_field "stale_unit_count" topology_summary));
    ]);
    ("agent_health", `Assoc [
      ("stale_total", `Int (int_of_float stale_agents));
    ]);
    ("generated_at", `String (Types.now_iso ()));
  ]
