(** Transport Observability Metrics for 50-agent monitoring.

    Collects SSE, gRPC, and agent-health transport metrics in
    Otel_metric_store text format via the existing Otel_metric_store module.

    Metric naming follows Otel_metric_store conventions:
    - masc_sse_* for SSE transport
    - masc_grpc_* for gRPC transport
    - masc_agent_heartbeat_* for agent liveness *)

let webrtc_is_enabled_ref = Atomic.make (fun () -> false)
let webrtc_pending_count_ref = Atomic.make (fun () -> 0)
let webrtc_peers_count_ref = Atomic.make (fun () -> 0)
let webrtc_live_count_ref = Atomic.make (fun () -> 0)
let webrtc_channels_count_ref = Atomic.make (fun () -> 0)
let webrtc_ice_servers_urls_ref = Atomic.make (fun () -> [])

let register_webrtc_metrics ~is_enabled ~pending_count ~peers_count ~live_count ~channels_count ~ice_servers_urls =
  Atomic.set webrtc_is_enabled_ref is_enabled;
  Atomic.set webrtc_pending_count_ref pending_count;
  Atomic.set webrtc_peers_count_ref peers_count;
  Atomic.set webrtc_live_count_ref live_count;
  Atomic.set webrtc_channels_count_ref channels_count;
  Atomic.set webrtc_ice_servers_urls_ref ice_servers_urls
;;

(** {1 SSE Metrics} *)

type hot_queue_session =
  { session_id : string
  ; kind : string
  ; queue_depth : int
  ; last_event_id : int
  ; idle_seconds : float
  }

let sse_hot_sessions : hot_queue_session list Atomic.t = Atomic.make []

let set_sse_sessions ~kind count =
  Otel_metric_store.set_gauge
    Otel_metric_store.metric_sse_sessions
    ~labels:[ "kind", kind ]
    (float_of_int count)
;;

let observe_broadcast_duration ?target seconds =
  Otel_metric_store.observe_histogram Otel_metric_store.metric_sse_broadcast_duration seconds;
  let labels =
    match target with
    | None -> []
    | Some t -> [ "target", t ]
  in
  Otel_metric_store.inc_counter Otel_metric_store.metric_sse_broadcast_events ~labels ()
;;

(* P1 silent-failure fix (transport scan):
   masc_sse_broadcast_events_total only counts successes, so an operator
   reading "0 events / sec" cannot tell whether the system is genuinely
   idle or whether every broadcast is failing.  Pair with the success
   counter and the same target label so health is computable as
   `rate(failures[5m]) / (rate(events[5m]) + rate(failures[5m]))`. *)
let inc_broadcast_failure ?target () =
  let labels =
    match target with
    | None -> []
    | Some t -> [ "target", t ]
  in
  Otel_metric_store.inc_counter Otel_metric_store.metric_sse_broadcast_failures ~labels ()
;;

(* P1 silent-failure fix (transport scan):
   notify_external_subscribers in lib/sse.ml previously only logged
   callback exceptions (Log.Misc.warn), leaving gRPC subscriber
   flapping invisible to dashboards.  Counter is unlabelled because
   the subscriber identity is high-cardinality (sub_id is gRPC stream
   id); operators can correlate via the warn log line if needed. *)
let inc_external_subscriber_callback_failure () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_sse_external_subscriber_callback_failures ()
;;

let observe_external_subscriber_fanout_duration seconds =
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_sse_external_fanout_duration_seconds
    (max 0.0 seconds)
;;

(* P2 silent-failure fix (transport scan):
   The OAS relay drop-marker is the operator-visible signal that an
   OAS event was dropped after exhausting retries.  If the drop marker
   broadcast itself fails (oas_event_bridge.ml:430), operators get no
   indication a drop happened.  Distinct from inc_broadcast_failure
   so the recovery-path failure rate is isolated from normal broadcast
   failures. *)
let inc_relay_drop_marker_failure () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_oas_sse_relay_drop_marker_failures ()
;;

let set_sse_queue_depth ~session_id depth =
  Otel_metric_store.set_gauge
    Otel_metric_store.metric_sse_stream_queue_depth
    ~labels:[ "session_id", session_id ]
    (float_of_int depth)
