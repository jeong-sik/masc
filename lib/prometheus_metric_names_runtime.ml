(** Private Prometheus metric-name constants split out of [Prometheus].

    Keep these modules pure: string constants only, no observer wiring or
    runtime registration side effects. *)

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

(* Process-level FD gauges — used in init() and update_fd_gauges. *)
let metric_open_fds = "masc_process_open_fds"
let metric_fd_warn_threshold = "masc_process_fd_warn_threshold"

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
let metric_provider_prefix_cache_creation_tokens =
  "masc_provider_prefix_cache_creation_tokens_total"
let metric_provider_prefix_cache_read_tokens =
  "masc_provider_prefix_cache_read_tokens_total"
let metric_tool_call = "masc_tool_call_total"
let metric_tool_call_duration = "masc_tool_call_duration_seconds"
let metric_llm_provider_http_status = "masc_llm_provider_http_status_total"
let metric_llm_provider_request_latency =
  "masc_llm_provider_request_latency_seconds"
let metric_llm_provider_request_latency_clamped =
  "masc_llm_provider_request_latency_clamped_total"
let metric_llm_provider_capability_drops =
  "masc_llm_provider_capability_drops_total"
let metric_llm_provider_cache_hits = "masc_llm_provider_cache_hits_total"
let metric_llm_provider_cache_misses = "masc_llm_provider_cache_misses_total"
let metric_llm_provider_requests_started =
  "masc_llm_provider_requests_started_total"
let metric_llm_provider_errors = "masc_llm_provider_errors_total"
let metric_llm_provider_errors_by_reason =
  "masc_llm_provider_errors_by_reason_total"
let metric_llm_provider_retries = "masc_llm_provider_retries_total"
let metric_llm_provider_input_tokens = "masc_llm_provider_input_tokens_total"
let metric_llm_provider_output_tokens = "masc_llm_provider_output_tokens_total"
let metric_fallback_triggered =
  "masc_fallback_triggered_total"

(* Domain-specific counters not yet constant-ised. *)
let metric_anti_rationalization_fallback =
  "masc_anti_rationalization_fallback_total"
(* #10113: per-pattern + per-decision counter for the gate 2
   excuse substring detector.  [decision] distinguishes the
   three reachable outcomes:
   - [advisory_to_llm]: pattern detected, default mode → LLM evaluates
     with the pattern as a heuristic hint;
   - [terminal_reject]: pattern detected,
     [MASC_ANTI_RATIONALIZATION_GATE2_FAIL_CLOSED=true] →
     historical local reject (operator opt-in);
   - [advisory_safety_net_reject]: pattern detected, advisory
     mode, but the LLM evaluator was unavailable so the
     pattern was upgraded to a Reject (LLM-down safety net).
   Lets the operator measure false-positive vs true-positive
   ratio per pattern across deployments without grepping logs. *)
let metric_anti_rationalization_excuse_pattern =
  "masc_anti_rationalization_excuse_pattern_total"
let metric_board_truncated_posts = "masc_board_truncated_posts_total"
let metric_keeper_quantitative_claim_rejections =
  "masc_keeper_quantitative_claim_rejections_total"
let metric_cascade_strategy_decisions = "masc_cascade_strategy_decisions_total"
let metric_cascade_capacity_events = "masc_cascade_capacity_events_total"

(* RFC-0022 §9 attempt-liveness gate.  Counts would-be (Observe) and
   actual (Enforce) liveness kills broken down by failure class.
   Labels: [kind, mode, provider].

   [observed_total] is the per-attempt finalizer counter regardless of
   outcome (success | kill | wire_error). Useful for the kill-rate
   ratio kill / observed. *)
let metric_cascade_attempt_liveness_kill =
  "masc_cascade_attempt_liveness_kill_total"
let metric_cascade_attempt_liveness_observed =
  "masc_cascade_attempt_liveness_observed_total"
let metric_keeper_invariant_violations = "masc_keeper_invariant_violations_total"
let metric_keeper_fsm_edge_transitions =
  "masc_keeper_fsm_edge_transitions_total"
let metric_keeper_turn_fsm_transitions =
  "masc_keeper_turn_fsm_transitions_total"
let metric_keeper_turn_phase_duration =
  "masc_keeper_turn_phase_duration_seconds"
let metric_keeper_lifecycle_transitions =
  "masc_keeper_lifecycle_transitions_total"
let metric_fsm_guard_violation = "masc_fsm_guard_violation_total"
let metric_keeper_lifecycle_callback_failures =
  "masc_keeper_lifecycle_callback_failures_total"
let metric_memory_pipeline_flushes =
  "masc_memory_pipeline_flushes_total"
let metric_memory_pipeline_flush_records =
  "masc_memory_pipeline_flush_records_total"
let metric_memory_pipeline_flush_duration_seconds =
  "masc_memory_pipeline_flush_duration_seconds"
let metric_keeper_event_bus_drain = "masc_keeper_event_bus_drain_total"
let metric_keeper_supervisor_cleanup_failures =
  "masc_keeper_supervisor_cleanup_failures_total"
