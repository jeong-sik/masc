(** Transport_metrics — Otel_metric_store observability for SSE, gRPC,
    WebSocket transports + agent heartbeat liveness.

    Metric naming follows Otel_metric_store conventions:

    - [masc_sse_*] for SSE transport
    - [masc_grpc_*] for gRPC transport
    - [masc_ws_*] for WebSocket transport
    - [masc_agent_heartbeat_*] for agent liveness

    Internal state cells and JSON projection helpers stay private; the typed
    mutation and snapshot functions below are the public boundary. *)

(** {1 SSE hot-queue snapshot} *)

type sse_session_kind =
  | Observer
  | Agent_stream
  | Presence

(** Per-session snapshot recorded into the SSE hot-queue
    Atomic ref by {!set_sse_queue_snapshot}.  Concrete record
    because callers construct + destructure it (notably the
    transport-health JSON renderer + tests). *)
type hot_queue_session =
  { session_id : string
  ; kind : sse_session_kind
  ; queue_depth : int
  ; last_event_id : int
  ; idle_seconds : float
  }

(** {1 SSE metrics} *)

(** [set_sse_sessions ~kind count] sets the [masc_sse_sessions]
    gauge labelled with the canonical session kind. *)
val set_sse_sessions : kind:sse_session_kind -> int -> unit

(** [observe_broadcast_duration ?target seconds] records a
    broadcast histogram observation AND increments
    [masc_sse_broadcast_events_total].  [?target] labels both
    the histogram and the events counter so failures pair with
    successes for health calculation. *)
val observe_broadcast_duration : ?target:string -> float -> unit

(** [inc_broadcast_failure ?target ()] increments
    [masc_sse_broadcast_failures_total].  Pinned at the contract
    seam: target label MUST match
    {!observe_broadcast_duration} so operators can compute
    [rate(failures[5m]) / (rate(events[5m]) + rate(failures[5m]))]
    — drift would break P1 silent-failure detection (transport
    scan). *)
val inc_broadcast_failure : ?target:string -> unit -> unit

val inc_sse_broadcast_skipped_no_observer : unit -> unit
(** A broadcast was skipped because nothing could observe it: bufferless, no
    external subscriber, and no session of the target kind. Non-zero here is
    the amount of serialization the fanout mutex no longer performs. *)

(** Increments
    [masc_sse_external_subscriber_callback_failures_total].
    Counter is intentionally unlabelled because subscriber id is
    high-cardinality (gRPC stream id); operators correlate via
    the warn log line. *)
val inc_external_subscriber_callback_failure : unit -> unit

(** Records the synchronous duration of
    [Sse.notify_external_subscribers] for one durable broadcast.  This is the
    Wave-A main-domain occupancy probe for the external subscriber fan-out
    section that delivers dashboard WebSocket deltas. *)
val observe_external_subscriber_fanout_duration : float -> unit

(** Increments [masc_agent_core_sse_relay_drop_marker_failures_total].
    Distinct from {!inc_broadcast_failure} so the
    recovery-path failure rate is isolated from normal broadcast
    failures (P2 silent-failure fix, transport scan). *)
val inc_relay_drop_marker_failure : unit -> unit

(** [set_sse_queue_snapshot ~avg_depth ~max_depth ~hot_sessions]
    sets [masc_sse_queue_depth_avg] + [masc_sse_queue_depth_max]
    gauges and records the hot-session list into the internal
    Atomic ref for {!transport_health_json}. *)
val set_sse_queue_snapshot
  :  avg_depth:float
  -> max_depth:int
  -> hot_sessions:hot_queue_session list
  -> unit

(** Sets [masc_sse_external_subscribers] gauge. *)
val set_sse_external_subscribers : int -> unit

(** Increments [masc_sse_client_evictions_total] when {!Sse.register}
    drops the oldest client because [max_clients] was reached.  Paired
    with the [Evicting oldest client] log line so operators can see
    eviction storms in metrics. *)
val inc_sse_client_evicted : unit -> unit

(** Increments [masc_sse_idle_evictions_total] for each session
    {!Sse.cleanup_stale} reaps for being idle past [max_age_s].
    Paired with the [idle evict] log line so the idle-reaper rate
    is observable without log scraping. *)
val inc_sse_idle_evicted : unit -> unit

(** [inc_sse_reject ~reason] increments [masc_sse_rejects_total]
    labelled with [reason] when the SSE connect storm guard
    rejects a request (HTTP 429). [reason] mirrors the JSON body
    field — currently ["session_cooldown"] or ["window_limit"].
    Paired with the existing rate-limit response so operators
    can rate-alert on storm conditions instead of grepping access
    logs. *)
val inc_sse_reject : reason:string -> unit