;;

let set_sse_queue_snapshot ~avg_depth ~max_depth ~hot_sessions =
  Otel_metric_store.set_gauge Otel_metric_store.metric_sse_queue_depth_avg avg_depth;
  Otel_metric_store.set_gauge Otel_metric_store.metric_sse_queue_depth_max (float_of_int max_depth);
  Atomic.set sse_hot_sessions hot_sessions
;;

let set_sse_external_subscribers count =
  Otel_metric_store.set_gauge Otel_metric_store.metric_sse_external_subscribers (float_of_int count)
;;

let inc_sse_client_evicted () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_sse_client_evictions ()
;;

let inc_sse_idle_evicted () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_sse_idle_evictions ()
;;

let inc_sse_reject ~reason =
  Otel_metric_store.inc_counter Otel_metric_store.metric_sse_rejects ~labels:[ "reason", reason ] ()
;;

let inc_sse_reconnect () = Otel_metric_store.inc_counter Otel_metric_store.metric_sse_reconnects ()

(** {1 gRPC Metrics} *)

let set_grpc_active_streams count =
  Otel_metric_store.set_gauge Otel_metric_store.metric_grpc_active_streams (float_of_int count)
;;

let observe_grpc_heartbeat_latency seconds =
  Otel_metric_store.observe_histogram Otel_metric_store.metric_grpc_heartbeat_latency seconds
;;

let set_grpc_subscribers count =
  Otel_metric_store.set_gauge Otel_metric_store.metric_grpc_subscribers (float_of_int count)
;;

let inc_grpc_events_delivered ?(delta = 1) () =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_grpc_events_delivered
    ~delta:(float_of_int delta)
    ()
;;

let inc_grpc_events_dropped () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_grpc_events_dropped ()
;;

(** {1 WebSocket Metrics} *)

let set_ws_sessions count =
  Otel_metric_store.set_gauge Otel_metric_store.metric_ws_sessions (float_of_int count)
;;

let inc_ws_parse_cache_hit () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_ws_parse_cache_hits ()
;;

let inc_ws_parse_cache_miss () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_ws_parse_cache_misses ()
;;

(** Iter 28 visibility fix — counter for previously-silent JSON parse
    drops in parse_sse_dashboard_event. Closed 2-value error_kind
    vocab keeps Otel_metric_store label cardinality bounded. *)
type ws_frame_json_parse_error_kind =
  | Yojson_parse_error
  | Other_ws_frame_json_parse_error

let ws_frame_json_parse_error_kind_to_string = function
  | Yojson_parse_error -> "yojson_parse_error"
  | Other_ws_frame_json_parse_error -> "other"
;;

let inc_ws_frame_json_parse_failure ~error_kind =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_server_mcp_ws_frame_json_parse_failures
    ~labels:[ "error_kind", ws_frame_json_parse_error_kind_to_string error_kind ]
    ()
;;

let inc_ws_bytes_cache_hit () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_ws_bytes_cache_hits ()
;;

let inc_ws_bytes_cache_miss () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_ws_bytes_cache_misses ()
;;

let observe_ws_dashboard_hello_latency ~success seconds =
  let outcome = if success then "success" else "error" in
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_ws_dashboard_hello_latency_seconds
    ~labels:[ "outcome", outcome ]
    (max 0.0 seconds)
;;

let observe_ws_client_buffered_bytes n =
  let bytes = float_of_int (max 0 n) in
  Otel_metric_store.observe_histogram Otel_metric_store.metric_ws_client_buffered_bytes bytes;
  Otel_metric_store.inc_counter Otel_metric_store.metric_ws_client_acks ()
;;

let inc_ws_throttled_delivery () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_ws_throttled_deliveries ()
;;

let inc_ws_slice_fanout_skipped () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_ws_slice_fanout_skipped ()
;;

let inc_ws_bytes_sent ~bytes =
  if bytes > 0
  then
    Otel_metric_store.inc_counter Otel_metric_store.metric_ws_bytes_sent ~delta:(float_of_int bytes) ()
;;

let observe_ws_message_bytes_sent n =
  let bytes = float_of_int (max 0 n) in
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_ws_message_bytes
    ~labels:[ "direction", "send" ]
    bytes
