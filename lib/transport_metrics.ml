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

let sse_hot_sessions : hot_queue_session list Atomic.t = Atomic.make []

let set_sse_sessions ~kind count =
  Prometheus.set_gauge Prometheus.metric_sse_sessions
    ~labels:[("kind", kind)] (float_of_int count)

let observe_broadcast_duration ?target seconds =
  Prometheus.observe_histogram Prometheus.metric_sse_broadcast_duration seconds;
  let labels = match target with
    | None -> []
    | Some t -> [("target", t)]
  in
  Prometheus.inc_counter Prometheus.metric_sse_broadcast_events ~labels ()

(* P1 silent-failure fix (transport scan):
   masc_sse_broadcast_events_total only counts successes, so an operator
   reading "0 events / sec" cannot tell whether the system is genuinely
   idle or whether every broadcast is failing.  Pair with the success
   counter and the same target label so health is computable as
   `rate(failures[5m]) / (rate(events[5m]) + rate(failures[5m]))`. *)
let inc_broadcast_failure ?target () =
  let labels = match target with
    | None -> []
    | Some t -> [("target", t)]
  in
  Prometheus.inc_counter Prometheus.metric_sse_broadcast_failures ~labels ()

(* P1 silent-failure fix (transport scan):
   notify_external_subscribers in lib/sse.ml previously only logged
   callback exceptions (Log.Misc.warn), leaving gRPC subscriber
   flapping invisible to dashboards.  Counter is unlabelled because
   the subscriber identity is high-cardinality (sub_id is gRPC stream
   id); operators can correlate via the warn log line if needed. *)
let inc_external_subscriber_callback_failure () =
  Prometheus.inc_counter
    Prometheus.metric_sse_external_subscriber_callback_failures ()

(* P2 silent-failure fix (transport scan):
   The OAS relay drop-marker is the operator-visible signal that an
   OAS event was dropped after exhausting retries.  If the drop marker
   broadcast itself fails (oas_event_bridge.ml:430), operators get no
   indication a drop happened.  Distinct from inc_broadcast_failure
   so the recovery-path failure rate is isolated from normal broadcast
   failures. *)
let inc_relay_drop_marker_failure () =
  Prometheus.inc_counter
    Prometheus.metric_oas_sse_relay_drop_marker_failures ()

let set_sse_queue_depth ~session_id depth =
  Prometheus.set_gauge Prometheus.metric_sse_stream_queue_depth
    ~labels:[("session_id", session_id)] (float_of_int depth)

let set_sse_queue_snapshot ~avg_depth ~max_depth ~hot_sessions =
  Prometheus.set_gauge Prometheus.metric_sse_queue_depth_avg avg_depth;
  Prometheus.set_gauge Prometheus.metric_sse_queue_depth_max (float_of_int max_depth);
  Atomic.set sse_hot_sessions hot_sessions

let set_sse_external_subscribers count =
  Prometheus.set_gauge Prometheus.metric_sse_external_subscribers (float_of_int count)

let inc_sse_client_evicted () =
  Prometheus.inc_counter Prometheus.metric_sse_client_evictions ()

let inc_sse_idle_evicted () =
  Prometheus.inc_counter Prometheus.metric_sse_idle_evictions ()

let inc_sse_reject ~reason =
  Prometheus.inc_counter Prometheus.metric_sse_rejects
    ~labels:[("reason", reason)] ()

let inc_sse_reconnect () =
  Prometheus.inc_counter Prometheus.metric_sse_reconnects ()

(** {1 gRPC Metrics} *)

let set_grpc_active_streams count =
  Prometheus.set_gauge Prometheus.metric_grpc_active_streams (float_of_int count)

let observe_grpc_heartbeat_latency seconds =
  Prometheus.observe_histogram Prometheus.metric_grpc_heartbeat_latency seconds

let set_grpc_subscribers count =
  Prometheus.set_gauge Prometheus.metric_grpc_subscribers (float_of_int count)

let inc_grpc_events_delivered ?(delta=1) () =
  Prometheus.inc_counter Prometheus.metric_grpc_events_delivered
    ~delta:(float_of_int delta) ()

let inc_grpc_events_dropped () =
  Prometheus.inc_counter Prometheus.metric_grpc_events_dropped ()

(** {1 WebSocket Metrics} *)

let set_ws_sessions count =
  Prometheus.set_gauge Prometheus.metric_ws_sessions (float_of_int count)