(* Increments each time [Keeper_turn_slot.force_release_holder_for] frees
   a slot held by a zombie fiber (typically because the fiber is stuck
   inside an LLM subprocess that did not honour cancellation). Without
   this path the slot stays held until process restart, starving the
   fleet behind the [reactive_turn_semaphore]. Labels: keeper, label
   ([turn] / [autonomous] / [reactive]). A positive rate means the
   force-release path is the only thing draining stuck slots, which is
   itself a signal that the upstream subprocess kill-on-cancel is
   incomplete and worth investigating. *)
let metric_keeper_slot_force_released =
  "masc_keeper_slot_force_released_total"
(* P0-2 (2026-05-07): observability for orphan turn loops.
   [_dropped] increments every time [Keeper_registry.update_entry] is
   called against a missing key (caller raced with deregistration).
   [_orphan_threshold_breached] increments once per breach event when
   the per-keeper drop count crosses [orphan_drop_threshold] inside
   [orphan_drop_window_sec]. Together they let operators tell a
   harmless single-update race from a stuck orphan fiber emitting 30+
   drops per turn. See masc-mcp 2026-05-07 verifier-loop incident. *)
let metric_keeper_registry_update_dropped =
  "masc_keeper_registry_update_dropped_total"
let metric_keeper_registry_orphan_threshold_breached =
  "masc_keeper_registry_orphan_threshold_breached_total"
let metric_keeper_stale_watchdog_tick_failures =
  "masc_keeper_stale_watchdog_tick_failures_total"
let metric_keeper_dead_total = "masc_keeper_dead_total"
(* Self-healing circuit breaker: incremented each time [sweep_and_recover]
   auto-resumes a keeper after its back-off timer has elapsed.  A rate >0
   means the system is self-healing; a zero rate while keepers accumulate
   [auto_resume_after_sec] means the sweep is not firing or the meta write
   is failing. Labels: keeper. *)
let metric_keeper_auto_resumed_total = "masc_keeper_auto_resumed_total"
(* Phase-3.5 health-gate block: incremented when the supervisor skips
   auto-resume because the keeper's cascade is unhealthy (failure ratio
   >= threshold).  Labels: keeper, cascade.  A positive rate means the
   health probe is actively protecting the fleet from resuming into a
   still-failing cascade. *)
let metric_keeper_auto_resume_blocked_total =
  "masc_keeper_auto_resume_blocked_total"
(* Positive signal for the Skip_idle + Woken gate-promotion path added
   by #12271. Increments every time run_smart_heartbeat_gate observes
   that an external wakeup_keeper call cut a Skip_idle backoff sleep
   short and the cycle was resumed (KeeperHeartbeat.tla HeartbeatTick
   action). A zero rate after operator-visible board signals to a Live
   keeper means the fix path is not firing — either the wakeup never
   reached the atomic, or a regression silently re-introduced
   MissedWakeup. Pair with stale_termination_by_class for full
   positive/negative coverage. Labels: keeper. *)
let metric_keeper_skip_idle_wake_resumed =
  "masc_keeper_skip_idle_wake_resumed_total"
let metric_keeper_event_queue_override =
  "masc_keeper_event_queue_override_total"
let metric_keeper_stimulus_consumed =
  "masc_keeper_stimulus_consumed_total"
let metric_keeper_unsupported_stimulus =
  "masc_keeper_unsupported_stimulus_total"
let metric_keeper_near_exhaustion_total = "masc_keeper_near_exhaustion_total"
let metric_keeper_restart_attempts =
  "masc_keeper_restart_attempts_total"
let metric_keeper_restart_outcomes =
  "masc_keeper_restart_outcomes_total"
(* #12801: Liveness Recovery Supervisor — auto-recover Dead keepers
   whose root cause has cleared.  [attempts] increments each time the
   scan selects a Dead keeper for recovery; [outcomes] breaks out the
   result by outcome label (started | not_running | meta_missing |
   meta_read_failed | meta_write_failed). Labels: keeper (for
   attempts) and keeper+outcome (for outcomes). *)
let metric_keeper_liveness_recovery_attempts =
  "masc_keeper_liveness_recovery_attempts_total"
let metric_keeper_liveness_recovery_outcomes =
  "masc_keeper_liveness_recovery_outcomes_total"
(* #12797: Cascade server-error score decay — provider deprioritised
   after recent 5xx events.  Increments each time a provider's server-
   error score drops the effective weight below the skip threshold.
   Labels: provider_key. *)
let metric_cascade_server_error_skip_total =
  "masc_cascade_server_error_skip_total"

(* 2026-05-05 fleet-stuck diagnosis: cascade A → B → A circular fallback
   creates a silent 600s timeout chain when every model in both
   cascades depends on the same provider that has stalled.  This
   counter increments once per [load_catalog] call when any
   fallback_cascade chain forms a cycle.  Labels: cascade (the entry
   point of the cycle).  Operators alert on this counter; cycle
   participants are listed in the WARN log. *)
let metric_cascade_fallback_cycle_detected_total =
  "masc_cascade_fallback_cycle_detected_total"
let metric_provider_health_probe_skipped =
  "masc_provider_health_probe_skipped_total"
let metric_provider_actual_health_status =
  "masc_provider_actual_health_status"