;;

let observe_ws_message_bytes_recv n =
  let bytes = float_of_int (max 0 n) in
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_ws_message_bytes
    ~labels:[ "direction", "recv" ]
    bytes
;;

let inc_grpc_bytes_sent ~bytes =
  if bytes > 0
  then
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_grpc_bytes_sent
      ~delta:(float_of_int bytes)
      ()
;;

let inc_ws_delta_built () = Otel_metric_store.inc_counter Otel_metric_store.metric_ws_delta_built ()

let inc_ws_delta_payload_serialization () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_ws_delta_payload_serializations ()
;;

let inc_grpc_backlog_replay_lines_scanned ?(delta = 1) () =
  if delta > 0
  then
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_grpc_backlog_replay_lines_scanned
      ~delta:(float_of_int delta)
      ()
;;

let inc_grpc_backlog_replay_events_replayed ?(delta = 1) () =
  if delta > 0
  then
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_grpc_backlog_replay_events_replayed
      ~delta:(float_of_int delta)
      ()
;;

(** {1 Primary HTTP listener state} *)

let http_listener_mode_runtime : string Atomic.t = Atomic.make "unknown"
let http_listener_status : string Atomic.t = Atomic.make "not_started"
let http_active_connections : int Atomic.t = Atomic.make 0
let http_last_accept_unix : float option Atomic.t = Atomic.make None
let http_last_accept_error : string option Atomic.t = Atomic.make None

let set_http_connection_gauge value =
  Otel_metric_store.set_gauge
    Otel_metric_store.metric_http_active_connections
    (float_of_int (max 0 value))
;;

let record_http_listener_started ~mode =
  Atomic.set http_listener_mode_runtime mode;
  Atomic.set http_listener_status "listening";
  set_http_connection_gauge (Atomic.get http_active_connections)
;;

let record_http_listener_stopped ~mode =
  Atomic.set http_listener_mode_runtime mode;
  Atomic.set http_listener_status "stopped";
  set_http_connection_gauge (Atomic.get http_active_connections)
;;

let record_http_accept ~mode =
  Atomic.set http_listener_mode_runtime mode;
  Atomic.set http_listener_status "listening";
  Atomic.set http_last_accept_unix (Some (Unix.gettimeofday ()));
  Atomic.set http_last_accept_error None;
  Otel_metric_store.inc_counter Otel_metric_store.metric_http_accepts ~labels:[ "mode", mode ] ();
  let active = Atomic.fetch_and_add http_active_connections 1 + 1 in
  set_http_connection_gauge active
;;

let rec dec_http_active_connections () =
  let before = Atomic.get http_active_connections in
  let after = max 0 (before - 1) in
  if Atomic.compare_and_set http_active_connections before after
  then after
  else dec_http_active_connections ()
;;

let record_http_connection_closed ~mode =
  Atomic.set http_listener_mode_runtime mode;
  let active = dec_http_active_connections () in
  set_http_connection_gauge active
;;

let record_http_accept_error ~mode ~error =
  Atomic.set http_listener_mode_runtime mode;
  Atomic.set http_listener_status "accept_error";
  Atomic.set http_last_accept_error (Some error);
  Otel_metric_store.inc_counter Otel_metric_store.metric_http_accept_errors ~labels:[ "mode", mode ] ()
;;

let accept_latency_metric = "masc_http_accept_latency_seconds"
let accept_latency_registered = Atomic.make false

let ensure_accept_latency_registered () =
  if Atomic.get accept_latency_registered
  then ()
  else (
    Atomic.set accept_latency_registered true;
    Otel_metric_store.register_histogram
      ~name:accept_latency_metric
      ~help:
        "Time spent in Eio.Net.accept before a new TCP connection is handed to the \
         accept loop.  A rising value signals fiber scheduling starvation — keeper turns \
         or other long-running fibers not yielding back to the scheduler.  Labels: mode \
         (h1|h2|auto)."
      ())
;;

let record_http_accept_latency ~mode latency_s =
  ensure_accept_latency_registered ();
  Otel_metric_store.observe_histogram accept_latency_metric ~labels:[ "mode", mode ] latency_s