let inc_ws_parse_cache_hit () =
  Prometheus.inc_counter Prometheus.metric_ws_parse_cache_hits ()

let inc_ws_parse_cache_miss () =
  Prometheus.inc_counter Prometheus.metric_ws_parse_cache_misses ()

let inc_ws_bytes_cache_hit () =
  Prometheus.inc_counter Prometheus.metric_ws_bytes_cache_hits ()

let inc_ws_bytes_cache_miss () =
  Prometheus.inc_counter Prometheus.metric_ws_bytes_cache_misses ()

let observe_ws_client_buffered_bytes n =
  let bytes = float_of_int (max 0 n) in
  Prometheus.observe_histogram Prometheus.metric_ws_client_buffered_bytes bytes;
  Prometheus.inc_counter Prometheus.metric_ws_client_acks ()

let inc_ws_throttled_delivery () =
  Prometheus.inc_counter Prometheus.metric_ws_throttled_deliveries ()

let inc_ws_slice_fanout_skipped () =
  Prometheus.inc_counter Prometheus.metric_ws_slice_fanout_skipped ()

let inc_ws_bytes_sent ~bytes =
  if bytes > 0 then
    Prometheus.inc_counter Prometheus.metric_ws_bytes_sent
      ~delta:(float_of_int bytes) ()

let observe_ws_message_bytes_sent n =
  let bytes = float_of_int (max 0 n) in
  Prometheus.observe_histogram Prometheus.metric_ws_message_bytes
    ~labels:[("direction", "send")] bytes

let observe_ws_message_bytes_recv n =
  let bytes = float_of_int (max 0 n) in
  Prometheus.observe_histogram Prometheus.metric_ws_message_bytes
    ~labels:[("direction", "recv")] bytes

let inc_grpc_bytes_sent ~bytes =
  if bytes > 0 then
    Prometheus.inc_counter Prometheus.metric_grpc_bytes_sent
      ~delta:(float_of_int bytes) ()

let inc_ws_delta_built () =
  Prometheus.inc_counter Prometheus.metric_ws_delta_built ()

let inc_grpc_backlog_replay_lines_scanned ?(delta=1) () =
  if delta > 0 then
    Prometheus.inc_counter
      Prometheus.metric_grpc_backlog_replay_lines_scanned
      ~delta:(float_of_int delta) ()

let inc_grpc_backlog_replay_events_replayed ?(delta=1) () =
  if delta > 0 then
    Prometheus.inc_counter
      Prometheus.metric_grpc_backlog_replay_events_replayed
      ~delta:(float_of_int delta) ()

(** {1 Primary HTTP listener state} *)

let http_listener_mode_runtime : string Atomic.t = Atomic.make "unknown"
let http_listener_status : string Atomic.t = Atomic.make "not_started"
let http_active_connections : int Atomic.t = Atomic.make 0
let http_last_accept_unix : float option Atomic.t = Atomic.make None
let http_last_accept_error : string option Atomic.t = Atomic.make None

let set_http_connection_gauge value =
  Prometheus.set_gauge Prometheus.metric_http_active_connections
    (float_of_int (max 0 value))

let record_http_listener_started ~mode =
  Atomic.set http_listener_mode_runtime mode;
  Atomic.set http_listener_status "listening";
  set_http_connection_gauge (Atomic.get http_active_connections)

let record_http_listener_stopped ~mode =
  Atomic.set http_listener_mode_runtime mode;
  Atomic.set http_listener_status "stopped";
  set_http_connection_gauge (Atomic.get http_active_connections)

let record_http_accept ~mode =
  Atomic.set http_listener_mode_runtime mode;
  Atomic.set http_listener_status "listening";
  Atomic.set http_last_accept_unix (Some (Unix.gettimeofday ()));
  Atomic.set http_last_accept_error None;
  Prometheus.inc_counter Prometheus.metric_http_accepts
    ~labels:[ ("mode", mode) ] ();
  let active = Atomic.fetch_and_add http_active_connections 1 + 1 in
  set_http_connection_gauge active

let rec dec_http_active_connections () =
  let before = Atomic.get http_active_connections in
  let after = max 0 (before - 1) in
  if Atomic.compare_and_set http_active_connections before after then
    after
  else
    dec_http_active_connections ()

let record_http_connection_closed ~mode =
  Atomic.set http_listener_mode_runtime mode;
  let active = dec_http_active_connections () in
  set_http_connection_gauge active

