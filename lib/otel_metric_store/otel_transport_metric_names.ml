(** Transport, websocket, gRPC, HTTP, dashboard, and cache metric-name
    constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

let metric_sse_sessions = Otel_metric_store_core.declare_counter "masc_sse_sessions_total"
let metric_sse_broadcast_duration = "masc_sse_broadcast_duration_seconds"
let metric_sse_broadcast_events = Otel_metric_store_core.declare_counter "masc_sse_broadcast_events_total"
let metric_sse_broadcast_failures = Otel_metric_store_core.declare_counter "masc_sse_broadcast_failures_total"

let metric_sse_external_subscriber_callback_failures =
  Otel_metric_store_core.declare_counter "masc_sse_external_subscriber_callback_failures_total"
;;

let metric_sse_external_fanout_duration_seconds =
  "masc_sse_external_fanout_duration_seconds"
;;

let metric_oas_sse_relay_drop_marker_failures =
  Otel_metric_store_core.declare_counter "masc_oas_sse_relay_drop_marker_failures_total"
;;

let metric_sse_stream_queue_depth = "masc_sse_stream_queue_depth"
let metric_sse_queue_depth_avg = "masc_sse_queue_depth_avg"
let metric_sse_queue_depth_max = "masc_sse_queue_depth_max"
let metric_sse_external_subscribers = "masc_sse_external_subscribers_total"
let metric_sse_client_evictions = Otel_metric_store_core.declare_counter "masc_sse_client_evictions_total"
let metric_workspace_broadcast_duration = "masc_workspace_broadcast_duration_seconds"
let metric_file_lock_retries = Otel_metric_store_core.declare_counter "masc_file_lock_retries_total"
let metric_file_lock_acquire_seconds = "masc_file_lock_acquire_seconds"
let metric_grpc_active_streams = "masc_grpc_active_streams_total"
let metric_grpc_heartbeat_latency = "masc_grpc_heartbeat_latency_seconds"
let metric_grpc_subscribers = Otel_metric_store_core.declare_counter "masc_grpc_subscribers_total"
let metric_grpc_events_delivered = Otel_metric_store_core.declare_counter "masc_grpc_events_delivered_total"
let metric_grpc_events_dropped = Otel_metric_store_core.declare_counter "masc_grpc_events_dropped_total"
let metric_ws_sessions = Otel_metric_store_core.declare_counter "masc_ws_sessions_total"
let metric_ws_parse_cache_hits = Otel_metric_store_core.declare_counter "masc_ws_parse_cache_hits_total"
let metric_ws_parse_cache_misses = Otel_metric_store_core.declare_counter "masc_ws_parse_cache_misses_total"

let metric_server_mcp_ws_frame_json_parse_failures =
  Otel_metric_store_core.declare_counter "masc_server_mcp_ws_frame_json_parse_failures_total"
;;

let metric_sidecar_schema_field_types_json_parse_failures =
  Otel_metric_store_core.declare_counter "masc_sidecar_schema_field_types_json_parse_failures_total"
;;

let metric_ws_bytes_cache_hits = Otel_metric_store_core.declare_counter "masc_ws_bytes_cache_hits_total"
let metric_ws_bytes_cache_misses = Otel_metric_store_core.declare_counter "masc_ws_bytes_cache_misses_total"
let metric_ws_dashboard_hello_latency_seconds = "masc_ws_dashboard_hello_latency_seconds"

let metric_discord_gateway_events =
  Otel_metric_store_core.declare_counter "masc_discord_gateway_events_total"
;;

let metric_discord_gateway_closes =
  Otel_metric_store_core.declare_counter "masc_discord_gateway_closes_total"
;;

let metric_discord_gateway_reconnect_scheduled =
  Otel_metric_store_core.declare_counter
    "masc_discord_gateway_reconnect_scheduled_total"
;;

let metric_discord_gateway_ack_timeouts =
  Otel_metric_store_core.declare_counter
    "masc_discord_gateway_ack_timeouts_total"
;;

let metric_discord_gateway_reconnect_outcomes =
  Otel_metric_store_core.declare_counter
    "masc_discord_gateway_reconnect_outcomes_total"
;;

let metric_discord_inbound_dispatch =
  Otel_metric_store_core.declare_counter "masc_discord_inbound_dispatch_total"
;;

let metric_discord_ambient_record =
  Otel_metric_store_core.declare_counter "masc_discord_ambient_record_total"
;;

let metric_discord_outbound_replies =
  Otel_metric_store_core.declare_counter "masc_discord_outbound_replies_total"
;;

(* RFC-0317: Slack in-process gateway counters. Mirror the Discord subset that
   the server-side gateway emits directly (event flow + inbound dispatch +
   outbound replies). Connection-level counters (reconnect/close) stay in the
   I/O layer and are added when Slack_socket_client grows observability. *)
let metric_slack_gateway_events =
  Otel_metric_store_core.declare_counter "masc_slack_gateway_events_total"
;;

let metric_slack_inbound_dispatch =
  Otel_metric_store_core.declare_counter "masc_slack_inbound_dispatch_total"
;;

let metric_slack_outbound_replies =
  Otel_metric_store_core.declare_counter "masc_slack_outbound_replies_total"
;;

let metric_dashboard_execution_render_phase_sec =
  "masc_dashboard_execution_render_phase_seconds"
;;

let metric_dashboard_snapshot_latency_seconds = "masc_dashboard_snapshot_latency_seconds"

let metric_operator_snapshot_stale_served_total =
  Otel_metric_store_core.declare_counter "masc_operator_snapshot_stale_served_total"
;;

let metric_dashboard_snapshot_latency_seconds_bucket =
  "masc_dashboard_snapshot_latency_seconds_bucket"
;;

let metric_dashboard_metric_all_zeros = "masc_dashboard_metric_all_zeros"
let metric_cache_hits_total = Otel_metric_store_core.declare_counter "masc_cache_hits_total"
let metric_cache_misses_total = Otel_metric_store_core.declare_counter "masc_cache_misses_total"
let metric_cache_stuck_evictions_total = Otel_metric_store_core.declare_counter "masc_cache_stuck_evictions_total"
let metric_cache_stuck_elapsed_seconds = "masc_cache_stuck_elapsed_seconds"
let metric_ws_client_buffered_bytes = "masc_ws_client_buffered_bytes"
let metric_ws_client_acks = Otel_metric_store_core.declare_counter "masc_ws_client_acks_total"
let metric_ws_throttled_deliveries = Otel_metric_store_core.declare_counter "masc_ws_throttled_deliveries_total"
let metric_ws_slice_fanout_skipped = Otel_metric_store_core.declare_counter "masc_ws_slice_fanout_skipped_total"
let metric_ws_bytes_sent = Otel_metric_store_core.declare_counter "masc_ws_bytes_sent_total"
let metric_grpc_bytes_sent = Otel_metric_store_core.declare_counter "masc_grpc_bytes_sent_total"
let metric_ws_delta_built = Otel_metric_store_core.declare_counter "masc_ws_delta_built_total"

let metric_ws_delta_payload_serializations =
  Otel_metric_store_core.declare_counter "masc_ws_delta_payload_serializations_total"
;;

let metric_ws_message_bytes = "masc_ws_message_bytes"

let metric_grpc_backlog_replay_lines_scanned =
  Otel_metric_store_core.declare_counter "masc_grpc_backlog_replay_lines_scanned_total"
;;

let metric_grpc_backlog_replay_events_replayed =
  Otel_metric_store_core.declare_counter "masc_grpc_backlog_replay_events_replayed_total"
;;

let metric_http_accepts = Otel_metric_store_core.declare_counter "masc_http_accepts_total"
let metric_http_accept_errors = Otel_metric_store_core.declare_counter "masc_http_accept_errors_total"
let metric_http_active_connections = "masc_http_active_connections"