;;

let json_float_option = function
  | Some value -> `Float value
  | None -> `Null
;;

let http_listener_json ?now () =
  let now =
    match now with
    | Some value -> value
    | None -> Unix.gettimeofday ()
  in
  let last_accept_unix = Atomic.get http_last_accept_unix in
  let last_accept_age_seconds =
    Option.map (fun ts -> max 0.0 (now -. ts)) last_accept_unix
  in
  `Assoc
    [ "mode", `String (Atomic.get http_listener_mode_runtime)
    ; "status", `String (Atomic.get http_listener_status)
    ; "active_connections", `Int (Atomic.get http_active_connections)
    ; ( "accepted_total"
      , `Int (int_of_float (Otel_metric_store.metric_total Otel_metric_store.metric_http_accepts)) )
    ; ( "accept_errors_total"
      , `Int (int_of_float (Otel_metric_store.metric_total Otel_metric_store.metric_http_accept_errors))
      )
    ; "last_accept_unix", json_float_option last_accept_unix
    ; "last_accept_age_seconds", json_float_option last_accept_age_seconds
    ; "last_error", Json_util.string_opt_to_json (Atomic.get http_last_accept_error)
    ]
;;

(** {1 Environment-derived Transport Config} *)

let grpc_runtime_listening : bool Atomic.t = Atomic.make false
let ws_runtime_listening : bool Atomic.t = Atomic.make false
let ws_same_origin_runtime_ready : bool Atomic.t = Atomic.make false

(** Explanatory status for why a transport is or is not listening.
    Valid values: ["not_started"], ["disabled"], ["listening"],
    ["bind_failed"], ["stopped"]. *)
let grpc_listen_status : string Atomic.t = Atomic.make "not_started"

let ws_listen_status : string Atomic.t = Atomic.make "not_started"
let set_grpc_runtime_listening listening = Atomic.set grpc_runtime_listening listening
let set_ws_runtime_listening listening = Atomic.set ws_runtime_listening listening
let set_ws_same_origin_runtime_ready ready =
  Atomic.set ws_same_origin_runtime_ready ready

let set_grpc_listen_status status = Atomic.set grpc_listen_status status
let set_ws_listen_status status = Atomic.set ws_listen_status status
let grpc_enabled () = Env_config.Transport.grpc_enabled ()
let grpc_port () = Env_config.Transport.grpc_port
let grpc_listening () = grpc_enabled () && Atomic.get grpc_runtime_listening

(** {1 Agent Health Metrics} *)

let set_agent_heartbeat_age ~agent_name age_seconds =
  Otel_metric_store.set_gauge
    Otel_metric_store.metric_agent_heartbeat_age_seconds
    ~labels:[ "agent_name", agent_name ]
    age_seconds
;;

let inc_agent_stale () = Otel_metric_store.inc_counter Otel_metric_store.metric_agent_stale_total ()

(** {1 Transport Health JSON Snapshot} *)

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let int_field key json =
  match assoc_field key json with
  | Some (`Int value) -> value
  | Some (`Intlit raw) -> Safe_ops.int_of_string_with_default ~default:0 raw
  | _ -> 0
;;

let workspace_id_from_config (_config : Workspace.config) = "default"

let cluster_summary_json (_config : Workspace.config) =
  (* Transport health should stay metrics-only and avoid command-plane/Workspace I/O. *)
  None
;;

let int_field_opt key = function
  | Some json -> Some (int_field key json)
  | None -> None
;;


let http_listener_mode () =
  Env_config.Transport.use_h2 () |> Env_config.Transport.h2_mode_to_string
;;

let primary_path ~webrtc_channels ~grpc_subscribers ~ws_sessions ~sse_sessions =
  if webrtc_channels > 0
  then "webrtc_datachannel"
  else if grpc_subscribers > 0
  then "grpc_subscribe"
  else if ws_sessions > 0
  then "websocket"
  else if sse_sessions > 0
  then "sse"
  else "streamable_http"
;;