let record_http_accept_error ~mode ~error =
  Atomic.set http_listener_mode_runtime mode;
  Atomic.set http_listener_status "accept_error";
  Atomic.set http_last_accept_error (Some error);
  Prometheus.inc_counter Prometheus.metric_http_accept_errors
    ~labels:[ ("mode", mode) ] ()

let json_float_option = function
  | Some value -> `Float value
  | None -> `Null

let json_string_option = function
  | Some value -> `String value
  | None -> `Null

let http_listener_json ?now () =
  let now = match now with Some value -> value | None -> Unix.gettimeofday () in
  let last_accept_unix = Atomic.get http_last_accept_unix in
  let last_accept_age_seconds =
    Option.map (fun ts -> max 0.0 (now -. ts)) last_accept_unix
  in
  `Assoc
    [
      ("mode", `String (Atomic.get http_listener_mode_runtime));
      ("status", `String (Atomic.get http_listener_status));
      ("active_connections", `Int (Atomic.get http_active_connections));
      ( "accepted_total",
        `Int (int_of_float (Prometheus.metric_total Prometheus.metric_http_accepts)) );
      ( "accept_errors_total",
        `Int
          (int_of_float
             (Prometheus.metric_total Prometheus.metric_http_accept_errors)) );
      ("last_accept_unix", json_float_option last_accept_unix);
      ("last_accept_age_seconds", json_float_option last_accept_age_seconds);
      ("last_error", json_string_option (Atomic.get http_last_accept_error));
    ]

(** {1 Environment-derived Transport Config} *)

let grpc_runtime_listening : bool Atomic.t = Atomic.make false
let ws_runtime_listening : bool Atomic.t = Atomic.make false

(** Explanatory status for why a transport is or is not listening.
    Valid values: ["not_started"], ["disabled"], ["listening"],
    ["bind_failed"], ["stopped"]. *)
let grpc_listen_status : string Atomic.t = Atomic.make "not_started"
let ws_listen_status : string Atomic.t = Atomic.make "not_started"

let set_grpc_runtime_listening listening =
  Atomic.set grpc_runtime_listening listening

let set_ws_runtime_listening listening =
  Atomic.set ws_runtime_listening listening

let set_grpc_listen_status status =
  Atomic.set grpc_listen_status status

let set_ws_listen_status status =
  Atomic.set ws_listen_status status

let grpc_enabled () = Env_config.Transport.grpc_enabled ()

let grpc_port () = Env_config.Transport.grpc_port

let grpc_listening () =
  grpc_enabled () && Atomic.get grpc_runtime_listening

(** {1 Agent Health Metrics} *)

let set_agent_heartbeat_age ~agent_name age_seconds =
  Prometheus.set_gauge Prometheus.metric_agent_heartbeat_age_seconds
    ~labels:[("agent_name", agent_name)] age_seconds

let inc_agent_stale () =
  Prometheus.inc_counter Prometheus.metric_agent_stale_total ()

(** {1 Transport Health JSON Snapshot} *)

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let int_field key json =
  match assoc_field key json with
  | Some (`Int value) -> value
  | Some (`Intlit raw) -> Safe_ops.int_of_string_with_default ~default:0 raw
  | _ -> 0

let room_id_from_config (_config : Coord.config) = "default"

let cluster_summary_json (_config : Coord.config) =
  (* Transport health should stay metrics-only and avoid command-plane/Coord I/O. *)
  None

let int_field_opt key = function
  | Some json -> Some (int_field key json)
  | None -> None

let int_option_json = function
  | Some value -> `Int value
  | None -> `Null

let http_listener_mode () =
  Env_config.Transport.use_h2 ()
  |> Env_config.Transport.h2_mode_to_string

let primary_path ~webrtc_channels ~grpc_subscribers ~ws_sessions ~sse_sessions =
  if webrtc_channels > 0 then "webrtc_datachannel"
  else if grpc_subscribers > 0 then "grpc_subscribe"
  else if ws_sessions > 0 then "websocket"
  else if sse_sessions > 0 then "sse"
  else "streamable_http"

let queue_pressure
    ~sse_queue_max
    ~relay_queue_depth
    ~relay_retry_total
    ~relay_drop_total =
  let max_queue_depth = max sse_queue_max relay_queue_depth in
  if max_queue_depth >= 32 || relay_drop_total > 0 then "high"
  else if max_queue_depth >= 8 || relay_queue_depth > 0 || relay_retry_total > 0
  then "watch"
  else "steady"

