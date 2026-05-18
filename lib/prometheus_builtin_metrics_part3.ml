(** Built-in metric registration chunk. *)

open Prometheus_builtin_metric_names

type metric_kind = [ `Counter | `Gauge | `Histogram ]

type register_histogram =
  name:string -> help:string -> ?labels:(string * string) list -> unit -> unit

type inc_counter =
  string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit

let register
      ~(add : string -> string -> metric_kind -> unit)
      ~(register_histogram : register_histogram)
      ~(inc_counter : inc_counter)
      ()
  =
  add
    Keeper_metrics.metric_keeper_alive_but_stuck_recovery_requests
    "#12838 Total alive-but-stuck recovery requests. Each increment means the supervisor \
     requested a supervised keeper restart by setting failure_reason plus \
     fiber_stop/fiber_wakeup. Labeled by keeper."
    `Counter;
  add
    metric_cascade_server_error_skip_total
    "#12797 Total cascade label-ranking skips triggered by recent server error (5xx) \
     score decay. Labeled by provider_key."
    `Counter;
  add
    metric_cascade_fallback_cycle_detected_total
    "Total cascade fallback_cascade cycles detected during load_catalog. A cycle means \
     a provider stall propagates through the loop silently for 600s+ without escaping. \
     Labeled by [cascade] (cycle entry point)."
    `Counter;
  add
    metric_provider_health_probe_skipped
    "Total bootstrap/runtime-catalog provider health probes intentionally skipped as \
     advisory. Labels: provider_name, profile_name. Any non-zero value means provider \
     liveness was not actually probed at catalog validation time."
    `Counter;
  add
    metric_provider_actual_health_status
    "Last advisory provider health status observed by runtime catalog validation. \
     Values: 0=unknown/skipped, 1=healthy, 3=unhealthy. Labels: provider_name, \
     profile_name, model_id."
    `Gauge;
  add
    metric_provider_health_probe_error
    "Total provider health probe errors observed during runtime catalog validation. \
     `Counter complement to [metric_provider_actual_health_status] — the gauge only \
     shows the last observed status, so a sustained probe failure rate is otherwise \
     invisible.  Labels: provider_name, profile_name."
    `Counter;
  add
    Keeper_metrics.metric_keeper_passive_loop_detected_total
    "#12799 Total passive-loop detections: keeper issued only read-only tool calls for N \
     consecutive turns. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_passive_loop_streak
    "Current passive-loop streak length per keeper.  Resets to 0 on any \
     execution/completion turn.  Labeled by keeper."
    `Gauge;
  add
    Keeper_metrics.metric_keeper_passive_loop_streak_exceeded
    "Total passive-loop streak threshold exceeded events.  Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_required_tool_loop_detected_total
    "#13362 Total required-tool contract loops: keeper hit N consecutive actionable \
     required-tool failures before making execution/completion progress. Labeled by \
     keeper and kind."
    `Counter;
  add
    Keeper_metrics.metric_keeper_zombie_loop_detected_total
    "Goal-loop Observe counter for no-progress keeper loops. Emitted by the \
     passive/required-tool loop detector when progress-signalling turns make no \
     execution or completion progress. Labeled by keeper_name."
    `Counter;
  add
    Keeper_metrics.metric_keeper_required_tool_gate_suppressed_total
    "#13631 Total Require_tool_use gate suppressions caused by actionable affordances \
     whose visible keeper tool surface contains no contract-satisfying tool. Labeled by \
     affordance."
    `Counter;
  add
    Keeper_metrics.metric_keeper_consecutive_idle
    "Task-138 Current consecutive-idle streak (passive-only turns) per keeper.  Resets \
     to 0 on the next execution/completion turn.  Labeled by keeper."
    `Gauge;
  add
    Keeper_metrics.metric_keeper_last_productive_ts
    "Task-138 Unix timestamp of the most recent productive turn (execution/completion \
     class) per keeper.  0 until the keeper has produced anything.  Labeled by keeper."
    `Gauge;
  add
    Keeper_metrics.metric_keeper_tool_call_total
    "Total tool call routing outcomes. Labeled by tool (public name), routed_to \
     (internal name or 'none' for miss), and result (ok|miss)."
    `Counter;
  add
    Keeper_metrics.metric_keeper_profile_config_conflicts
    "Total keeper profile config conflicts between persona defaults and TOML overlays. \
     Labeled by field, resolution, and logged=true|false."
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_timeout_classifications
    "Total keeper OAS timeout classifications. Labeled by \
     classification=transient_network|structural_budget|other_timeout."
    `Counter;
  add
    Keeper_metrics.metric_keeper_no_tool_provider
    "Total no_tool_capable_provider errors. Labeled by keeper and cascade."
    `Counter;
  add
    Keeper_metrics.metric_keeper_proactive_outcome
    "Total proactive cycle outcomes. Labeled by keeper and \
     outcome=tool_called|noop|error."
    `Counter;
  add
    Keeper_metrics.metric_keeper_ollama_saturation_skip
    "Total keeper turns skipped because the resolved cascade is ollama-only and the \
     /api/ps probe reported zero available slots. Labeled by keeper and cascade."
    `Counter;
  add
    Keeper_metrics.metric_keeper_task_load_failures
    "Total Coord.get_tasks_raw exceptions while loading current task contract. Labeled \
     by keeper and phase=task_contract_load."
    `Counter;
  add
    Keeper_metrics.metric_keeper_tool_selection_failures
    "Total tool selection exceptions during per-turn tool set assembly. Labeled by \
     keeper and phase=topk_llm|tool_discovery."
    `Counter;
  add
    Keeper_metrics.metric_keeper_tool_policy_failures
    "Total tool-policy preset resolution failures (e.g. policy_config_not_loaded). \
     Labels: site, preset. The policy layer runs at module-init and preset resolution \
     time so it does not carry keeper context; keeper attribution is recovered from the \
     surrounding Log.Keeper line."
    `Counter;
  add
    metric_tool_policy_unloaded_query
    "Total tool-policy accessors called before init_policy_config loaded \
     config/tool_policy.toml. Labeled by accessor."
    `Counter;
  add
    metric_tool_policy_init_failed
    "Total server startup tool-policy initialization failures. Labeled by base_path."
    `Counter;
  add
    metric_cache_desync_cleared
    "Total stale task-state cache emissions cleared after reloading backlog truth. \
     Labeled by module and status."
    `Counter;
  add
    Keeper_metrics.metric_keeper_reconcile_failures
    "Total current-task reconciliation failures. Labeled by keeper and \
     phase=resolve_agent|task_id_parse|owned_tasks_query."
    `Counter;
  add
    Keeper_metrics.metric_keeper_decision_audit_flush_failures
    "Total decision audit ring-buffer flush failures causing audit data loss. Labeled by \
     keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_cancel
    "Total OAS execution cancellations in keeper_llm_bridge. Labeled by bucket (timeout \
     classification)."
    `Counter;
  add
    Keeper_metrics.metric_keeper_claim_auto_provision
    "Total task-claim auto-provision outcomes during keeper bootstrap. Labeled by \
     outcome and agent_name."
    `Counter;
  add
    metric_egress_audit_missing
    "Total egress audit entries where the keeper has no audit record. Labeled by keeper."
    `Counter;
  add
    metric_egress_audit_stale_orphan
    "Total egress audit entries that are stale or orphaned. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_toml_invalid
    "Total keeper TOML config parse failures falling back to persona. Labeled by keeper \
     and reason."
    `Counter;
  add
    Keeper_metrics.metric_keeper_persona_drift_missing
    "Total keeper persona file missing at expected path (config drift). Labeled by \
     keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_room_init_failures
    "Total supervisor room initialization failures during keeper bootstrap. Labeled by \
     keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_presence_sync_failures
    "Total supervisor presence sync failures after room init. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_self_preservation_universal
    "Total self-preservation UNIVERSAL suppression events where all keepers in a cohort \
     are suppressed and auto-recovery is OFF. Labeled by cohort (dominant failure key)."
    `Counter;
  add
    Keeper_metrics.metric_keeper_stale_storm_paused
    "Total keepers auto-paused due to stale termination storms. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_timeout_budget_loop_paused
    "Total keepers auto-paused due to repeated OAS timeout budget exhaustion. Labeled by \
     keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_cycle_exceptions
    "Total unhandled exceptions caught by the keeper main cycle loop. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_snapshot_write_failures
    "Total heartbeat snapshot persistence failures causing metric data loss. Labeled by \
     keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_progress_updated_line_failures
    "Total failures refreshing the Updated line in keeper progress.md. Missing progress \
     files are no-ops; non-zero rates mean progress metadata refresh is failing after a \
     successful meta write. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_sse_broadcast_failures
    "Total keeper SSE broadcast failures. Labeled by keeper and site when available."
    `Counter;
  add
    Keeper_metrics.metric_keeper_room_heartbeat_failures
    "Total room heartbeat failures (consecutive, leads to crash). Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_metrics_snapshot_failures
    "Total metrics snapshot write failures after keeper turns. Labeled by keeper and \
     site."
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_execution_errors
    "Total OAS execution errors (non-cancellation) in keeper_llm_bridge. Labeled by \
     keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_episode_create_failures
    "Total episode creation failures in keeper_agent_memory_episode. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_memory_activity_emit_failures
    "Total memory flush activity emit callback failures in keeper_agent_memory_episode. \
     Labeled by keeper and outcome."
    `Counter;
  add
    Keeper_metrics.metric_keeper_supervisor_sweep_failures
    "Total supervisor sweep failures in keeper_runtime periodic beat. Labeled by origin."
    `Counter;
  add
    Keeper_metrics.metric_keeper_toml_reconcile_sweep_failures
    "Total TOML reconcile sweep failures in keeper_runtime periodic beat. Labeled by \
     origin."
    `Counter;
  add
    Keeper_metrics.metric_keeper_tool_usage_flush_failures
    "Total tool usage JSONL flush failures in keeper_registry. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_livelock_blocks
    "Total turn dispatches blocked by livelock guard in keeper_unified_turn."
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_timeout_committed
    "Total wall-clock turn timeouts after committed mutating tools. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_error_after_tools
    "Total provider errors after committed mutating tool calls. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_cascade_sync_failures
    "Total cascade state synchronization failures (pause/resume/auto-pause). Labeled by \
     keeper and site."
    `Counter;
  add
    Keeper_metrics.metric_keeper_local_discovery_failures
    "Total local discovery readiness failures observed during create/turn paths. Labeled \
     by keeper and site."
    `Counter;
  add
    Keeper_metrics.metric_keeper_thinking_persist_failures
    "Total thinking content persistence failures in keeper_agent_run. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_checkpoint_failures
    "Total OAS checkpoint save or missing-checkpoint failures. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_memory_write_failures
    "Total memory write failures (notes/kinds) in keeper_agent_run. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_memory_consolidations
    "Total keeper memory-bank consolidation rows. Labels: keeper, \
     source=progress_consolidation|cross_trace_recurrence|other, \
     outcome=generated|persisted|evicted|write_failed."
    `Counter;
  add
    Keeper_metrics.metric_keeper_write_meta_cycle_failures
    "Total write_meta failures after turn/cycle in keeper_unified_turn. Labeled by \
     keeper and site."
    `Counter;
  add
    Keeper_metrics.metric_keeper_alert_persist_failures
    "Total alert JSONL write failures (alert/failed-channels/deadletter). Labeled by \
     kind."
    `Counter;
  add
    Keeper_metrics.metric_keeper_metrics_sse_failures
    "Total SSE broadcast failures during metrics compaction/handoff. Labeled by kind."
    `Counter;
  add
    Keeper_metrics.metric_keeper_dispatch_event_failures
    "Total keeper state-machine dispatch and keeper cycle side-effect failures. Labels \
     include keeper plus site, event, or reason depending on the emitting path."
    `Counter;
  add
    Keeper_metrics.metric_keeper_directive_failures
    "Total gRPC directive routing failures — target agent not in registry or directive \
     malformed (labels: keeper, site)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_session_cleanup_failures
    "Total session directory cleanup failures during keeper teardown."
    `Counter;
  add
    Keeper_metrics.metric_keeper_chat_store_failures
    "Total chat store append/load failures. Labeled by operation."
    `Counter;
  add
    Keeper_metrics.metric_keeper_observation_query_failures
    "Total world observation query failures (backlog counts, active agents, board \
     events). Labeled by operation."
    `Counter;
  add
    metric_persistence_read_drops
    "Total persisted read-model entries dropped during filesystem scans, labeled by \
     surface and reason"
    `Counter;
  add
    metric_persistence_utf8_repair
    "Total persistence JSON reads repaired after invalid UTF-8 was detected."
    `Counter;
  Safe_ops.set_persistence_utf8_repair_metric_hook (fun () ->
    inc_counter metric_persistence_utf8_repair ());
  add
    metric_discovery_history_failures
    "Total discovery history JSONL persistence/read/prune failures, labeled by site"
    `Counter;
  add
    metric_oas_sse_relay_retries
    "Total OAS SSE relay retry attempts, labeled by failed stage"
    `Counter;
  add
    metric_oas_sse_relay_drops
    "Total OAS SSE relay drops after retries or queue pressure, labeled by stage"
    `Counter;
  add
    metric_oas_sse_relay_queue_depth
    "Current in-memory OAS SSE relay retry queue depth"
    `Gauge;
  add
    metric_board_truncated_posts
    "Total board posts truncated due to size limits"
    `Counter;
  add
    metric_board_dispatch_flusher_start_outcomes
    "Total board flusher actor startup non-success outcomes (label \
     outcome=switch_finished|cas_exhausted). switch_finished = \
     start_flusher_actor raised Invalid_argument \"Switch finished!\"; \
     cas_exhausted = backend_state CAS retries depleted under contention."
    `Counter;
  add
    Keeper_metrics.metric_keeper_quantitative_claim_rejections
    "Total keeper board posts rejected because quantitative code claims lacked explicit \
     evidence"
    `Counter;
  add
    metric_anti_rationalization_fallback
    "Total anti-rationalization fallbacks fired (verifier LLM unavailable), labeled by \
     mode and cascade"
    `Counter;
  add
    metric_anti_rationalization_excuse_pattern
    "Total anti-rationalization excuse pattern detections at gate 2, labeled by pattern \
     and decision (advisory_to_llm | terminal_reject | advisory_safety_net_reject) — \
     #10113"
    `Counter;
  add
    metric_agent_heartbeat_age_seconds
    "Maximum observed heartbeat age across active agents (seconds)"
    `Gauge;
  add
    metric_agent_stale_total
    "Total agents marked stale due to missed heartbeats"
    `Counter;
  register_histogram
    ~name:metric_llm_provider_request_latency
    ~help:
      "Per-HTTP-request LLM latency from OAS on_request_end callback. Independent from \
       masc_llm_inference_duration_seconds (turn-scope) — this fires per provider HTTP \
       call regardless of keeper hook health. Labels: provider, model."
    ();
  register_histogram ~name:metric_llm_provider_streaming_first_chunk
    ~help:"OAS streaming time to first parsed chunk. Labels: provider, model." ();
  register_histogram ~name:metric_llm_provider_streaming_inter_chunk
    ~help:"OAS streaming inter-chunk gap. Labels: provider, model." ();
  add
    metric_llm_provider_streaming_first_chunk_invalid
    "Total OAS streaming first-chunk observations rejected before histogram emission \
     because the [ttfrc_ms] input was non-finite or non-positive. Labels: provider, \
     model, reason (not_finite | non_positive)."
    `Counter;
  add
    metric_llm_provider_streaming_inter_chunk_invalid
    "Total OAS streaming inter-chunk observations rejected before histogram emission \
     because the [inter_chunk_ms] input was non-finite or non-positive. Labels: \
     provider, model, reason (not_finite | non_positive)."
    `Counter;
  (* Process-level resource gauges.  Sampled on every /metrics scrape via
     [update_fd_gauges] so a monotonic ramp (fd leak) is visible in the
     time series before it crosses the OS limit and crashes the server.
     Evidence: 2026-04-16 production incident, 4029 CLOSE_WAIT sockets
     accumulated before the accept() path started failing. *)
  add
    metric_open_fds
    "Approximate count of open file descriptors for the server process (derived from \
     /dev/fd). Ramp indicates a socket/file leak."
    `Gauge;
  add
    metric_fd_warn_threshold
    "Threshold above which open_fds triggers a one-shot WARN log."
    `Gauge;
;;
