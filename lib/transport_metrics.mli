(** Transport_metrics — Prometheus observability for SSE, gRPC,
    WebSocket transports + agent heartbeat liveness.

    Metric naming follows Prometheus conventions:

    - [masc_sse_*] for SSE transport
    - [masc_grpc_*] for gRPC transport
    - [masc_ws_*] for WebSocket transport
    - [masc_agent_heartbeat_*] for agent liveness

    Internal: ~22 helpers stay private — \[sse_hot_sessions]
    (Atomic.t state cell mutated by {!set_sse_queue_snapshot}),
    \[grpc_runtime_listening] / \[ws_runtime_listening] (bool
    Atomic.t cells mutated by the [set_*_runtime_listening]
    functions), [set_sse_queue_depth] (per-session gauge,
    high-cardinality so kept internal), [grpc_enabled] /
    [grpc_port] / [ws_port] (env-derived), [set_agent_heartbeat_age]
    / [inc_agent_stale] (per-agent labels, internal-only), the
    JSON helpers (\[assoc_field], [int_field], [int_field_opt],
    [int_option_json], [room_id_from_config], [cluster_summary_json]),
    [http_listener_mode], [primary_path], [queue_pressure],
    [tcp_port_reachable], [hot_session_json], the
    [ws_delivery_metric_names] data table + its type.  All
    consumed only inside {!transport_health_json}'s pipeline. *)

(** {1 SSE hot-queue snapshot} *)

type hot_queue_session = {
  session_id : string;
  kind : string;
  queue_depth : int;
  last_event_id : int;
  idle_seconds : float;
}
(** Per-session snapshot recorded into the SSE hot-queue
    Atomic ref by {!set_sse_queue_snapshot}.  Concrete record
    because callers construct + destructure it (notably the
    transport-health JSON renderer + tests). *)

(** {1 SSE metrics} *)

val set_sse_sessions : kind:string -> int -> unit
(** [set_sse_sessions ~kind count] sets the [masc_sse_sessions]
    gauge labelled with [kind] (typically ["observer"] /
    ["coordinator"]). *)

val observe_broadcast_duration :
  ?target:string -> float -> unit
(** [observe_broadcast_duration ?target seconds] records a
    broadcast histogram observation AND increments
    [masc_sse_broadcast_events_total].  [?target] labels both
    the histogram and the events counter so failures pair with
    successes for health calculation. *)

val inc_broadcast_failure : ?target:string -> unit -> unit
(** [inc_broadcast_failure ?target ()] increments
    [masc_sse_broadcast_failures_total].  Pinned at the contract
    seam: target label MUST match
    {!observe_broadcast_duration} so operators can compute
    [rate(failures[5m]) / (rate(events[5m]) + rate(failures[5m]))]
    — drift would break P1 silent-failure detection (transport
    scan). *)

val inc_external_subscriber_callback_failure : unit -> unit
(** Increments
    [masc_sse_external_subscriber_callback_failures_total].
    Counter is intentionally unlabelled because subscriber id is
    high-cardinality (gRPC stream id); operators correlate via
    the warn log line. *)

val inc_relay_drop_marker_failure : unit -> unit
(** Increments [masc_oas_sse_relay_drop_marker_failures_total].
    Distinct from {!inc_broadcast_failure} so the
    recovery-path failure rate is isolated from normal broadcast
    failures (P2 silent-failure fix, transport scan). *)

val set_sse_queue_snapshot :
  avg_depth:float ->
  max_depth:int ->
  hot_sessions:hot_queue_session list ->
  unit
(** [set_sse_queue_snapshot ~avg_depth ~max_depth ~hot_sessions]
    sets [masc_sse_queue_depth_avg] + [masc_sse_queue_depth_max]
    gauges and records the hot-session list into the internal
    Atomic ref for {!transport_health_json}. *)

val set_sse_external_subscribers : int -> unit
(** Sets [masc_sse_external_subscribers] gauge. *)

(** {1 gRPC metrics} *)

val set_grpc_active_streams : int -> unit
(** Sets [masc_grpc_active_streams] gauge. *)

val observe_grpc_heartbeat_latency : float -> unit
(** Records a [masc_grpc_heartbeat_latency] histogram observation. *)

val set_grpc_subscribers : int -> unit
(** Sets [masc_grpc_subscribers] gauge. *)

val inc_grpc_events_delivered : ?delta:int -> unit -> unit
(** [inc_grpc_events_delivered ?(delta=1) ()] increments
    [masc_grpc_events_delivered_total] by [delta]. *)

val inc_grpc_events_dropped : unit -> unit
(** Increments [masc_grpc_events_dropped_total]. *)

val inc_grpc_bytes_sent : bytes:int -> unit
(** [inc_grpc_bytes_sent ~bytes] increments
    [masc_grpc_bytes_sent_total] by [bytes].  No-op when
    [bytes <= 0]. *)

val inc_grpc_backlog_replay_lines_scanned :
  ?delta:int -> unit -> unit
(** [inc_grpc_backlog_replay_lines_scanned ?(delta=1) ()]
    increments [masc_grpc_backlog_replay_lines_scanned_total].
    No-op when [delta <= 0]. *)

val inc_grpc_backlog_replay_events_replayed :
  ?delta:int -> unit -> unit
(** [inc_grpc_backlog_replay_events_replayed ?(delta=1) ()]
    increments [masc_grpc_backlog_replay_events_replayed_total].
    No-op when [delta <= 0]. *)

(** {1 WebSocket metrics} *)

val set_ws_sessions : int -> unit
(** Sets [masc_ws_sessions] gauge. *)

val inc_ws_parse_cache_hit : unit -> unit
(** Increments [masc_ws_parse_cache_hits_total]. *)

val inc_ws_parse_cache_miss : unit -> unit
(** Increments [masc_ws_parse_cache_misses_total]. *)

val inc_ws_bytes_cache_hit : unit -> unit
(** Increments [masc_ws_bytes_cache_hits_total]. *)

val inc_ws_bytes_cache_miss : unit -> unit
(** Increments [masc_ws_bytes_cache_misses_total]. *)

val observe_ws_client_buffered_bytes : int -> unit
(** [observe_ws_client_buffered_bytes n] records
    [masc_ws_client_buffered_bytes] (clamped to [max 0 n]) AND
    increments [masc_ws_client_acks_total].  Paired observation
    so the histogram count + ack counter cross-check. *)

val inc_ws_throttled_delivery : unit -> unit
(** Increments [masc_ws_throttled_deliveries_total]. *)

val inc_ws_slice_fanout_skipped : unit -> unit
(** Increments [masc_ws_slice_fanout_skipped]. *)

val inc_ws_bytes_sent : bytes:int -> unit
(** [inc_ws_bytes_sent ~bytes] increments
    [masc_ws_bytes_sent_total] by [bytes].  No-op when
    [bytes <= 0]. *)

val inc_ws_delta_built : unit -> unit
(** Increments [masc_ws_delta_built]. *)

(** {1 Transport listen state} *)

val grpc_listen_status : string Atomic.t
(** Explanatory status for why gRPC is or is not listening.
    Valid values: ["not_started"], ["disabled"], ["listening"],
    ["bind_failed"], ["stopped"].  Pinned literal set —
    operators read this Atomic directly for status display.
    Drift would break dashboard tooltips. *)

val ws_listen_status : string Atomic.t
(** WebSocket variant of {!grpc_listen_status}. *)

val set_grpc_runtime_listening : bool -> unit
(** [set_grpc_runtime_listening listening] flips the gRPC
    listen-state Atomic.  Combined with
    {!Env_config.Transport.grpc_enabled} via {!grpc_listening}. *)

val set_ws_runtime_listening : bool -> unit
(** WebSocket variant of {!set_grpc_runtime_listening}. *)

val set_grpc_listen_status : string -> unit
(** [set_grpc_listen_status s] writes [s] into
    {!grpc_listen_status}.  Caller is responsible for using a
    pinned status literal — drift to free-form strings would
    break dashboard parsing. *)

val set_ws_listen_status : string -> unit
(** WebSocket variant of {!set_grpc_listen_status}. *)

val grpc_listening : unit -> bool
(** [grpc_listening ()] is
    [grpc_enabled () && Atomic.get grpc_runtime_listening] —
    the AND of the env-config flag and the runtime listen
    state. *)

val ws_enabled : unit -> bool
(** [ws_enabled ()] is [Env_config.Transport.ws_enabled ()].
    Read every call — env mutation between calls takes effect. *)

val ws_listening : unit -> bool
(** [ws_listening ()] is
    [ws_enabled () && Atomic.get ws_runtime_listening] —
    AND of env-config and runtime state. *)

(** {1 Agent health gauges (test-visible)} *)

val set_agent_heartbeat_age :
  agent_name:string -> float -> unit
(** [set_agent_heartbeat_age ~agent_name age_seconds] writes
    [age_seconds] to the [masc_agent_heartbeat_age_seconds] gauge
    labelled by [agent_name].  Pinned for behaviour-tests under
    {!test/test_transport_metrics}. *)

val inc_agent_stale : unit -> unit
(** [inc_agent_stale ()] increments the [masc_agent_stale_total]
    counter.  Pinned for behaviour-tests under
    {!test/test_transport_metrics}. *)

(** {1 Transport health snapshot} *)

val transport_health_json : config:Coord.config -> Yojson.Safe.t
(** [transport_health_json ~config] returns a JSON object with
    SSE / gRPC / WebSocket / agent-health metric values plus
    derived fields ([primary_path], [queue_pressure],
    [http_listener_mode]).  Reads metric values via
    [Prometheus.metric_value_or_zero] — never raises on missing
    metrics.  [~config] is currently used for room-id
    derivation; [cluster_summary_json] is intentionally [None]
    to keep transport health metrics-only (no command-plane I/O). *)