let ws_enabled () = Env_config.Transport.ws_enabled ()

let ws_port () = Env_config.Transport.ws_port

let ws_listening () =
  ws_enabled () && Atomic.get ws_runtime_listening

let tcp_port_reachable port =
  try
    let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> try Unix.close sock with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ())
      (fun () ->
        Unix.connect sock
          (Unix.ADDR_INET
             (Unix.inet_addr_of_string Masc_network_defaults.masc_http_default_host, port));
        true)
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> false

let hot_session_json (session : hot_queue_session) =
  `Assoc
    [
      ("session_id", `String session.session_id);
      ("kind", `String session.kind);
      ("queue_depth", `Int session.queue_depth);
      ("last_event_id", `Int session.last_event_id);
      ("idle_seconds", `Float session.idle_seconds);
    ]

type ws_delivery_metric_names = {
  parse_cache_hits : string;
  parse_cache_misses : string;
  bytes_cache_hits : string;
  bytes_cache_misses : string;
  client_acks : string;
  throttled_deliveries : string;
  client_buffered_bytes : string;
  client_buffered_bytes_count : string;
}

let ws_delivery_metric_names =
  {
    parse_cache_hits = "masc_ws_parse_cache_hits_total";
    parse_cache_misses = "masc_ws_parse_cache_misses_total";
    bytes_cache_hits = "masc_ws_bytes_cache_hits_total";
    bytes_cache_misses = "masc_ws_bytes_cache_misses_total";
    client_acks = "masc_ws_client_acks_total";
    throttled_deliveries = "masc_ws_throttled_deliveries_total";
    client_buffered_bytes = "masc_ws_client_buffered_bytes";
    client_buffered_bytes_count = "masc_ws_client_buffered_bytes_count";
  }