let queue_pressure ~sse_queue_max ~relay_queue_depth ~relay_retry_total ~relay_drop_total =
  let max_queue_depth = max sse_queue_max relay_queue_depth in
  if max_queue_depth >= 32 || relay_drop_total > 0
  then "high"
  else if max_queue_depth >= 8 || relay_queue_depth > 0 || relay_retry_total > 0
  then "watch"
  else "steady"
;;

let ws_enabled () = Env_config.Transport.ws_enabled ()
let ws_port () = Env_config.Transport.ws_port
let ws_listening () = ws_enabled () && Atomic.get ws_runtime_listening
let ws_same_origin_ready () =
  ws_enabled () && Atomic.get ws_same_origin_runtime_ready

(* [tcp_port_reachable] is intentionally [false], matching the canonical
   decision in [Transport_read_model.tcp_port_reachable]. A stdlib
   [Unix.connect] probe here would (a) block the Eio domain on a syscall
   inside the transport-health refresh path and (b) only ever flip to
   [true] by racing a foreign listener on the same port, which is not a
   useful health signal. With this, [grpc_reachable]/[ws_reachable]
   collapse to their [*_live] (listener-bound) state, the single source
   of truth shared with the read model. Argument kept for call-site
   stability. *)
let tcp_port_reachable (_port : int) : bool = false
;;

let hot_session_json (session : hot_queue_session) =
  `Assoc
    [ "session_id", `String session.session_id
    ; "kind", `String session.kind
    ; "queue_depth", `Int session.queue_depth
    ; "last_event_id", `Int session.last_event_id
    ; "idle_seconds", `Float session.idle_seconds
    ]
;;

type ws_delivery_metric_names =
  { parse_cache_hits : string
  ; parse_cache_misses : string
  ; bytes_cache_hits : string
  ; bytes_cache_misses : string
  ; client_acks : string
  ; throttled_deliveries : string
  ; delta_payload_serializations : string
  ; client_buffered_bytes : string
  ; client_buffered_bytes_count : string
  ; hello_latency : string
  ; hello_latency_count : string
  }

let ws_delivery_metric_names =
  { parse_cache_hits = "masc_ws_parse_cache_hits_total"
  ; parse_cache_misses = "masc_ws_parse_cache_misses_total"
  ; bytes_cache_hits = "masc_ws_bytes_cache_hits_total"
  ; bytes_cache_misses = "masc_ws_bytes_cache_misses_total"
  ; client_acks = "masc_ws_client_acks_total"
  ; throttled_deliveries = "masc_ws_throttled_deliveries_total"
  ; delta_payload_serializations = "masc_ws_delta_payload_serializations_total"
  ; client_buffered_bytes = "masc_ws_client_buffered_bytes"
  ; client_buffered_bytes_count = "masc_ws_client_buffered_bytes_count"
  ; hello_latency = Otel_metric_store.metric_ws_dashboard_hello_latency_seconds
  ; hello_latency_count = Otel_metric_store.metric_ws_dashboard_hello_latency_seconds ^ "_count"
  }
;;

