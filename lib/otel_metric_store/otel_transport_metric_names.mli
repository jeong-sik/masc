(** Transport, websocket, gRPC, HTTP, dashboard, and cache metric-name
    constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

val metric_sse_sessions : string
val metric_sse_broadcast_duration : string
val metric_sse_broadcast_events : string
val metric_sse_broadcast_failures : string
val metric_sse_external_subscriber_callback_failures : string
val metric_sse_external_fanout_duration_seconds : string
val metric_oas_sse_relay_drop_marker_failures : string
val metric_sse_stream_queue_depth : string
val metric_sse_queue_depth_avg : string
val metric_sse_queue_depth_max : string
val metric_sse_external_subscribers : string
val metric_sse_client_evictions : string
val metric_workspace_broadcast_duration : string
val metric_file_lock_retries : string
val metric_file_lock_acquire_seconds : string
val metric_grpc_active_streams : string
val metric_grpc_heartbeat_latency : string
val metric_grpc_subscribers : string
val metric_grpc_events_delivered : string
val metric_grpc_events_dropped : string
val metric_ws_sessions : string
val metric_ws_parse_cache_hits : string
val metric_ws_parse_cache_misses : string
val metric_ws_bytes_cache_hits : string
val metric_ws_bytes_cache_misses : string

(** Counter of WebSocket transport incoming-frame JSON parse failures.
    Frame is dropped (parse_sse_dashboard_event returns None) but
    operators now have a counter + warn log.
    Labels: [error_kind = yojson_parse_error | other]. Iter 28. *)
val metric_server_mcp_ws_frame_json_parse_failures : string

(** Counter of sidecar HTTP route [schema_field_types] JSON parse
    failures. Previously the catch-all returned [] silently, allowing
    callers (e.g. [coerce_value] in TOML sidecar handlers) to proceed
    with zero type information - a silent type-validation bypass on
    malformed schema JSON. Behavior is preserved (still returns []);
    operators now get a counter + warn log to distinguish
    "schema missing" from "schema present but malformed".
    Labels: [error_kind = json_parse_error | other]. Iter 31. *)
val metric_sidecar_schema_field_types_json_parse_failures : string

(** Counter of sidecar HTTP route [schema_field_types] failures before the
    legacy list facade returns [[]]. Covers schema fetch failures and malformed
    schema JSON with a bounded error vocabulary.
    Labels: [error_kind = fetch_schema_error | json_parse_error | other]. *)
val metric_sidecar_schema_field_types_failures : string

(** Histogram of dashboard/hello JSON-RPC processing latency in seconds.
    Labels: [outcome = success | error]. *)
val metric_ws_dashboard_hello_latency_seconds : string

(** Discord gateway events emitted from the in-process WSS client.
    Labels: [event], [route]. *)
val metric_discord_gateway_events : string

(** Discord gateway close effects interpreted by the WSS client.
    Labels: [code]. *)
val metric_discord_gateway_closes : string

(** Discord gateway reconnect backoffs scheduled by the state machine. *)
val metric_discord_gateway_reconnect_scheduled : string

(** Discord gateway heartbeat ACK liveness failures detected by the WSS I/O
    loop before forcing a reconnect. *)
val metric_discord_gateway_ack_timeouts : string

(** Discord gateway reconnect attempt outcomes.
    Labels: [method] = [resume | fresh_identify],
    [outcome] = [succeeded | failed]. *)
val metric_discord_gateway_reconnect_outcomes : string

(** Triggered Discord inbound messages after keeper binding lookup.
    Labels: [outcome] =
    [dropped_unbound | dispatch_unavailable | gate_error | empty_reply |
     reply_sent | reply_send_error]. *)
val metric_discord_inbound_dispatch : string

(** Ambient Discord messages that did not trigger a turn.
    Labels: [outcome] =
    [recorded | dropped_unbound | dropped_empty | dropped_too_long]. *)
val metric_discord_ambient_record : string

(** Discord REST replies attempted by the gateway reply path.
    Labels: [outcome] = [sent | send_error | empty]. *)
val metric_discord_outbound_replies : string

(** Dashboard execution render phase latency histogram. Labels:
    [phase] = total | snapshot | operations | enrich | enrich_per_keeper
            | data_load | assemble.
    The per-phase series let operators distinguish broad dashboard N+1 /
    enrichment cost from unrelated snapshot or assembly latency. *)
val metric_dashboard_execution_render_phase_sec : string

(** Dashboard snapshot phase latency in seconds. *)
val metric_dashboard_snapshot_latency_seconds : string

(** Counter of operator snapshots served from stale cache while a
    background recompute was running. Labels: [cache = "operator"]. *)
val metric_operator_snapshot_stale_served_total : string

(** Cumulative bucket counter for dashboard snapshot phase latency.
    Labels: [le]. *)
val metric_dashboard_snapshot_latency_seconds_bucket : string

(** Dashboard render sub-operation timing all-zero diagnostic.
    Labels: [keeper_name], using [__dashboard__] for the render-level
    singleton required by the Observe dashboard contract. *)
val metric_dashboard_metric_all_zeros : string

(** PR-0.2.A (RFC 2026-04-masc-ide-strategy): cache lookup hit/miss
    counters. Labels: [cache] with values
    - ["eio"]      - [Cache_eio.get] (filesystem-backed key/value cache).
    - ["dashboard"] - [Dashboard_cache.get_or_compute] (in-memory
                     stale-while-revalidate cache for dashboard responses).
    Operator query: [hit_ratio = hits / (hits + misses)] per [cache] label
    quantifies cache effectiveness. Pure observation - registering or
    incrementing these counters never changes cache logic. *)
val metric_cache_hits_total : string

(** Companion to {!metric_cache_hits_total}; same [cache] label values. *)
val metric_cache_misses_total : string

(** Stuck-eviction counter for cache slots whose [Computing] state outlived
    the watchdog budget despite the [release_on_cancel] cleanup hook.

    Increments only from the watchdog branch in
    {!Dashboard_cache.get_or_compute_eio} when a waiter forces a recompute
    because the [Computing] slot has been alive beyond [max_wait_sec].

    SLO: sustained rate >0.1/min indicates [release_on_cancel] is failing
    to fire (compute fiber not getting cancelled when caller switch dies),
    which leaves orphan slots blocking new waiters. Alert is paired with
    the structural fix (release_on_cancel + caller-budget watchdog), not a
    standalone telemetry-as-fix. Labels: cache=dashboard. *)
val metric_cache_stuck_evictions_total : string

(** Histogram of elapsed-seconds at the time a stuck eviction fired.
    Labels: cache=dashboard. Quantiles surface whether stuck slots are
    just past the watchdog ceiling or pathologically older. *)
val metric_cache_stuck_elapsed_seconds : string

(** Companion to {!metric_cache_hits_total}; same [cache] label values. *)
val metric_ws_client_buffered_bytes : string

val metric_ws_client_acks : string
val metric_ws_throttled_deliveries : string
val metric_ws_slice_fanout_skipped : string
val metric_ws_bytes_sent : string
val metric_grpc_bytes_sent : string
val metric_ws_delta_built : string
val metric_ws_delta_payload_serializations : string

(** Histogram of WebSocket message payload size in bytes, observed at
    the wire boundary. Labels: [direction = send | recv]. Complements
    the [masc_ws_bytes_sent_total] counter by exposing per-message
    distribution (p50/p95/p99) so operators can distinguish a few
    large frames from many small frames. *)
val metric_ws_message_bytes : string

(** Lines walked while replaying [.masc/backlog.jsonl] on a gRPC
    Subscribe RPC, including those filtered out by [since_seq]. *)
val metric_grpc_backlog_replay_lines_scanned : string

(** Backlog events actually delivered (post-[since_seq] filter)
    on a gRPC Subscribe RPC. The gap between scanned-lines and
    replayed-events isolates wasted scan cost. *)
val metric_grpc_backlog_replay_events_replayed : string

(** Primary HTTP listener accepted TCP connections. Labels: [mode]. *)
val metric_http_accepts : string

(** Primary HTTP listener accept-loop errors. Labels: [mode]. *)
val metric_http_accept_errors : string

(** Primary HTTP listener active accepted connections. *)
val metric_http_active_connections : string
