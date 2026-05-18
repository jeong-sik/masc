(** Built-in metric registration chunk. *)

open Prometheus_builtin_metric_names

type metric_kind = [ `Counter | `Gauge | `Histogram ]

type register_histogram =
  name:string -> help:string -> ?labels:(string * string) list -> unit -> unit

type register_gauge =
  name:string -> help:string -> ?labels:(string * string) list -> unit -> unit

type inc_counter =
  string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit

let register
      ~(add : string -> string -> metric_kind -> unit)
      ~(register_histogram : register_histogram)
      ~(register_gauge : register_gauge)
      ~inc_counter:(_ : inc_counter)
      ()
  =
  register_histogram
    ~name:metric_file_lock_acquire_seconds
    ~help:
      "acquire_flock_retry* wall-clock excluding openfile. Labels: caller, outcome \
       (acquired|timeout)."
    ();
  (* Duplicate keeper turn / cascade / persistence-failure registrations were
     removed; the authoritative help text lives at the earlier init() sites. *)
  add
    Keeper_metrics.metric_keeper_stale_termination_total
    "Total stale watchdog terminations (all classes). Labels: keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_stale_termination_by_class
    "Total stale watchdog terminations broken down by kill class      (idle_turn | \
     in_turn_hung | noop_failure_loop). Labels: keeper, class."
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_timeout_budget_watchdog_termination
    "Total watchdog terminations preserving unresolved oas_timeout_budget      failure \
     reason. Labels: keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_stale_termination_threshold_breached
    "Total stale termination threshold breaches triggering auto-pause.      Labels: \
     keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_stale_termination_batch
    "Total fleet-wide batch termination events (multiple keepers terminated      within \
     the batch window). Labels: root_cause."
    `Counter;
  add
    Keeper_metrics.metric_keeper_stale_broadcast_emit_failures
    "Total failures emitting stale keeper broadcast events. Labels: keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_run_timeout
    "Total Agent.run / run_stream invocations that returned Llm_provider.Retry.Timeout. \
     Pairs with #13923 (max_execution_time wire) and #13933 (cascade activation): \
     dashboards can attribute hangs to root cause via the source label \
     (max_execution_time = our wrapper fired; provider = transport-level deadline). \
     Labels: cascade, provider, source."
    `Counter;
  add
    Keeper_metrics.metric_keeper_tool_use_failure
    "Total keeper tool use failures during OAS hooks. Labels: keeper, tool."
    `Counter;
  add
    Keeper_metrics.metric_keeper_tool_not_allowed
    "Total keeper tool calls denied because the tool is not in the keeper's allowlist \
     (preset drift, deny-list, or unknown tool name). Labels: keeper, tool, reason. \
     reason ∈ {not_in_candidate_set, denied_by_policy, not_in_allow_set}. Alert on a \
     non-zero rate for any (keeper, tool) pair: it means the keeper's BDI is attempting \
     tools that its preset/policy does not permit, causing the keeper to loop without \
     making progress. Distinct from masc_keeper_tool_use_failure_total (post-execution \
     hook failure) and masc_keeper_turn_gate_rejected_terminal_total (pre_tool_use guard \
     hard-reject)."
    `Counter;
  add
    metric_after_turn_response_model_empty
    "After-turn response model resolution returned empty string."
    `Counter;
  add
    metric_after_turn_response_model_alias
    "After-turn response model matched a known alias."
    `Counter;
  add
    metric_pricing_catalog_miss
    "Pricing catalog lookups that missed. Labels: model."
    `Counter;
  (* metric_cost_emit_zero_source is registered in keeper_hooks_oas.ml. *)
  add
    metric_cost_ledger_status
    "Cost ledger status transitions per provider/status/reason combination. Labels: \
     provider, status, reason."
    `Counter;
  (* Related keeper guard/receipt metrics are registered in their owning modules. *)
  add
    Keeper_metrics.metric_keeper_bash_network_upgrade
    "Bash shell network upgrade events. Labels: keeper, detected_tool."
    `Counter;
  add
    Keeper_metrics.metric_keeper_bash_local_execution
    "Bash shell local execution events. Labels: keeper, reason."
    `Counter;
  add
    Keeper_metrics.metric_keeper_docker_runtime_discarded
    "Docker shell runtime output discarded. Labels: keeper, reason."
    `Counter;
  add
    Keeper_metrics.metric_keeper_proactive_skip
    "Proactive turn skipped due to heartbeat snapshot conditions. Labels: keeper, reason."
    `Counter;
  add
    Keeper_metrics.metric_keeper_stay_silent_loop_detected
    "Stay-silent loop detector triggered. Labels: keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_usage_trust
    "Keeper usage trust outcome. Labels: keeper, outcome."
    `Counter;
  add
    Keeper_metrics.metric_keeper_usage_anomaly_reason
    "Keeper usage anomaly reason. Labels: keeper, reason."
    `Counter;
  add
    Keeper_metrics.metric_keeper_config_env_parse_failures
    "Config env var parse failures (non-integer values). Labels: var."
    `Counter;
  add
    Keeper_metrics.metric_keeper_post_turn_wirein_failures
    "Post-turn wire-in failures (autonomous, tool_emission_drain, multimodal, \
     resilience). Labels: keeper, phase."
    `Counter;
  (* metric_keeper_meta_read_failures is registered earlier in init(). *)
  add
    Keeper_metrics.metric_keeper_recurring_failures
    "Recurring task execution/dispatch failures. Labels: task, phase."
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_cleanup_failures
    "Turn cleanup failures (unsubscribe event_bus, mark_turn_finished). Labels: keeper, \
     site."
    `Counter;
  (* === Keeper metrics previously unregistered in init() ===
     These were auto-registered on first inc_counter call with no HELP text.
     Explicit registration adds proper documentation. *)
  add
    Keeper_metrics.metric_keeper_fsm_edge_transitions
    "Keeper FSM edge transitions across lifecycle states. Labels: edge."
    `Counter;
  add
    Keeper_metrics.metric_keeper_invariant_violations
    "Keeper composite lifecycle invariant violations. Labels: keeper, invariant."
    `Counter;
  add
    Keeper_metrics.metric_keeper_metric_emit_dropped
    "Keeper metric emit attempts dropped (buffer full / unregistered). Labels: keeper, \
     reason."
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_timeout_budget_strike
    "OAS timeout budget strikes (consecutive timeouts before escalation). Labels: keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_path_rejection
    "Keeper path rejections (sandbox escape / outside roots). Labels: kind."
    `Counter;
  add
    Keeper_metrics.metric_ide_orphan_writes
    "RFC-0128 §4.2: IDE annotation/region writes that landed in \
     .masc-ide/_orphan/ because the canonical URL could not be resolved. \
     Labels: kind (annotation | region), reason."
    `Counter;
  add
    Keeper_metrics.metric_keeper_provider_cooldown_remaining_sec
    "Provider cooldown remaining seconds. Labels: keeper, provider."
    `Gauge;
  add
    Keeper_metrics.metric_keeper_provider_cooldown_skip
    "Provider cooldown skips (fallback cascade used while cooling). Labels: keeper, \
     provider."
    `Counter;
  add
    Keeper_metrics.metric_keeper_require_tool_use_violations
    "Tool contract require_tool_use violations. Labels: keeper, contract_status."
    `Counter;
  add
    Keeper_metrics.metric_keeper_semaphore_wait_seconds_bucket
    "Keeper turn semaphore wait duration buckets (le label)."
    `Counter;
  add
    Keeper_metrics.metric_keeper_semaphore_wait_timeout
    "Keeper turn semaphore wait timeouts. Labels: keeper, channel."
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_fsm_transitions
    "Keeper turn FSM state transitions. Labels: keeper, from, to."
    `Counter;
  add
    metric_mention_dedup_decisions_total
    "RFC-0040 sender-side mention dedup decisions. Labels: \
     outcome={skipped|passed|no_target|bypassed}."
    `Counter;
  add metric_grpc_active_streams "Active gRPC bidirectional streams" `Gauge;
  register_histogram
    ~name:metric_grpc_heartbeat_latency
    ~help:"gRPC heartbeat round-trip latency"
    ();
  add metric_grpc_subscribers "Active gRPC Subscribe stream subscribers" `Gauge;
  add metric_grpc_events_delivered "Total events delivered via gRPC streams" `Counter;
  add
    metric_grpc_events_dropped
    "Events dropped by gRPC subscribers when the stream buffer is full (capacity \
     pressure — operator must investigate slow consumers)"
    `Counter;
  add metric_ws_sessions "Active standalone WebSocket sessions" `Gauge;
  add
    metric_ws_parse_cache_hits
    "WS dashboard delta parse cache hits (same event string reused across sessions)"
    `Counter;
  add
    metric_ws_parse_cache_misses
    "WS dashboard delta parse cache misses (fresh JSON parse required)"
    `Counter;
  add
    metric_server_mcp_ws_frame_json_parse_failures
    "WebSocket transport incoming-frame JSON parse failures (frame dropped). \
     Labels: error_kind={yojson_parse_error|other}. Iter 28 visibility \
     fix for previously-silent drops in parse_sse_dashboard_event."
    `Counter;
  add
    metric_sidecar_schema_field_types_json_parse_failures
    "Sidecar HTTP route schema_field_types JSON parse failures (returns []). \
     Labels: error_kind={json_parse_error|other}. Iter 31 visibility \
     fix for previously-silent type-validation bypass on malformed schema \
     JSON in server_routes_http_routes_sidecar.schema_field_types."
    `Counter;
  add
    metric_ws_bytes_cache_hits
    "WS raw-SSE-forward Bytes cache hits (same event reused across sessions)"
    `Counter;
  add
    metric_ws_bytes_cache_misses
    "WS raw-SSE-forward Bytes cache misses (fresh allocation required)"
    `Counter;
  register_histogram
    ~name:metric_ws_dashboard_hello_latency_seconds
    ~help:
      "dashboard/hello JSON-RPC processing latency in seconds. Labels: \
       outcome=success|error."
    ~labels:[ "outcome", "success" ]
    ();
  register_histogram
    ~name:metric_ws_dashboard_hello_latency_seconds
    ~help:
      "dashboard/hello JSON-RPC processing latency in seconds. Labels: \
       outcome=success|error."
    ~labels:[ "outcome", "error" ]
    ();
  add
    metric_http_accepts
    "TCP connections accepted by the primary HTTP listener. Labels: mode (h1|h2|auto)."
    `Counter;
  add
    metric_http_accept_errors
    "Primary HTTP listener accept-loop errors. Labels: mode (h1|h2|auto). A non-zero \
     rate means fresh control-plane connections may be blocked even while existing \
     dashboard/SSE sessions remain established."
    `Counter;
  add
    metric_http_active_connections
    "Currently active primary HTTP connections accepted by the listener."
    `Gauge;
  register_histogram
    ~name:metric_dashboard_execution_render_phase_sec
    ~help:
      "Dashboard execution render phase latency in seconds. Labels: \
       phase=total|snapshot|operations|enrich|enrich_per_keeper|data_load|assemble."
    ();
  register_histogram
    ~name:metric_dashboard_snapshot_latency_seconds
    ~help:"Dashboard snapshot phase latency in seconds."
    ();
  register_gauge
    ~name:metric_dashboard_metric_all_zeros
    ~help:
      "Dashboard render sub-operation timing all-zero diagnostic. 1 means \
       snapshot/operations/enrich/data_load/assemble were all zero for a non-empty \
       render. Labels: keeper_name, with keeper_name=__dashboard__ for this render-level \
       singleton."
    ~labels:[ "keeper_name", "__dashboard__" ]
    ();
  (* Generic cache hit/miss counters. Per-label series are created on first use. *)
  add
    metric_cache_hits_total
    "Cache lookup hits. Labels: cache=eio|dashboard. hit_ratio = hits / (hits + misses) \
     per cache label."
    `Counter;
  add
    metric_cache_misses_total
    "Cache lookup misses (compute required). Labels: cache=eio|dashboard."
    `Counter;
  register_histogram
    ~name:metric_ws_client_buffered_bytes
    ~help:"Dashboard client WebSocket.bufferedAmount reported on each ack"
    ();
  add
    metric_ws_client_acks
    "Total dashboard/ack notifications received from WS clients"
    `Counter;
  add
    metric_ws_throttled_deliveries
    "WS dashboard deliveries skipped because the client's last reported bufferedAmount \
     exceeded MASC_WS_CLIENT_BUFFER_LIMIT_BYTES"
    `Counter;
  add
    metric_ws_slice_fanout_skipped
    "WS sessions skipped during slice-scoped fanout because their route does not \
     subscribe to the event's slice (gated by MASC_WS_SLICE_INDEX_ENABLED, RFC #10119 \
     Phase 2)"
    `Counter;
  add
    metric_ws_bytes_sent
    "Bytes written to WebSocket clients (frame payload only, includes dashboard deltas \
     and raw SSE forwards). Capacity-planning input for bandwidth-burst response."
    `Counter;
  add
    metric_grpc_bytes_sent
    "Bytes serialised into gRPC Subscribe stream events delivered to subscribers. Same \
     purpose as masc_ws_bytes_sent_total but for the gRPC transport."
    `Counter;
  add
    metric_ws_delta_built
    "Per-session dashboard deltas constructed (one Yojson.Safe.t allocation + \
     jsonrpc_notification wrap per delta). Divide by broadcast count to estimate fanout \
     amplification."
    `Counter;
  register_histogram
    ~name:metric_ws_message_bytes
    ~help:
      "WebSocket message payload size in bytes (per-frame, wire boundary). Labelled by \
       direction so send vs recv distributions can be compared independently."
    ~labels:[ "direction", "send" ]
    ();
  register_histogram
    ~name:metric_ws_message_bytes
    ~help:
      "WebSocket message payload size in bytes (per-frame, wire boundary). Labelled by \
       direction so send vs recv distributions can be compared independently."
    ~labels:[ "direction", "recv" ]
    ();
  add
    metric_grpc_backlog_replay_lines_scanned
    "Lines walked while replaying .masc/backlog.jsonl on a gRPC Subscribe RPC (every \
     line, including those filtered by since_seq). Use with backlog file size to \
     estimate disk read cost amplification under a Subscribe burst."
    `Counter;
  add
    metric_grpc_backlog_replay_events_replayed
    "Backlog events actually delivered (post-since_seq filter) on gRPC Subscribe. Subset \
     of grpc_events_delivered; the difference between scanned-lines and replayed-events \
     isolates wasted scan cost."
    `Counter;
  (* RFC-0022 §9 attempt-liveness gate metrics. *)
  add
    metric_cascade_attempt_liveness_kill
    "Counts would-be (Observe) and actual (Enforce) liveness kills broken down by \
     failure class. Labels: [kind, mode, cascade, provider] where provider is a \
     bounded public provider bucket."
    `Counter;
  add
    metric_cascade_attempt_liveness_observed
    "Per-attempt finalizer counter regardless of outcome (success | kill | wire_error). \
     Useful for the kill-rate ratio. Labels: [cascade, provider, outcome] where provider \
     is a bounded public provider bucket."
    `Counter;
  add metric_cascade_strategy_decisions "Cascade strategy decisions by outcome." `Counter;
  add metric_cascade_capacity_events "Cascade capacity events by type." `Counter;
  add
    metric_cascade_ttfb_seconds
    "Time from cascade attempt start to first non-Done chunk (TTFT). Labels: [cascade, \
     provider] where provider is a bounded public provider bucket."
    `Histogram;
  add
    metric_cascade_inter_chunk_seconds
    "Inter-chunk gap during streaming (TBT). Labels: [cascade, provider] where provider \
     is a bounded public provider bucket."
    `Histogram;
  add
    metric_cascade_provider_health_score
    "Composite health score per cascade provider. success_rate * speed_score * \
     cost_score in [0.0, 1.0]. Labels: [provider_key]."
    `Gauge;
  add
    metric_oas_context_overflow_ratio
    "Context overflow ratio (estimated_tokens / limit_tokens) when \
     ContextOverflowImminent fires. Labels: [agent_name]."
    `Gauge;
  add
    metric_oas_context_compaction_total
    "Total context compaction actions triggered by OAS event bus. Labels: [agent_name, \
     trigger]."
    `Counter;
  ()
;;