let transport_health_json ~config =
  let v name ?(labels = []) () = Otel_metric_store.metric_value_or_zero name ~labels () in
  let sse_observer = v Otel_metric_store.metric_sse_sessions ~labels:[ "kind", "observer" ] () in
  let sse_agent_stream =
    v Otel_metric_store.metric_sse_sessions ~labels:[ "kind", "agent_stream" ] ()
  in
  let sse_presence = v Otel_metric_store.metric_sse_sessions ~labels:[ "kind", "presence" ] () in
  let sse_total = int_of_float (sse_observer +. sse_agent_stream +. sse_presence) in
  let sse_external_subscribers =
    int_of_float (v Otel_metric_store.metric_sse_external_subscribers ())
  in
  let sse_queue_avg = v Otel_metric_store.metric_sse_queue_depth_avg () in
  let sse_queue_max = int_of_float (v Otel_metric_store.metric_sse_queue_depth_max ()) in
  let relay_queue_depth =
    int_of_float (v Otel_metric_store.metric_oas_sse_relay_queue_depth ())
  in
  let relay_retry_append =
    int_of_float
      (v Otel_metric_store.metric_oas_sse_relay_retries ~labels:[ "stage", "append" ] ())
  in
  let relay_retry_broadcast =
    int_of_float
      (v Otel_metric_store.metric_oas_sse_relay_retries ~labels:[ "stage", "broadcast" ] ())
  in
  let relay_retry_total =
    int_of_float (Otel_metric_store.metric_total Otel_metric_store.metric_oas_sse_relay_retries)
  in
  let relay_drop_queue =
    int_of_float (v Otel_metric_store.metric_oas_sse_relay_drops ~labels:[ "stage", "queue" ] ())
  in
  let relay_drop_append =
    int_of_float
      (v Otel_metric_store.metric_oas_sse_relay_drops ~labels:[ "stage", "append" ] ())
  in
  let relay_drop_broadcast =
    int_of_float
      (v Otel_metric_store.metric_oas_sse_relay_drops ~labels:[ "stage", "broadcast" ] ())
  in
  let relay_drop_total =
    int_of_float (Otel_metric_store.metric_total Otel_metric_store.metric_oas_sse_relay_drops)
  in
  let broadcast_sum = v Otel_metric_store.metric_sse_broadcast_duration () in
  let broadcast_count = v "masc_sse_broadcast_duration_seconds_count" () in
  let broadcast_avg =
    if broadcast_count > 0.0 then broadcast_sum /. broadcast_count else 0.0
  in
  let external_fanout_sum =
    v Otel_metric_store.metric_sse_external_fanout_duration_seconds ()
  in
  let external_fanout_count =
    v (Otel_metric_store.metric_sse_external_fanout_duration_seconds ^ "_count") ()
  in
  let external_fanout_avg =
    if external_fanout_count > 0.0
    then external_fanout_sum /. external_fanout_count
    else 0.0
  in
  let grpc_streams = v Otel_metric_store.metric_grpc_active_streams () in
  let grpc_subscribers = v Otel_metric_store.metric_grpc_subscribers () in
  let grpc_heartbeat_sum = v Otel_metric_store.metric_grpc_heartbeat_latency () in
  let grpc_heartbeat_count = v "masc_grpc_heartbeat_latency_seconds_count" () in
  let grpc_heartbeat_avg =
    if grpc_heartbeat_count > 0.0 then grpc_heartbeat_sum /. grpc_heartbeat_count else 0.0
  in
  let grpc_events = v Otel_metric_store.metric_grpc_events_delivered () in
  let grpc_events_dropped = v Otel_metric_store.metric_grpc_events_dropped () in
  let stale_agents = v Otel_metric_store.metric_agent_stale_total () in
  let lifecycle_dispatch_rejections =
    int_of_float
      (Otel_metric_store.metric_total Keeper_metrics.(to_string LifecycleDispatchRejections))
  in
  let ws_delivery_metrics = ws_delivery_metric_names in
  let ws_sessions = int_of_float (v Otel_metric_store.metric_ws_sessions ()) in
  let grpc_configured = grpc_enabled () in
  let grpc_live = grpc_listening () in
  let grpc_reachable = grpc_live || tcp_port_reachable (grpc_port ()) in
  let ws_configured = ws_enabled () in
  let ws_live = ws_listening () in
  let ws_reachable = ws_live || tcp_port_reachable (ws_port ()) in
  let streamable_auth_policy_present =
    Env_config.Transport.http_auth_strict_env_enabled ()
  in
  let webrtc_configured = (Atomic.get webrtc_is_enabled_ref) () in
  let webrtc_pending = (Atomic.get webrtc_pending_count_ref) () in
  let webrtc_peers = (Atomic.get webrtc_peers_count_ref) () in
  let webrtc_live = (Atomic.get webrtc_live_count_ref) () in
  let webrtc_channels = (Atomic.get webrtc_channels_count_ref) () in
  let listener_mode = http_listener_mode () in
  let topology_summary = cluster_summary_json config in
  let workspace_id = workspace_id_from_config config in
  let cluster_name = Env_config_core.cluster_name () in
  (* Keep transport-health free of Workspace/PG reads so proactive refresh does not
     contend with dashboard and MCP writes on the shared backend. *)
  let recent_messages = None in
  let recent_messages_available = Option.is_some recent_messages in
  let grpc_subscribers_i = int_of_float grpc_subscribers in
  let primary_path =
    primary_path
      ~webrtc_channels
      ~grpc_subscribers:grpc_subscribers_i
      ~ws_sessions
      ~sse_sessions:sse_total
  in
  let topology_available = Option.is_some topology_summary in
  let degraded_source = "metrics_only" in
  `Assoc
    [ ( "summary"
      , `Assoc
          [ "primary_path", `String primary_path
          ; ( "queue_pressure"
            , `String
                (queue_pressure
                   ~sse_queue_max
                   ~relay_queue_depth
                   ~relay_retry_total
                   ~relay_drop_total) )
          ; "recent_messages", Json_util.int_opt_to_json recent_messages
          ; "recent_messages_available", `Bool recent_messages_available
          ; "recent_messages_source", `String degraded_source
          ; "external_fanout_targets", `Int sse_external_subscribers
          ] )
    ; ( "sse"
      , `Assoc
          [ "sessions_observer", `Int (int_of_float sse_observer)
          ; "sessions_agent_stream", `Int (int_of_float sse_agent_stream)
          ; "sessions_presence", `Int (int_of_float sse_presence)
          ; "sessions_total", `Int sse_total
          ; "external_subscribers", `Int sse_external_subscribers
          ; "broadcast_avg_seconds", `Float broadcast_avg
          ; "broadcast_count", `Int (int_of_float broadcast_count)
          ; "external_fanout_avg_seconds", `Float external_fanout_avg
          ; "external_fanout_count", `Int (int_of_float external_fanout_count)
          ; "external_fanout_sum_seconds", `Float external_fanout_sum
          ; "queue_avg_depth", `Float sse_queue_avg
          ; "queue_max_depth", `Int sse_queue_max
          ; "relay_queue_depth", `Int relay_queue_depth
          ; "relay_retry_total", `Int relay_retry_total
          ; "relay_retry_append", `Int relay_retry_append
          ; "relay_retry_broadcast", `Int relay_retry_broadcast
          ; "relay_drop_total", `Int relay_drop_total
          ; "relay_drop_queue", `Int relay_drop_queue
          ; "relay_drop_append", `Int relay_drop_append
          ; "relay_drop_broadcast", `Int relay_drop_broadcast
          ; ( "hot_sessions"
            , `List (List.map hot_session_json (Atomic.get sse_hot_sessions)) )
          ] )
    ; ( "grpc"
      , `Assoc
          [ "enabled", `Bool grpc_configured
          ; "configured", `Bool grpc_configured
          ; "listening", `Bool grpc_live
          ; "reachable", `Bool grpc_reachable
          ; "listen_status", `String (Atomic.get grpc_listen_status)
          ; "port", `Int (grpc_port ())
          ; "active_streams", `Int (int_of_float grpc_streams)
          ; "subscribers", `Int grpc_subscribers_i
          ; "heartbeat_avg_seconds", `Float grpc_heartbeat_avg
          ; "events_delivered", `Int (int_of_float grpc_events)
          ; "events_dropped", `Int (int_of_float grpc_events_dropped)
          ] )
    ; ( "websocket"
      , `Assoc
          [ "enabled", `Bool ws_configured
          ; "configured", `Bool ws_configured
          ; "listening", `Bool ws_live
          ; "reachable", `Bool ws_reachable
          ; "listen_status", `String (Atomic.get ws_listen_status)
          ; "mode", `String "standalone"
          ; "port", `Int (ws_port ())
          ; "sessions", `Int ws_sessions
          ; "relay_source", `String "sse_external_subscriber"
          ; (* Diagnostic counters for the WS delivery path.  The metric names
         are catalogued here so this surface does not take a compile-time
         dependency on any particular WS perf/observability PR.  If a
         producing PR has not registered a metric yet, [metric_value_or_zero]
         returns 0.0, which reads naturally as "nothing has happened". *)
            ( "delivery"
            , `Assoc
                [ ( "parse_cache_hits"
                  , `Int (int_of_float (v ws_delivery_metrics.parse_cache_hits ())) )
                ; ( "parse_cache_misses"
                  , `Int (int_of_float (v ws_delivery_metrics.parse_cache_misses ())) )
                ; ( "bytes_cache_hits"
                  , `Int (int_of_float (v ws_delivery_metrics.bytes_cache_hits ())) )
                ; ( "bytes_cache_misses"
                  , `Int (int_of_float (v ws_delivery_metrics.bytes_cache_misses ())) )
                ; ( "client_acks"
                  , `Int (int_of_float (v ws_delivery_metrics.client_acks ())) )
                ; ( "throttled_deliveries"
                  , `Int (int_of_float (v ws_delivery_metrics.throttled_deliveries ())) )
                ; ( "delta_payload_serializations"
                  , `Int
                      (int_of_float
                         (v ws_delivery_metrics.delta_payload_serializations ())) )
                ; (* Histogram sum + auto _count give operators enough to compute
           average buffered bytes per ack without external telemetry queries. *)
                  ( "client_buffered_bytes_sum"
                  , `Float (v ws_delivery_metrics.client_buffered_bytes ()) )
                ; ( "client_buffered_bytes_count"
                  , `Int
                      (int_of_float
                         (v ws_delivery_metrics.client_buffered_bytes_count ())) )
                ; ( "hello_latency_sum_seconds"
                  , `Float (Otel_metric_store.metric_total ws_delivery_metrics.hello_latency) )
                ; ( "hello_latency_count"
                  , `Int
                      (int_of_float
                         (Otel_metric_store.metric_total ws_delivery_metrics.hello_latency_count))
                  )
                ] )
          ] )
    ; ( "webrtc"
      , `Assoc
          [ "enabled", `Bool webrtc_configured
          ; "configured", `Bool webrtc_configured
          ; "signaling_available", `Bool webrtc_configured
          ; "signaling_mode", `String "shared_http"
          ; "pending_offers", `Int webrtc_pending
          ; "active_peers", `Int webrtc_peers
          ; "live_connections", `Int webrtc_live
          ; "connected_channels", `Int webrtc_channels
          ; ( "ice_server_count"
            , `Int (List.length ((Atomic.get webrtc_ice_servers_urls_ref) ())) )
          ] )
    ; ( "streamable_http"
      , `Assoc
          [ "endpoint", `String "/mcp"
          ; "observer_stream", `String "/mcp?sse_kind=observer"
          ; "presence_stream", `String "/events/presence"
          ; "managed_endpoint", `String "/mcp/managed"
          ; "operator_endpoint", `String "/mcp/operator"
          ; "delete_endpoint", `String "/mcp"
          ; "default_transport", `String "streamable_http"
          ; "configured", `Bool true
          ; "protocol_capable", `Bool true
          ; "auth_policy_present", `Bool streamable_auth_policy_present
          ; "supports_post", `Bool true
          ; "supports_sse_upgrade", `Bool true
          ; "supports_delete", `Bool true
          ; "listener", http_listener_json ()
          ] )
    ; ( "http2"
      , `Assoc
          [ "listener_mode", `String listener_mode
          ; "multiplex_ready", `Bool (not (String.equal listener_mode "h1_only"))
          ; "prior_knowledge_path", `String "/mcp"
          ] )
    ; ( "cluster"
      , `Assoc
          [ "cluster", `String cluster_name
          ; "workspace_id", `String workspace_id
          ; "topology_available", `Bool topology_available
          ; "topology_source", `String degraded_source
          ; "total_units", Json_util.int_opt_to_json (int_field_opt "total_units" topology_summary)
          ; ( "managed_units"
            , Json_util.int_opt_to_json (int_field_opt "managed_unit_count" topology_summary) )
          ; ( "live_agents"
            , Json_util.int_opt_to_json (int_field_opt "live_agent_count" topology_summary) )
          ; ( "active_operations"
            , Json_util.int_opt_to_json (int_field_opt "active_operation_count" topology_summary) )
          ; ( "stale_units"
            , Json_util.int_opt_to_json (int_field_opt "stale_unit_count" topology_summary) )
          ] )
    ; ( "agent_health"
      , `Assoc
          [ "stale_total", `Int (int_of_float stale_agents)
          ; "lifecycle_dispatch_rejections_total", `Int lifecycle_dispatch_rejections
          ] )
    ; "generated_at", `String (Masc_domain.now_iso ())
    ]
;;
