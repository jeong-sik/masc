(** Transport Observability Metrics for 50-agent monitoring.

    Collects SSE, gRPC, and agent-health transport metrics in
    Otel_metric_store text format via the existing Otel_metric_store module.

    Metric naming follows Otel_metric_store conventions:
    - masc_sse_* for SSE transport
    - masc_grpc_* for gRPC transport
    - masc_agent_heartbeat_* for agent liveness *)

(** {1 SSE Metrics} *)

type sse_session_kind =
  | Observer
  | Agent_stream
  | Presence

let sse_session_kind_to_string = function
  | Observer -> "observer"
  | Agent_stream -> "agent_stream"
  | Presence -> "presence"
;;

type hot_queue_session =
  { session_id : string
  ; kind : sse_session_kind
  ; queue_depth : int
  ; last_event_id : int
  ; idle_seconds : float
  }

let sse_hot_sessions : hot_queue_session list Atomic.t = Atomic.make []

let sse_session_kinds = [ Observer; Agent_stream; Presence ]
let relay_retry_stages = [ "append"; "broadcast" ]
let relay_drop_stages = [ "queue"; "append"; "broadcast" ]

let () =
  List.iter
    (fun kind ->
      let kind = sse_session_kind_to_string kind in
      Otel_metric_store.register_gauge
        ~name:Otel_metric_store.metric_sse_sessions
        ~help:Otel_metric_store.metric_sse_sessions
        ~labels:[ "kind", kind ]
        ())
    sse_session_kinds;
  List.iter
    (fun stage ->
      Otel_metric_store.register_counter
        ~name:Otel_metric_store.metric_agent_core_sse_relay_retries
        ~help:Otel_metric_store.metric_agent_core_sse_relay_retries
        ~labels:[ "stage", stage ]
        ())
    relay_retry_stages;
  List.iter
    (fun stage ->
      Otel_metric_store.register_counter
        ~name:Otel_metric_store.metric_agent_core_sse_relay_drops
        ~help:Otel_metric_store.metric_agent_core_sse_relay_drops
        ~labels:[ "stage", stage ]
        ())
    relay_drop_stages
;;

let set_sse_sessions ~kind count =
  let kind = sse_session_kind_to_string kind in
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
let inc_sse_broadcast_skipped_no_observer () =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_sse_broadcast_skipped_no_observer ()
;;

let inc_external_subscriber_callback_failure () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_sse_external_subscriber_callback_failures ()
;;

let observe_external_subscriber_fanout_duration seconds =
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_sse_external_fanout_duration_seconds
    (max 0.0 seconds)
;;

(* P2 silent-failure fix (transport scan):
   The AGENT_CORE relay drop-marker is the operator-visible signal that an
   AGENT_CORE event was dropped after exhausting retries.  If the drop marker
   broadcast itself fails, operators get no
   indication a drop happened.  Distinct from inc_broadcast_failure
   so the recovery-path failure rate is isolated from normal broadcast
   failures. *)
let inc_relay_drop_marker_failure () =
  Otel_metric_store.inc_counter Otel_metric_store.metric_agent_core_sse_relay_drop_marker_failures ()
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

(* Silent-failure fix (2026-08-18 live finding): every external MCP
   credential had gone stale after a token rotation and every client
   request died at the auth boundary with a client-only 401 — zero
   server-side trace, so mcp_transport_sessions.json staying empty was
   indistinguishable from "no client ever tried".  [reason] carries the
   typed [auth_error_code] ("invalid_token", "missing_token", ...), not
   free-form message text, so the label set stays bounded. *)
let inc_mcp_auth_reject ~endpoint ~reason =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_mcp_auth_rejects
    ~labels:[ "endpoint", endpoint; "reason", reason ]
    ()
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
let ws_same_origin_runtime_ready : bool Atomic.t = Atomic.make false

(** Explanatory status for why a transport is or is not listening.
    Valid values: ["not_started"], ["disabled"], ["listening"],
    ["bind_failed"], ["stopped"]. *)
let grpc_listen_status : string Atomic.t = Atomic.make "not_started"