let transport_health_json ~config =
  let v name ?(labels=[]) () =
    Prometheus.metric_value_or_zero name ~labels ()
  in
  let sse_observer = v Prometheus.metric_sse_sessions ~labels:[("kind", "observer")] () in
  let sse_coordinator = v Prometheus.metric_sse_sessions ~labels:[("kind", "coordinator")] () in
  let sse_presence = v Prometheus.metric_sse_sessions ~labels:[("kind", "presence")] () in
  let sse_total = int_of_float (sse_observer +. sse_coordinator +. sse_presence) in
  let sse_external_subscribers =
    int_of_float (v Prometheus.metric_sse_external_subscribers ())
  in
  let sse_queue_avg = v Prometheus.metric_sse_queue_depth_avg () in
  let sse_queue_max = int_of_float (v Prometheus.metric_sse_queue_depth_max ()) in
  let relay_queue_depth =
    int_of_float (v Prometheus.metric_oas_sse_relay_queue_depth ())
  in
  let relay_retry_append =
    int_of_float
      (v Prometheus.metric_oas_sse_relay_retries
         ~labels:[ ("stage", "append") ] ())
  in
  let relay_retry_broadcast =
    int_of_float
      (v Prometheus.metric_oas_sse_relay_retries
         ~labels:[ ("stage", "broadcast") ] ())
  in
  let relay_retry_total =
    int_of_float (Prometheus.metric_total Prometheus.metric_oas_sse_relay_retries)
  in
  let relay_drop_queue =
    int_of_float
      (v Prometheus.metric_oas_sse_relay_drops
         ~labels:[ ("stage", "queue") ] ())
  in
  let relay_drop_append =
    int_of_float
      (v Prometheus.metric_oas_sse_relay_drops
         ~labels:[ ("stage", "append") ] ())
  in
  let relay_drop_broadcast =
    int_of_float
      (v Prometheus.metric_oas_sse_relay_drops
         ~labels:[ ("stage", "broadcast") ] ())
  in
  let relay_drop_total =
    int_of_float (Prometheus.metric_total Prometheus.metric_oas_sse_relay_drops)
  in
  let broadcast_sum = v Prometheus.metric_sse_broadcast_duration () in
  let broadcast_count = v "masc_sse_broadcast_duration_seconds_count" () in
  let broadcast_avg =
    if broadcast_count > 0.0 then broadcast_sum /. broadcast_count else 0.0
  in
  let grpc_streams = v Prometheus.metric_grpc_active_streams () in
  let grpc_subscribers = v Prometheus.metric_grpc_subscribers () in
  let grpc_heartbeat_sum = v Prometheus.metric_grpc_heartbeat_latency () in
  let grpc_heartbeat_count = v "masc_grpc_heartbeat_latency_seconds_count" () in
  let grpc_heartbeat_avg =
    if grpc_heartbeat_count > 0.0 then grpc_heartbeat_sum /. grpc_heartbeat_count
    else 0.0
  in
  let grpc_events = v Prometheus.metric_grpc_events_delivered () in
  let grpc_events_dropped = v Prometheus.metric_grpc_events_dropped () in
  let stale_agents = v Prometheus.metric_agent_stale_total () in
  let lifecycle_dispatch_rejections =
    int_of_float
      (Prometheus.metric_total
         Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections)
  in
  let ws_delivery_metrics = ws_delivery_metric_names in
  let ws_sessions = int_of_float (v Prometheus.metric_ws_sessions ()) in
  let grpc_configured = grpc_enabled () in
  let grpc_live = grpc_listening () in
  let grpc_reachable = grpc_live || tcp_port_reachable (grpc_port ()) in
  let ws_configured = ws_enabled () in
  let ws_live = ws_listening () in
  let ws_reachable = ws_live || tcp_port_reachable (ws_port ()) in
  let streamable_auth_policy_present =
    Env_config.Transport.http_auth_strict_env_enabled ()
  in
  let webrtc_configured = Server_webrtc_transport.is_enabled () in
  let webrtc_pending = Server_webrtc_transport.pending_offer_count () in
  let webrtc_peers = Server_webrtc_transport.active_peer_count () in
  let webrtc_live = Server_webrtc_transport.live_webrtc_count () in
  let webrtc_channels = Server_webrtc_transport.connected_channel_count () in
  let listener_mode = http_listener_mode () in
  let topology_summary = cluster_summary_json config in
  let room_id =
    room_id_from_config config
  in
  let cluster_name = Env_config_core.cluster_name () in
  (* Keep transport-health free of Coord/PG reads so proactive refresh does not
     contend with dashboard and MCP writes on the shared backend. *)
  let recent_messages = None in
  let recent_messages_available = Option.is_some recent_messages in
  let grpc_subscribers_i = int_of_float grpc_subscribers in
  let primary_path =
    primary_path ~webrtc_channels ~grpc_subscribers:grpc_subscribers_i
      ~ws_sessions ~sse_sessions:sse_total
  in
  let topology_available = Option.is_some topology_summary in
  let degraded_source = "metrics_only" in
  `Assoc [
    ("summary", `Assoc [
      ("primary_path", `String primary_path);
      ("queue_pressure",
       `String
         (queue_pressure
            ~sse_queue_max
            ~relay_queue_depth
            ~relay_retry_total
            ~relay_drop_total));
      ("recent_messages", int_option_json recent_messages);
      ("recent_messages_available", `Bool recent_messages_available);
      ("recent_messages_source", `String degraded_source);
      ("external_fanout_targets", `Int sse_external_subscribers);
    ]);
    ("sse", `Assoc [
      ("sessions_observer", `Int (int_of_float sse_observer));
      ("sessions_coordinator", `Int (int_of_float sse_coordinator));
      ("sessions_presence", `Int (int_of_float sse_presence));
      ("sessions_total", `Int sse_total);
      ("external_subscribers", `Int sse_external_subscribers);
      ("broadcast_avg_seconds", `Float broadcast_avg);
      ("broadcast_count", `Int (int_of_float broadcast_count));
      ("queue_avg_depth", `Float sse_queue_avg);
      ("queue_max_depth", `Int sse_queue_max);
      ("relay_queue_depth", `Int relay_queue_depth);
      ("relay_retry_total", `Int relay_retry_total);
      ("relay_retry_append", `Int relay_retry_append);
      ("relay_retry_broadcast", `Int relay_retry_broadcast);
      ("relay_drop_total", `Int relay_drop_total);
      ("relay_drop_queue", `Int relay_drop_queue);
      ("relay_drop_append", `Int relay_drop_append);
      ("relay_drop_broadcast", `Int relay_drop_broadcast);
      ("hot_sessions", `List (List.map hot_session_json (Atomic.get sse_hot_sessions)));
    ]);
    ("grpc", `Assoc [
      ("enabled", `Bool grpc_configured);
      ("configured", `Bool grpc_configured);
      ("listening", `Bool grpc_live);
      ("reachable", `Bool grpc_reachable);
      ("listen_status", `String (Atomic.get grpc_listen_status));
      ("port", `Int (grpc_port ()));
      ("active_streams", `Int (int_of_float grpc_streams));
      ("subscribers", `Int grpc_subscribers_i);
      ("heartbeat_avg_seconds", `Float grpc_heartbeat_avg);
      ("events_delivered", `Int (int_of_float grpc_events));
      ("events_dropped", `Int (int_of_float grpc_events_dropped));
    ]);
    ("websocket", `Assoc [
      ("enabled", `Bool ws_configured);
      ("configured", `Bool ws_configured);
      ("listening", `Bool ws_live);
      ("reachable", `Bool ws_reachable);
      ("listen_status", `String (Atomic.get ws_listen_status));
      ("mode", `String "standalone");
      ("port", `Int (ws_port ()));
      ("sessions", `Int ws_sessions);
      ("relay_source", `String "sse_external_subscriber");
      (* Diagnostic counters for the WS delivery path.  The metric names
         are catalogued here so this surface does not take a compile-time
         dependency on any particular WS perf/observability PR.  If a
         producing PR has not registered a metric yet, [metric_value_or_zero]
         returns 0.0, which reads naturally as "nothing has happened". *)
      ("delivery", `Assoc [
        ("parse_cache_hits",
         `Int (int_of_float (v ws_delivery_metrics.parse_cache_hits ())));
        ("parse_cache_misses",
         `Int (int_of_float (v ws_delivery_metrics.parse_cache_misses ())));
        ("bytes_cache_hits",
         `Int (int_of_float (v ws_delivery_metrics.bytes_cache_hits ())));
        ("bytes_cache_misses",
         `Int (int_of_float (v ws_delivery_metrics.bytes_cache_misses ())));
        ("client_acks",
         `Int (int_of_float (v ws_delivery_metrics.client_acks ())));
        ("throttled_deliveries",
         `Int (int_of_float (v ws_delivery_metrics.throttled_deliveries ())));
        (* Histogram sum + auto _count give operators enough to compute
           average buffered bytes per ack without scraping /metrics. *)
        ("client_buffered_bytes_sum",
         `Float (v ws_delivery_metrics.client_buffered_bytes ()));
        ("client_buffered_bytes_count",
         `Int (int_of_float (v ws_delivery_metrics.client_buffered_bytes_count ())));
      ]);
    ]);
    ("webrtc", `Assoc [
      ("enabled", `Bool webrtc_configured);
      ("configured", `Bool webrtc_configured);
      ("signaling_available", `Bool webrtc_configured);
      ("signaling_mode", `String "shared_http");
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
      ("presence_stream", `String "/events/presence");
      ("managed_endpoint", `String "/mcp/managed");
      ("operator_endpoint", `String "/mcp/operator");
      ("delete_endpoint", `String "/mcp");
      ("legacy_sse_endpoint", `String "/sse");
      ("legacy_messages_endpoint", `String "/messages");
      ("default_transport", `String "streamable_http");
      ("configured", `Bool true);
      ("protocol_capable", `Bool true);
      ("auth_policy_present", `Bool streamable_auth_policy_present);
      ("supports_post", `Bool true);
      ("supports_sse_upgrade", `Bool true);
      ("supports_delete", `Bool true);
      ("listener", http_listener_json ());
    ]);
    ("http2", `Assoc [
      ("listener_mode", `String listener_mode);
      ("multiplex_ready", `Bool (not (String.equal listener_mode "h1_only")));
      ("prior_knowledge_path", `String "/mcp");
    ]);
    ("cluster", `Assoc [
      ("cluster", `String cluster_name);
      ("room_id", `String room_id);
      ("topology_available", `Bool topology_available);
      ("topology_source", `String degraded_source);
      ("total_units", int_option_json (int_field_opt "total_units" topology_summary));
      ("managed_units", int_option_json (int_field_opt "managed_unit_count" topology_summary));
      ("live_agents", int_option_json (int_field_opt "live_agent_count" topology_summary));
      ("active_operations", int_option_json (int_field_opt "active_operation_count" topology_summary));
      ("stale_units", int_option_json (int_field_opt "stale_unit_count" topology_summary));
    ]);
    ("agent_health", `Assoc [
      ("stale_total", `Int (int_of_float stale_agents));
      ("lifecycle_dispatch_rejections_total",
       `Int lifecycle_dispatch_rejections);
    ]);
    ("generated_at", `String (Masc_domain.now_iso ()));
  ]