(** [inc_mcp_auth_reject ~endpoint ~reason] increments
    [masc_mcp_auth_rejects_total{endpoint,reason}] when an MCP
    transport request is rejected at the auth boundary (HTTP 401).
    [endpoint] is the fixed route label (e.g. ["POST /mcp"]),
    [reason] the typed [auth_error_code] ("invalid_token",
    "missing_token", ...) — never free-form message text, so the
    label set stays bounded.  Paired with the [Log.Auth] reject
    event emitted at the same boundary; before this pair a stale
    bearer produced only a client-visible 401 (2026-08-18 live
    finding: all external MCP credentials stale, zero trace). *)
val inc_mcp_auth_reject : endpoint:string -> reason:string -> unit

(** Increments [masc_sse_reconnects_total] whenever an SSE client
    arrives with a [Last-Event-Id] header, i.e. is asking the
    server to replay events from a prior connection.  Distinct
    from a fresh connect — useful for rate-alerting on disconnect
    flapping (network instability, client buggy retry loops). *)
val inc_sse_reconnect : unit -> unit

(** {1 gRPC metrics} *)

(** Sets [masc_grpc_active_streams] gauge. *)
val set_grpc_active_streams : int -> unit

(** Records a [masc_grpc_heartbeat_latency] histogram observation. *)
val observe_grpc_heartbeat_latency : float -> unit

(** Sets [masc_grpc_subscribers] gauge. *)
val set_grpc_subscribers : int -> unit

(** [inc_grpc_events_delivered ?(delta=1) ()] increments
    [masc_grpc_events_delivered_total] by [delta]. *)
val inc_grpc_events_delivered : ?delta:int -> unit -> unit

(** Increments [masc_grpc_events_dropped_total]. *)
val inc_grpc_events_dropped : unit -> unit

(** [inc_grpc_bytes_sent ~bytes] increments
    [masc_grpc_bytes_sent_total] by [bytes].  No-op when
    [bytes <= 0]. *)
val inc_grpc_bytes_sent : bytes:int -> unit

(** {1 Primary HTTP listener state} *)

type http_protocol =
  | H1
  | H2

type http_rate_limit_scope =
  | Client_ip
  | Agent
  | Sse_connection

(** Records one HTTP 429 response at the transport response boundary.  Both
    labels come from closed sums, so the metric cardinality is fixed. *)
val record_http_rate_limit_response
  :  protocol:http_protocol
  -> scope:http_rate_limit_scope
  -> unit

(** Marks the primary HTTP accept loop as listening.  [mode] is one of
    ["h1"], ["h2"], or ["auto"]. *)
val record_http_listener_started : mode:string -> unit

(** Marks the primary HTTP accept loop as stopped during shutdown. *)
val record_http_listener_stopped : mode:string -> unit

(** Records one accepted TCP connection and increments the active
    connection gauge. *)
val record_http_accept : mode:string -> unit

(** Records release of one accepted TCP connection. *)
val record_http_connection_closed : mode:string -> unit

(** Records an accept-loop error without using the error text as a
    metric label. *)
val record_http_accept_error : mode:string -> error:string -> unit

(** Records the wall-clock time [Eio.Net.accept] took for a single
    connection.  Observes into [masc_http_accept_latency_seconds]
    histogram (self-registered on first call). *)
val record_http_accept_latency : mode:string -> float -> unit

(** Snapshot of primary HTTP accept-loop status and emitted HTTP 429 counters
    for [/health] and dashboard transport health. *)
val http_listener_json : ?now:float -> unit -> Yojson.Safe.t

(** {1 WebSocket metrics} *)

(** Sets [masc_ws_sessions] gauge. *)
val set_ws_sessions : int -> unit


(** Increments [masc_ws_bytes_cache_hits_total]. *)
val inc_ws_bytes_cache_hit : unit -> unit

(** Increments [masc_ws_bytes_cache_misses_total]. *)
val inc_ws_bytes_cache_miss : unit -> unit

(** Records [dashboard/hello] processing latency in seconds.
    [success] is encoded as bounded [outcome=success|error]. *)
val observe_ws_dashboard_hello_latency : success:bool -> float -> unit

(** [observe_ws_client_buffered_bytes n] records
    [masc_ws_client_buffered_bytes] (clamped to [max 0 n]) AND
    increments [masc_ws_client_acks_total].  Paired observation
    so the histogram count + ack counter cross-check. *)
val observe_ws_client_buffered_bytes : int -> unit

(** Increments [masc_ws_throttled_deliveries_total]. *)
val inc_ws_throttled_delivery : unit -> unit

(** Increments [masc_ws_slice_fanout_skipped]. *)
val inc_ws_slice_fanout_skipped : unit -> unit

