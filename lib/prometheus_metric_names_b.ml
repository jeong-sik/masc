let metric_keeper_execution_receipt_failures =
  "masc_keeper_execution_receipt_failures_total"
let metric_keeper_llm_bridge_failures =
  "masc_keeper_llm_bridge_failures_total"
let metric_keeper_shell_bash_failures =
  "masc_keeper_shell_bash_failures_total"
let metric_keeper_rollover_failures =
  "masc_keeper_rollover_failures_total"
let metric_keeper_lifecycle_dispatch_rejections =
  "masc_keeper_lifecycle_dispatch_rejections_total"
let metric_keeper_paused_state_persist_errors =
  "masc_keeper_paused_state_persist_errors_total"
let metric_keeper_unexpected_tool_partial_tolerance =
  "masc_keeper_unexpected_tool_partial_tolerance_total"
(* #10091: [require_tool_use] contract violations labelled by
   [has_current_task] (true = #10091's active-task path that
   [#10031] intentionally left strict, false = the no-task path
   that [#10031] relaxed to [Auto]) and by fine-grained
   [contract_status] ([passive_only], [needs_execution_progress],
   [claim_only_after_owned_task], [tool_surface_mismatch],
   [missing_required_tool_use]).  The fleet histogram of
   (keeper, contract_status) pairs tells the operator which
   keeper tool_presets need reshaping for the current task mix
   without masking the strict gate. *)
let metric_keeper_require_tool_use_violations =
  "masc_keeper_require_tool_use_violations_total"
let metric_keeper_tool_alias_canonicalizations =
  "masc_keeper_tool_alias_canonicalizations_total"
let metric_keeper_profile_config_conflicts =
  "masc_keeper_profile_config_conflicts_total"
let metric_keeper_oas_timeout_classifications =
  "masc_keeper_oas_timeout_classifications_total"
(* #10474: no_tool_capable_provider and proactive cycle outcome counters.
   [metric_keeper_no_tool_provider_total] fires every time a keeper's
   cascade has zero tool-capable providers, labelled by cascade so
   the operator sees which cascade definition needs fixing.
   [metric_keeper_proactive_outcome_total] classifies every scheduled
   autonomous cycle into tool_called | noop | error, giving a fleet-wide
   health ratio in Grafana. *)
let metric_keeper_no_tool_provider =
  "masc_keeper_no_tool_provider_total"
let metric_keeper_proactive_outcome =
  "masc_keeper_proactive_outcome_total"
(* PR-B: keeper turn skipped due to ollama saturation pre-check.
   Labelled by [keeper] and [cascade]. *)
let metric_keeper_ollama_saturation_skip =
  "masc_keeper_ollama_saturation_skip_total"
(* Tool-setup and task-load failures during keeper tool surface assembly.
   task_load: Coord.get_tasks_raw exception while loading current task contract.
   tool_selection: TopK_llm or tool discovery exception during per-turn tool set assembly. *)
let metric_keeper_task_load_failures =
  "masc_keeper_task_load_failures_total"
let metric_keeper_tool_selection_failures =
  "masc_keeper_tool_selection_failures_total"
let metric_keeper_tool_policy_failures =
  "masc_keeper_tool_policy_failures_total"
let metric_tool_policy_unloaded_query =
  "masc_tool_policy_unloaded_query_total"
let metric_tool_policy_init_failed =
  "masc_tool_policy_init_failed_total"
let metric_cache_desync_cleared =
  "masc_cache_desync_cleared_total"
let metric_keeper_reconcile_failures =
  "masc_keeper_reconcile_failures_total"
let metric_keeper_decision_audit_flush_failures =
  "masc_keeper_decision_audit_flush_failures_total"
let metric_keeper_oas_cancel =
  "masc_keeper_oas_cancel_total"
let metric_keeper_claim_auto_provision =
  "masc_keeper_claim_auto_provision_total"
let metric_egress_audit_missing =
  "masc_egress_audit_missing_total"
let metric_egress_audit_stale_orphan =
  "masc_egress_audit_stale_orphan_total"
let metric_keeper_toml_invalid =
  "masc_keeper_toml_invalid_total"
let metric_keeper_persona_drift_missing =
  "masc_keeper_persona_drift_missing_total"
let metric_keeper_room_init_failures =
  "masc_keeper_room_init_failures_total"
let metric_keeper_presence_sync_failures =
  "masc_keeper_presence_sync_failures_total"
let metric_keeper_self_preservation_universal =
  "masc_keeper_self_preservation_universal_total"
let metric_keeper_stale_storm_paused =
  "masc_keeper_stale_storm_paused_total"
let metric_keeper_stale_fleet_batch_paused =
  "masc_keeper_stale_fleet_batch_paused_total"
let metric_keeper_oas_timeout_budget_loop_paused =
  "masc_keeper_oas_timeout_budget_loop_paused_total"
let metric_keeper_cycle_exceptions =
  "masc_keeper_cycle_exceptions_total"
let metric_keeper_snapshot_write_failures =
  "masc_keeper_snapshot_write_failures_total"
let metric_keeper_progress_updated_line_failures =
  "masc_keeper_progress_updated_line_failures_total"
let metric_keeper_sse_broadcast_failures =
  "masc_keeper_sse_broadcast_failures_total"
let metric_keeper_room_heartbeat_failures =
  "masc_keeper_room_heartbeat_failures_total"
let metric_keeper_turn_metrics_snapshot_failures =
  "masc_keeper_turn_metrics_snapshot_failures_total"
let metric_keeper_oas_execution_errors =
  "masc_keeper_oas_execution_errors_total"
let metric_keeper_episode_create_failures =
  "masc_keeper_episode_create_failures_total"
let metric_keeper_memory_activity_emit_failures =
  "masc_keeper_memory_activity_emit_failures_total"
let metric_keeper_supervisor_sweep_failures =
  "masc_keeper_supervisor_sweep_failures_total"
let metric_keeper_toml_reconcile_sweep_failures =
  "masc_keeper_toml_reconcile_sweep_failures_total"
let metric_keeper_tool_usage_flush_failures =
  "masc_keeper_tool_usage_flush_failures_total"
let metric_keeper_turn_livelock_blocks =
  "masc_keeper_turn_livelock_blocks_total"
let metric_keeper_turn_timeout_committed =
  "masc_keeper_turn_timeout_committed_total"
let metric_keeper_turn_error_after_tools =
  "masc_keeper_turn_error_after_tools_total"
let metric_keeper_cascade_sync_failures =
  "masc_keeper_cascade_sync_failures_total"
let metric_keeper_local_discovery_failures =
  "masc_keeper_local_discovery_failures_total"
let metric_keeper_thinking_persist_failures =
  "masc_keeper_thinking_persist_failures_total"
let metric_keeper_checkpoint_failures =
  "masc_keeper_checkpoint_failures_total"
let metric_keeper_memory_write_failures =
  "masc_keeper_memory_write_failures_total"
let metric_keeper_memory_consolidations =
  "masc_keeper_memory_consolidations_total"
let metric_keeper_write_meta_cycle_failures =
  "masc_keeper_write_meta_cycle_failures_total"
let metric_keeper_alert_persist_failures =
  "masc_keeper_alert_persist_failures_total"
let metric_keeper_metrics_sse_failures =
  "masc_keeper_metrics_sse_failures_total"let metric_keeper_session_cleanup_failures =
  "masc_keeper_session_cleanup_failures_total"
let metric_keeper_chat_store_failures =
  "masc_keeper_chat_store_failures_total"
let metric_keeper_observation_query_failures =
  "masc_keeper_observation_query_failures_total"
let metric_persistence_read_drops =
  "masc_persistence_read_drops_total"
let metric_persistence_utf8_repair =
  "masc_persistence_utf8_repair_total"
let metric_discovery_history_failures =
  "masc_discovery_history_failures_total"

(* #10097: codex_cli provider cannot carry keeper-bound runtime MCP
   tools that need request-scoped auth headers.  Every time
   oas_worker_exec_transport strips such a tool, this counter
   increments with the tool name so dashboards can track WHICH
   tools are being omitted and at WHAT rate.  Paired with a
   once-per-session WARN log ([fingerprint]-deduplicated) so the
   operator sees the structural fact exactly once while the
   counter carries the frequency signal. *)
let metric_codex_cli_mcp_tool_omission =
  "masc_codex_cli_mcp_tool_omission_total"

(* #9520: durable coverage-gap records must also have an alertable
   Prometheus surface.  The labels deliberately avoid raw paths and
   error strings; [source], [producer], [dashboard_surface], and
   [stale_reason] are bounded vocabularies owned by telemetry
   producers. *)
let metric_telemetry_coverage_gap =
  "masc_telemetry_coverage_gap_total"

(* Phase 0 telemetry fan-in: source discovery/read failures must not collapse
   into an indistinguishable empty dashboard. Labels are bounded by the
   Telemetry_unified.source enum and a small site vocabulary. *)
let metric_telemetry_unified_source_read_failures =
  "masc_telemetry_unified_source_read_failures_total"

let metric_tool_assignment_telemetry_failures =
  "masc_tool_assignment_telemetry_failures_total"

(* Phase 0 exception visibility for [Telemetry_observe]: every swallowed
   non-cancel exception logs and increments this bounded-by-callsite counter. *)
let metric_telemetry_observe_failures =
  "masc_telemetry_observe_failures_total"

(* #10358 (c1): observability for the silent [Effect.Unhandled] catch-all
   in [lib/coord.ml] [observe_agent_lifecycle] / [observe_task_transition_event] /
   [Keeper_accountability.record_task_transition].  Those three try/with
   sites swallow the exception that fires when the lifecycle hook is
   dispatched from a non-Eio context (test path, bootstrap, certain HTTP
   handlers).  Before this counter, the entire Audit_log + Telemetry pair
   silently disappeared, exactly matching the 5-tag → 2-tag attrition
   ledger pattern (only [tool_called] survives because it is wired on a
   different fiber-bearing path).  Labels: [event_family] (one of
   [agent_lifecycle] / [task_transition] / [accountability]) and
   [event_kind] (the lifecycle/transition variant). [event_kind] for
   [agent_lifecycle] is one of [join] / [rejoin] / [leave] (3 values).
   [event_kind] for both [task_transition] and [accountability] uses the
   8 [Masc_domain.task_action_to_string] values: [claim] / [start] /
   [done] / [cancel] / [release] / [submit_for_verification] / [approve]
   / [reject]. Both vocabularies are bounded so series cardinality is at
   most 19 (3 + 8 + 8). *)
let metric_coord_telemetry_drop =
  "masc_coord_telemetry_drop_total"
let metric_coord_claim_post_provision_failures =
  "masc_coord_claim_post_provision_failures_total"

(* #10094: per-caller counter for [Masc_oas_bridge.run_safe]
   timeouts.  The [caller] string supplied at the run_safe entry
   point lets the operator see WHICH caller is timing out at
   WHICH configured budget without grepping warn-level log
   lines.  Paired with per-caller env-overridable defaults in
   [Env_config_oas_bridge] so 60s "fantasy" budgets in
   [auto_responder] / [dashboard_provider_runs] no longer
   silently masquerade as the same class of event as
   intentional 120s/180s budgets in autoresearch / deep_review. *)
let metric_oas_bridge_timeout =
  "masc_oas_bridge_timeout_total"

(* #10942 mirror for masc_oas_bridge cancel branch.  Same bucket
   semantics as [masc_keeper_oas_cancel_total] (fast/short_tail/
   mid_tail/long_mid/long_tail) so PromQL can union the two
   sources by [bucket] for a fleet-wide bimodal view of cancels.
   [caller] preserves the timeout-counter pairing so each caller's
   timeout vs cancel populations stay separable. *)
let metric_oas_bridge_cancel =
  "masc_oas_bridge_cancel_total"


(* OAS event relay (oas_event_bridge.ml).  Metric strings keep the
   historical [oas_sse_*] prefix for Grafana/alert continuity; renaming
   the operational contract is deferred to a separate PR with a
   dashboard migration plan. *)
let metric_oas_sse_relay_retries =
  "masc_oas_sse_relay_retries_total"
let metric_oas_sse_relay_drops =
  "masc_oas_sse_relay_drops_total"
let metric_oas_sse_relay_queue_depth =
  "masc_oas_sse_relay_queue_depth"
let metric_oas_inference_telemetry_tokens =
  "masc_oas_inference_telemetry_tokens"
let metric_oas_inference_prompt_tok_per_sec =
  "masc_oas_inference_prompt_tok_per_sec"
let metric_oas_inference_decode_tok_per_sec =
  "masc_oas_inference_decode_tok_per_sec"
let metric_oas_inference_cost_usd =
  "masc_oas_inference_cost_usd"

(* Cascade provider health score — composite of success_rate * speed_score *
   cost_score.  Set (not observed) because it is a point-in-time snapshot,
   not a distribution. *)
let metric_cascade_provider_health_score =
  "masc_cascade_provider_health_score"

(* Context overflow ratio — set each time ContextOverflowImminent fires.
   Ratio is estimated_tokens / limit_tokens in [0.0, 1.0+]. *)
let metric_oas_context_overflow_ratio =
  "masc_oas_context_overflow_ratio"

(* OAS-level context compaction counter — incremented each time
   ContextCompactStarted fires from the event bus. *)
let metric_oas_context_compaction_total =
  "masc_oas_context_compaction_total"

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

(* Admission queue metrics — used in admission_queue_metrics.ml. *)
let metric_inference_queue_depth = "masc_inference_queue_depth"
let metric_inference_queue_inflight = "masc_inference_queue_inflight"
let metric_inference_queue_acquired = "masc_inference_queue_acquired_total"
let metric_inference_queue_wait = "masc_inference_queue_wait_seconds"
let metric_inference_queue_cancelled = "masc_inference_queue_cancelled_total"
let metric_inference_queue_rejected = "masc_inference_queue_rejected_total"
let metric_inference_queue_max_concurrent = "masc_inference_queue_max_concurrent"

(* Agent health metrics — used in transport_metrics.ml. *)
let metric_agent_heartbeat_age_seconds = "masc_agent_heartbeat_age_seconds"
let metric_agent_stale_total = "masc_agent_stale_total"

(* Core counters / gauges — used outside init. *)
let metric_mcp_requests = "masc_mcp_requests_total"
let metric_llm_inference_duration = "masc_llm_inference_duration_seconds"
(* Throughput histograms — derived from Agent_sdk inference_telemetry.timings.
   Split from masc_llm_inference_duration_seconds because wall-clock latency
   mixes prefill and decode phases; operators need them separately to tell
   "prompt ingestion is slow" apart from "generation is slow". Silent when
   the backend does not emit timings (Anthropic/Gemini). *)
let metric_llm_prompt_tok_per_sec = "masc_llm_prompt_tok_per_sec"
let metric_llm_decode_tok_per_sec = "masc_llm_decode_tok_per_sec"
(* Cascade attempt-liveness streaming histograms.
   Filled by cascade_attempt_liveness_observer via the recorder injected
   into L.step.  TTFT = time from request start to first non-Done chunk;
   TBT = inter-chunk gap during streaming. *)
let metric_cascade_ttfb_seconds = "masc_cascade_ttfb_seconds"
let metric_cascade_inter_chunk_seconds = "masc_cascade_inter_chunk_seconds"
let metric_after_turn_hook = "masc_after_turn_hook_total"
let metric_keeper_oas_on_stop = "masc_keeper_oas_on_stop_total"
let metric_keeper_oas_on_idle_escalated =
  "masc_keeper_oas_on_idle_escalated_total"
let metric_after_turn_telemetry_missing =
  "masc_after_turn_telemetry_missing_total"
let metric_after_turn_telemetry_zero_latency =
  "masc_after_turn_telemetry_zero_latency_total"
let metric_tasks = "masc_tasks_total"
let metric_errors = "masc_errors_total"
let metric_error_events = "masc_error_events_total"
let metric_workspace_route_failures = "masc_workspace_route_failures_total"
let metric_active_agents = "masc_active_agents"
let metric_pending_tasks = "masc_pending_tasks"
let metric_uptime_seconds = "masc_uptime_seconds"
let metric_goal_attainment_pct = "masc_goal_attainment_pct"
let metric_goal_attainment_measured = "masc_goal_attainment_measured"

(* PR-0.2.D: OCaml GC quick_stat sampler gauges.  Populated by
   [Gc_sampler.run] from the runtime [Gc.quick_stat ()] once per
   sampling interval.  Names follow the [masc_gc_*_words] /
   [masc_gc_*] convention so PromQL queries can group on the
   [masc_gc_] prefix.  Cumulative counters are exposed as Gauge
   because they are read as point-in-time runtime snapshots; PromQL
   [rate()] still works on monotonic-by-construction gauges. *)
let metric_gc_minor_words = "masc_gc_minor_words"
let metric_gc_major_words = "masc_gc_major_words"
let metric_gc_heap_words = "masc_gc_heap_words"
let metric_gc_live_words = "masc_gc_live_words"
let metric_gc_compactions = "masc_gc_compactions"
let metric_gc_promoted_words = "masc_gc_promoted_words"
let metric_memory_usage_bytes = "masc_memory_usage_bytes"

let metric_sse_connections_active = "masc_sse_connections_active"
let metric_sse_reconnects = "masc_sse_reconnects_total"
let metric_sse_idle_evictions = "masc_sse_idle_evictions_total"
let metric_sse_capacity_evictions = "masc_sse_capacity_evictions_total"
let metric_sse_write_failures = "masc_sse_write_failures_total"
let metric_sse_rejects = "masc_sse_rejects_total"
