(** Transport, websocket, gRPC, HTTP, dashboard, and cache metric-name
    constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

let metric_sse_sessions = "masc_sse_sessions_total"
let metric_sse_broadcast_duration = "masc_sse_broadcast_duration_seconds"
let metric_sse_broadcast_events = "masc_sse_broadcast_events_total"
let metric_sse_broadcast_failures = "masc_sse_broadcast_failures_total"

let metric_sse_external_subscriber_callback_failures =
  "masc_sse_external_subscriber_callback_failures_total"
;;

let metric_oas_sse_relay_drop_marker_failures =
  "masc_oas_sse_relay_drop_marker_failures_total"
;;

let metric_sse_stream_queue_depth = "masc_sse_stream_queue_depth"
let metric_sse_queue_depth_avg = "masc_sse_queue_depth_avg"
let metric_sse_queue_depth_max = "masc_sse_queue_depth_max"
let metric_sse_external_subscribers = "masc_sse_external_subscribers_total"
let metric_sse_client_evictions = "masc_sse_client_evictions_total"
let metric_coord_broadcast_duration = "masc_coord_broadcast_duration_seconds"
let metric_file_lock_retries = "masc_file_lock_retries_total"
let metric_file_lock_acquire_seconds = "masc_file_lock_acquire_seconds"
let metric_grpc_active_streams = "masc_grpc_active_streams_total"
let metric_grpc_heartbeat_latency = "masc_grpc_heartbeat_latency_seconds"
let metric_grpc_subscribers = "masc_grpc_subscribers_total"
let metric_grpc_events_delivered = "masc_grpc_events_delivered_total"
let metric_grpc_events_dropped = "masc_grpc_events_dropped_total"
let metric_ws_sessions = "masc_ws_sessions_total"
let metric_ws_parse_cache_hits = "masc_ws_parse_cache_hits_total"
let metric_ws_parse_cache_misses = "masc_ws_parse_cache_misses_total"

let metric_server_mcp_ws_frame_json_parse_failures =
  "masc_server_mcp_ws_frame_json_parse_failures_total"
;;

let metric_sidecar_schema_field_types_json_parse_failures =
  "masc_sidecar_schema_field_types_json_parse_failures_total"
;;

let metric_ws_bytes_cache_hits = "masc_ws_bytes_cache_hits_total"
let metric_ws_bytes_cache_misses = "masc_ws_bytes_cache_misses_total"
let metric_ws_dashboard_hello_latency_seconds = "masc_ws_dashboard_hello_latency_seconds"

let metric_dashboard_execution_render_phase_sec =
  "masc_dashboard_execution_render_phase_seconds"
;;

let metric_dashboard_snapshot_latency_seconds = "masc_dashboard_snapshot_latency_seconds"

let metric_dashboard_snapshot_latency_seconds_bucket =
  "masc_dashboard_snapshot_latency_seconds_bucket"
;;

let metric_dashboard_metric_all_zeros = "masc_dashboard_metric_all_zeros"
let metric_cache_hits_total = "masc_cache_hits_total"
let metric_cache_misses_total = "masc_cache_misses_total"
let metric_cache_stuck_evictions_total = "masc_cache_stuck_evictions_total"
let metric_cache_stuck_elapsed_seconds = "masc_cache_stuck_elapsed_seconds"
let metric_ws_client_buffered_bytes = "masc_ws_client_buffered_bytes"
let metric_ws_client_acks = "masc_ws_client_acks_total"
let metric_ws_throttled_deliveries = "masc_ws_throttled_deliveries_total"
let metric_ws_slice_fanout_skipped = "masc_ws_slice_fanout_skipped_total"
let metric_ws_bytes_sent = "masc_ws_bytes_sent_total"
let metric_grpc_bytes_sent = "masc_grpc_bytes_sent_total"
let metric_ws_delta_built = "masc_ws_delta_built_total"
let metric_ws_message_bytes = "masc_ws_message_bytes"

let metric_grpc_backlog_replay_lines_scanned =
  "masc_grpc_backlog_replay_lines_scanned_total"
;;

let metric_grpc_backlog_replay_events_replayed =
  "masc_grpc_backlog_replay_events_replayed_total"
;;

let metric_http_accepts = "masc_http_accepts_total"
let metric_http_accept_errors = "masc_http_accept_errors_total"
let metric_http_active_connections = "masc_http_active_connections"