let set_grpc_runtime_listening listening = Atomic.set grpc_runtime_listening listening
let set_ws_same_origin_runtime_ready ready =
  Atomic.set ws_same_origin_runtime_ready ready

let set_grpc_listen_status status = Atomic.set grpc_listen_status status
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


let http_listener_mode () =
  Env_config.Transport.effective_h2_mode ()
;;

let primary_path ~grpc_subscribers ~ws_sessions ~sse_sessions =
  if grpc_subscribers > 0
  then "grpc_subscribe"
  else if ws_sessions > 0
  then "websocket"
  else if sse_sessions > 0
  then "sse"
  else "streamable_http"
;;

(* [relay_retry_total] and [relay_drop_total] used to feed this. They are
   process-lifetime counters with no decrement anywhere, so one relay drop
   pinned the reading to "high" until the next restart and the queue depths
   below could no longer move it. The totals travel beside this field in the
   same payload, where a number that only grows belongs (#27652). *)
let queue_pressure_high_depth = 32
let queue_pressure_watch_depth = 8

let queue_pressure ~sse_queue_max ~relay_queue_depth =
  let max_queue_depth = max sse_queue_max relay_queue_depth in
  if max_queue_depth >= queue_pressure_high_depth
  then "high"
  else if max_queue_depth >= queue_pressure_watch_depth
  then "watch"
  else "steady"
;;

let ws_enabled () = Env_config.Transport.ws_enabled ()
let ws_same_origin_ready () =
  ws_enabled () && Atomic.get ws_same_origin_runtime_ready

let hot_session_json (session : hot_queue_session) =
  `Assoc
    [ "session_id", `String session.session_id
    ; "kind", `String (sse_session_kind_to_string session.kind)
    ; "queue_depth", `Int session.queue_depth
    ; "last_event_id", `Int session.last_event_id
    ; "idle_seconds", `Float session.idle_seconds
    ]
;;

let required_metric_value name ?(labels = []) () =
  match Otel_metric_store.get_metric_value name ~labels () with
  | Some value -> value
  | None ->
    invalid_arg
      (Printf.sprintf
         "transport health metric cell is not registered: %s labels=%s"
         name
         (labels
          |> List.map (fun (key, value) -> key ^ "=" ^ value)
          |> String.concat ","))
;;

let transport_health_json () =
  let v = required_metric_value in
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
    int_of_float (v Otel_metric_store.metric_agent_core_sse_relay_queue_depth ())
  in
  let relay_retry_append =
    int_of_float
      (v Otel_metric_store.metric_agent_core_sse_relay_retries ~labels:[ "stage", "append" ] ())
  in
  let relay_retry_broadcast =
    int_of_float
      (v Otel_metric_store.metric_agent_core_sse_relay_retries ~labels:[ "stage", "broadcast" ] ())
  in
  let relay_retry_total =
    int_of_float (Otel_metric_store.metric_total Otel_metric_store.metric_agent_core_sse_relay_retries)
  in
  let relay_drop_queue =
    int_of_float (v Otel_metric_store.metric_agent_core_sse_relay_drops ~labels:[ "stage", "queue" ] ())
  in
  let relay_drop_append =
    int_of_float
      (v Otel_metric_store.metric_agent_core_sse_relay_drops ~labels:[ "stage", "append" ] ())
  in
  let relay_drop_broadcast =
    int_of_float
      (v Otel_metric_store.metric_agent_core_sse_relay_drops ~labels:[ "stage", "broadcast" ] ())
  in
  let relay_drop_total =
    int_of_float (Otel_metric_store.metric_total Otel_metric_store.metric_agent_core_sse_relay_drops)
  in
  let broadcast_sum = v Otel_metric_store.metric_sse_broadcast_duration () in
  let broadcast_count = v Otel_metric_store.metric_sse_broadcast_duration_count () in
  let broadcast_avg =
    if broadcast_count > 0.0 then broadcast_sum /. broadcast_count else 0.0
  in
  let grpc_streams = v Otel_metric_store.metric_grpc_active_streams () in
  let grpc_subscribers = v Otel_metric_store.metric_grpc_subscribers () in
  let grpc_heartbeat_sum = v Otel_metric_store.metric_grpc_heartbeat_latency () in
  let grpc_heartbeat_count = v Otel_metric_store.metric_grpc_heartbeat_latency_count () in
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
  let ws_sessions = int_of_float (v Otel_metric_store.metric_ws_sessions ()) in
  let grpc_configured = grpc_enabled () in
  let grpc_live = grpc_listening () in
  let ws_configured = ws_enabled () in
  let ws_live = ws_same_origin_ready () in
  let listener_mode = http_listener_mode () in
  let listener_mode_label =
    Env_config.Transport.h2_mode_to_string listener_mode
  in
  let multiplex_ready =
    match listener_mode with
    | Env_config.Transport.H1_only -> false
    | Env_config.Transport.Auto | Env_config.Transport.H2_only -> true
  in
  let grpc_subscribers_i = int_of_float grpc_subscribers in
  let primary_path =
    primary_path
      ~grpc_subscribers:grpc_subscribers_i
      ~ws_sessions
      ~sse_sessions:sse_total
  in
  `Assoc
    [ ( "summary"
      , `Assoc
          [ "primary_path", `String primary_path
          ; ( "queue_pressure"
            , `String
                (queue_pressure ~sse_queue_max ~relay_queue_depth) )
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
          [ "configured", `Bool grpc_configured
          ; "listening", `Bool grpc_live
          ; "port", `Int (grpc_port ())
          ; "active_streams", `Int (int_of_float grpc_streams)
          ; "subscribers", `Int grpc_subscribers_i
          ; "heartbeat_avg_seconds", `Float grpc_heartbeat_avg
          ; "events_delivered", `Int (int_of_float grpc_events)
          ; "events_dropped", `Int (int_of_float grpc_events_dropped)
          ] )
    ; ( "websocket"
      , `Assoc
          [ "configured", `Bool ws_configured
          ; "listening", `Bool ws_live
          ; (* Sessions ride the HTTP listener's same-origin /ws upgrade,
               so there is no WebSocket-specific port to report. *)
            "mode", `String "same_origin"
          ; "sessions", `Int ws_sessions
          ; "relay_source", `String "sse_external_subscriber"
          ; ( "delivery"
            , `Assoc
                [ ( "bytes_cache_hits"
                  , `Int
                      (int_of_float
                         (v Otel_metric_store.metric_ws_bytes_cache_hits ())) )
                ; ( "bytes_cache_misses"
                  , `Int
                      (int_of_float
                         (v Otel_metric_store.metric_ws_bytes_cache_misses ())) )
                ; ( "client_acks"
                  , `Int (int_of_float (v Otel_metric_store.metric_ws_client_acks ())) )
                ; ( "throttled_deliveries"
                  , `Int
                      (int_of_float
                         (v Otel_metric_store.metric_ws_throttled_deliveries ())) )
                ; ( "client_buffered_bytes_sum"
                  , `Float (v Otel_metric_store.metric_ws_client_buffered_bytes ()) )
                ; ( "client_buffered_bytes_count"
                  , `Int
                      (int_of_float
                         (v Otel_metric_store.metric_ws_client_buffered_bytes_count ())) )
                ] )
          ] )
    ; ( "streamable_http"
      , `Assoc
          [ "endpoint", `String "/mcp"
          ; "observer_stream", `String "/mcp?sse_kind=observer"
          ; "presence_stream", `String "/events/presence"
          ; "supports_post", `Bool true
          ; "supports_sse_upgrade", `Bool true
          ; ( "auth_rejects_total"
            , `Int
                (int_of_float
                   (Otel_metric_store.metric_total Otel_metric_store.metric_mcp_auth_rejects)) )
          ] )
    ; ( "http2"
      , `Assoc
          [ "listener_mode", `String listener_mode_label
          ; "multiplex_ready", `Bool multiplex_ready
          ] )
    ; ( "agent_health"
      , `Assoc
          [ "stale_total", `Int (int_of_float stale_agents)
          ; "lifecycle_dispatch_rejections_total", `Int lifecycle_dispatch_rejections
          ] )
    ; "generated_at", `String (Masc_domain.now_iso ())
    ]
;;