(** [inc_ws_bytes_sent ~bytes] increments
    [masc_ws_bytes_sent_total] by [bytes].  No-op when
    [bytes <= 0]. *)
val inc_ws_bytes_sent : bytes:int -> unit

(** [observe_ws_message_bytes_sent n] records [n] (clamped to
    [max 0 n]) into [masc_ws_message_bytes{direction="send"}].
    Paired with {!inc_ws_bytes_sent}: counter for total volume,
    histogram for per-message distribution. *)
val observe_ws_message_bytes_sent : int -> unit

(** Increments [masc_ws_delta_built]. *)
val inc_ws_delta_built : unit -> unit

(** Increments [masc_ws_delta_payload_serializations_total] once when a
    broadcast's shared dashboard/delta payload frame is serialized.  This is
    the Wave-A proof counter for keeping payload serialization independent of
    subscribed WS session count. *)
val inc_ws_delta_payload_serialization : unit -> unit

(** {1 Transport listen state} *)

(** Explanatory status for why gRPC is or is not listening.
    Valid values: ["not_started"], ["disabled"], ["listening"],
    ["bind_failed"], ["stopped"].  Pinned literal set —
    operators read this Atomic directly for status display.
    Drift would break dashboard tooltips. *)
val grpc_listen_status : string Atomic.t


(** [set_grpc_runtime_listening listening] flips the gRPC
    listen-state Atomic.  Combined with
    {!Env_config.Transport.grpc_enabled} via {!grpc_listening}. *)
val set_grpc_runtime_listening : bool -> unit


(** [set_ws_same_origin_runtime_ready ready] flips the same-origin [/ws]
    upgrade readiness Atomic.  This is separate from the HTTP listener being
    open: early bootstrap can accept HTTP requests before the WebSocket MCP
    dispatcher is installed. *)
val set_ws_same_origin_runtime_ready : bool -> unit

(** [set_grpc_listen_status s] writes [s] into
    {!grpc_listen_status}.  Caller is responsible for using a
    pinned status literal — drift to free-form strings would
    break dashboard parsing. *)
val set_grpc_listen_status : string -> unit


(** [grpc_listening ()] is
    [grpc_enabled () && Atomic.get grpc_runtime_listening] —
    the AND of the env-config flag and the runtime listen
    state. *)
val grpc_listening : unit -> bool

(** [ws_enabled ()] is [Env_config.Transport.ws_enabled ()].
    Read every call — env mutation between calls takes effect. *)
val ws_enabled : unit -> bool


(** [ws_same_origin_ready ()] is [ws_enabled ()] AND the runtime readiness bit
    set after the inbound WebSocket dispatcher is installed. *)
val ws_same_origin_ready : unit -> bool

(** {1 Agent health gauges (test-visible)} *)

(** [set_agent_heartbeat_age ~agent_name age_seconds] writes
    [age_seconds] to the [masc_agent_heartbeat_age_seconds] gauge
    labelled by [agent_name].  Pinned for behaviour-tests under
    {!test/test_transport_metrics}. *)
val set_agent_heartbeat_age : agent_name:string -> float -> unit

(** [inc_agent_stale ()] increments the [masc_agent_stale_total]
    counter.  Pinned for behaviour-tests under
    {!test/test_transport_metrics}. *)
val inc_agent_stale : unit -> unit

(** {1 Transport health snapshot} *)

(** Which transport carries the operator's stream right now. Closed so a
    reader lands on one of the four values this module can publish; a spelling
    it does not know is a decode failure rather than a word rendered as if it
    named a path (#27652). *)
type primary_path_kind =
  | Grpc_subscribe
  | Websocket
  | Sse
  | Streamable_http

val primary_path_kind_to_string : primary_path_kind -> string

val primary_path_kind_of_string : string -> primary_path_kind option
(** [None] when the word is not one this module publishes. *)

(** How full the deepest outbound queue is. Read from current depths, not from
    lifetime totals: a counter that only grows pinned this to [High] until the
    next restart (#27652). *)
type queue_pressure_kind =
  | Steady
  | Watch
  | High

val queue_pressure_kind_to_string : queue_pressure_kind -> string

val queue_pressure_kind_of_string : string -> queue_pressure_kind option
(** [None] when the word is not one this module publishes. *)


(** [transport_health_json ()] returns a JSON object with
    SSE / gRPC / WebSocket / agent-health metric values plus
    derived fields ([primary_path], [queue_pressure],
    [http_listener_mode]).  Reads metric values via
    [Otel_metric_store.required_metric_value] and performs no Workspace I/O. *)
val transport_health_json : unit -> Yojson.Safe.t
