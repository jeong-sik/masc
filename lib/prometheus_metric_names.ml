(** Metric-name constants split from [Prometheus] to keep the registry
    module below the absolute file-size cap without changing its public API. *)

(* MCP tool schema budget (set once at boot from mcp_server_eio.ml
   via [set_tool_schema_stats]). *)
let metric_mcp_tool_schema_count = "masc_mcp_tool_schema_count"
let metric_mcp_tool_schema_tokens_approx =
  "masc_mcp_tool_schema_tokens_approx"

(* Transport metrics — used in transport_metrics.ml. *)
let metric_sse_sessions = "masc_sse_sessions_total"
let metric_sse_broadcast_duration = "masc_sse_broadcast_duration_seconds"
let metric_sse_broadcast_events = "masc_sse_broadcast_events_total"
let metric_sse_broadcast_failures = "masc_sse_broadcast_failures_total"
let metric_sse_external_subscriber_callback_failures =
  "masc_sse_external_subscriber_callback_failures_total"
let metric_oas_sse_relay_drop_marker_failures =
  "masc_oas_sse_relay_drop_marker_failures_total"
let metric_sse_stream_queue_depth = "masc_sse_stream_queue_depth"
let metric_sse_queue_depth_avg = "masc_sse_queue_depth_avg"
let metric_sse_queue_depth_max = "masc_sse_queue_depth_max"
let metric_sse_external_subscribers = "masc_sse_external_subscribers_total"
let metric_sse_client_evictions = "masc_sse_client_evictions_total"
let metric_coord_broadcast_duration = "masc_coord_broadcast_duration_seconds"
let metric_file_lock_retries = "masc_file_lock_retries_total"
let metric_file_lock_acquire_duration = "masc_file_lock_acquire_seconds"
let metric_grpc_active_streams = "masc_grpc_active_streams_total"
let metric_grpc_heartbeat_latency = "masc_grpc_heartbeat_latency_seconds"
let metric_grpc_subscribers = "masc_grpc_subscribers_total"
let metric_grpc_events_delivered = "masc_grpc_events_delivered_total"
let metric_grpc_events_dropped = "masc_grpc_events_dropped_total"
let metric_ws_sessions = "masc_ws_sessions_total"
let metric_ws_parse_cache_hits = "masc_ws_parse_cache_hits_total"
let metric_ws_parse_cache_misses = "masc_ws_parse_cache_misses_total"
let metric_ws_bytes_cache_hits = "masc_ws_bytes_cache_hits_total"
let metric_ws_bytes_cache_misses = "masc_ws_bytes_cache_misses_total"
let metric_dashboard_execution_render_phase_sec =
  "masc_dashboard_execution_render_phase_seconds"
let metric_dashboard_snapshot_latency_seconds =
  "masc_dashboard_snapshot_latency_seconds"
let metric_dashboard_snapshot_latency_seconds_bucket =
  "masc_dashboard_snapshot_latency_seconds_bucket"
let metric_dashboard_metric_all_zeros =
  "masc_dashboard_metric_all_zeros"

(* PR-0.2.A (RFC 2026-04-masc-ide-strategy): generic cache hit/miss
   counters, labelled by [cache] = "eio" | "dashboard".  Distinct from
   the WS-specific parse/bytes cache counters above; these track the
   filesystem-backed [Cache_eio] and the dashboard in-memory
   stale-while-revalidate cache. *)
let metric_cache_hits_total = "masc_cache_hits_total"
let metric_cache_misses_total = "masc_cache_misses_total"
let metric_ws_client_buffered_bytes = "masc_ws_client_buffered_bytes"
let metric_ws_client_acks = "masc_ws_client_acks_total"
let metric_ws_throttled_deliveries = "masc_ws_throttled_deliveries_total"
let metric_ws_slice_fanout_skipped = "masc_ws_slice_fanout_skipped_total"
let metric_ws_bytes_sent = "masc_ws_bytes_sent_total"
let metric_grpc_bytes_sent = "masc_grpc_bytes_sent_total"
let metric_ws_delta_built = "masc_ws_delta_built_total"
let metric_ws_message_bytes = "masc_ws_message_bytes"

(* Backlog-replay attribution: every gRPC Subscribe RPC reads
   [.masc/backlog.jsonl] from disk before the live broadcast hook
   takes over.  These two counters separate replay cost from live
   delivery so a Subscribe burst can be billed against backlog IO,
   not [grpc_bytes_sent] / [grpc_events_delivered] which lump init
   + replay + live into one bucket. *)
let metric_grpc_backlog_replay_lines_scanned =
  "masc_grpc_backlog_replay_lines_scanned_total"
let metric_grpc_backlog_replay_events_replayed =
  "masc_grpc_backlog_replay_events_replayed_total"
let metric_http_accepts = "masc_http_accepts_total"
let metric_http_accept_errors = "masc_http_accept_errors_total"
let metric_http_active_connections = "masc_http_active_connections"

(* Agent health metrics — used in transport_metrics.ml. *)
let metric_agent_heartbeat_age_seconds = "masc_agent_heartbeat_age_seconds"
let metric_agent_stale_total = "masc_agent_stale_total"

(* Process-level FD gauges — used in init() and update_fd_gauges. *)
let metric_open_fds = "masc_process_open_fds"
let metric_fd_warn_threshold = "masc_process_fd_warn_threshold"
