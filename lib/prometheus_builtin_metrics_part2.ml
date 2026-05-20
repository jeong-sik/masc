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
      ~inc_counter:(_ : inc_counter)
      ()
  =
  (* PR-0.2.C: pre-register cold/warm phase rows so /metrics shows a
     zero-value baseline before the first observation. The phase label
     is decided at observe-site in [Otel_dispatch_hook] based on a
     module-level startup time threshold. *)
  register_histogram
    ~name:metric_tool_call_duration
    ~help:"Tool call latency in seconds (phase=cold|warm)"
    ~labels:[ "phase", "cold" ]
    ();
  register_histogram
    ~name:metric_tool_call_duration
    ~help:"Tool call latency in seconds (phase=cold|warm)"
    ~labels:[ "phase", "warm" ]
    ();
  (* Inference admission queue metrics *)
  add
    metric_inference_queue_inflight
    "Concurrent inference calls holding an admission permit"
    `Gauge;
  add metric_inference_queue_depth "Callers waiting in the admission queue" `Gauge;
  add
    metric_inference_queue_max_concurrent
    "Configured max concurrent admission permits"
    `Gauge;
  add metric_inference_queue_acquired "Total admission permits acquired" `Counter;
  add
    metric_inference_queue_cancelled
    "Total admission waits cancelled by fiber cancellation"
    `Counter;
  add
    metric_inference_queue_rejected
    "Total admission requests rejected before execution. Labels: \
     surface=with_permit|try_with_permit, reason=host_resource_saturated"
    `Counter;
  register_histogram
    ~name:metric_inference_queue_wait
    ~help:"Time waiting in admission queue before exchanging for permit"
    ();
  (* LLM provider HTTP response counter — emitted by Llm_metric_bridge
     via the OAS Metrics.t on_http_status hook.  Labels are populated
     dynamically per call; no initial registration with zero-value rows
     is needed because inc_counter auto-creates the label series on
     first observation. *)
  add
    metric_llm_provider_http_status
    "Total HTTP responses from LLM providers, labeled by provider, model, and status code"
    `Counter;
  add
    metric_llm_provider_capability_drops
    "Total OAS capability drops from LLM providers, labeled by model and field"
    `Counter;
  add metric_llm_provider_cache_hits "Total OAS LLM cache hits, labeled by model" `Counter;
  add
    metric_llm_provider_cache_misses
    "Total OAS LLM cache misses, labeled by model"
    `Counter;
  add
    metric_llm_provider_requests_started
    "Total OAS LLM requests started, labeled by model"
    `Counter;
  add metric_llm_provider_errors "Total OAS LLM request errors, labeled by model" `Counter;
  add
    metric_llm_provider_errors_by_reason
    "Total OAS LLM request errors, labeled by model and bounded error_reason"
    `Counter;
  add
    metric_llm_provider_request_latency_clamped
    "Total OAS LLM request latency observations clamped before histogram emission, \
     labeled by provider, model, and reason"
    `Counter;
  add
    metric_llm_provider_retries
    "Total OAS LLM retries, labeled by provider, model, and attempt"
    `Counter;
  add
    metric_llm_provider_input_tokens
    "Total OAS LLM input tokens, labeled by provider and model"
    `Counter;
  add
    metric_llm_provider_output_tokens
    "Total OAS LLM output tokens, labeled by provider and model"
    `Counter;
  add
    metric_llm_provider_tool_calls
    "Total OAS LLM provider-emitted tool calls, labeled by provider and model"
    `Counter;
  add
    metric_llm_provider_circuit_state
    "Current OAS cascade circuit state, labeled by provider, model, and provider_key. \
     `Gauge values: 0=closed, 1=open, 2=half-open"
    `Gauge;
  add
    metric_fallback_triggered
    "Total fallback events across the LLM cascade pipeline, labeled by kind \
     (cascade_empty|capability_drop|cli_unsupported|...) and detail"
    `Counter;
  (* Cascade FSM metrics — emitted by cascade_metrics.ml. *)
  add
    metric_cascade_decisions
    "Total cascade routing decisions, labeled by \
     decision=accept|accept_on_exhaustion|try_next|exhausted"
    `Counter;
  add
    metric_cascade_fallbacks
    "Total cascade fallback events, labeled by \
     reason=call_err|accept_rejected|health_filter"
    `Counter;
  add
    metric_cascade_providers_exhausted
    "Total provider exhaustion events (all providers in cascade failed)"
    `Counter;
  add
    metric_cascade_routing_phase_overrides
    "Total phase-based cascade routing overrides, labeled by phase and from_cascade / \
     to_cascade"
    `Counter;
  (* Orphan metrics — used via inc_counter/set_gauge but previously
     never registered.  Auto-create still works, but registering here
     gives them a HELP description in /metrics output and a zero-value
     baseline so dashboards see "0" instead of "no data" before the
     first observation. *)
  add
    Keeper_metrics.metric_keeper_write_meta_failures
    "Total keeper meta-file write failures, labeled by keeper and phase"
    `Counter;
  add
    metric_write_meta_cas_retry_total
    "Total keeper meta write CAS retries, labeled by keeper_name"
    `Counter;
  add
    Keeper_metrics.metric_keeper_meta_read_failures
    "Total keeper meta-file read/parse failures, labeled by keeper and site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_approval_queue_failures
    "Total keeper approval queue failures, labeled by keeper and site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_guards_failures
    "Total keeper guard warnings, labeled by keeper and site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_profile_load_failures
    "Total keeper profile/TOML load failures, labeled by site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_compact_audit_failures
    "Total keeper compact audit failures (persist/prune/handle), labeled by keeper and \
     site"
    `Counter;
  (* V17 burst visibility: drain-loop observability for keeper_compact_audit. *)
  add
    Keeper_metrics.metric_keeper_compact_audit_drain_batches
    "Total keeper compact_audit drain-loop iterations (used with drain_batch_size_bucket \
     for mean batch size and burst detection)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_compact_audit_drain_batch_size_bucket
    "Keeper compact_audit drain batch size distribution. Closed-vocab bucket label: \
     0|1_9|10_49|50_99|100_499|500_plus. Burst >= 100/batch indicates 9-keeper \
     compaction storm or JSONL writer lag."
    `Counter;
  add
    Keeper_metrics.metric_keeper_fs_failures
    "Total keeper filesystem operation failures (ensure_dir/save_atomic), labeled by \
     path and site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_crash_persistence_failures
    "Total keeper crash/sp persistence write failures, labeled by site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_generation_lineage_failures
    "Total keeper generation lineage failures (index append/manifest save), labeled by \
     keeper and site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_keepalive_signal_failures
    "Total keeper keepalive signal failures (late-event rejected), labeled by keeper and \
     site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_board_signal_wakeup_capped_total
    "Total board signal wakeups dropped by configured fanout caps, labeled by kind"
    `Counter;
  add
    Keeper_metrics.metric_keeper_board_signal_no_wake_total
    "Total board signals (post_created/comment_added) that did not produce a wake \
     decision for a running keeper. Increments per (keeper, kind) when \
     [Keeper_world_observation.board_signal_wake_reason] returns [None] — i.e. no \
     explicit_mention, scope feed disabled, and (for comments) no external reply after a \
     self-comment. Operators alert on this counter when keepers should be reacting to a \
     known board signal: a high rate identifies keepers whose \
     [room_signal_prompt_enabled] / mention-target configuration drops legitimate \
     signals. Labels: keeper, kind=post_created|comment_added."
    `Counter;
  add
    Keeper_metrics.metric_keeper_meta_json_failures
    "Total keeper meta JSON failures (seed parse/unknown keys), labeled by site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_tools_oas_failures
    "Total keeper OAS tool failures (blocked/error result/deadlock), labeled by tool and \
     site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_hook_output_parse_failures
    "Total keeper OAS hook tool-output JSON parse failures, labeled by surface"
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_up_update_failures
    "Total keeper turn-up update failures (prompt cap/sandbox validation/preflight), \
     labeled by keeper and site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_exec_tools_failures
    "Total keeper exec tool failures (malformed structured payload), labeled by keeper \
     and tool"
    `Counter;
  add
    Keeper_metrics.metric_keeper_circuit_breaker_trips
    "Total keeper failure circuit breaker trips, labeled by keeper and failure_type"
    `Counter;
  add
    Keeper_metrics.metric_keeper_prompt_failures
    "Total keeper prompt render failures, labeled by prompt name"
    `Counter;
  add
    Keeper_metrics.metric_keeper_run_context_failures
    "Total keeper run context failures (checkpoint save), labeled by keeper"
    `Counter;
  add
    Keeper_metrics.metric_keeper_shell_ops_failures
    "Total keeper shell operation failures (R2 blocked), labeled by keeper"
    `Counter;
  add
    Keeper_metrics.metric_keeper_tag_dispatch_failures
    "Total keeper tag dispatch exceptions, labeled by tag"
    `Counter;
  add
    Keeper_metrics.metric_keeper_trace_emit_failures
    "Total keeper trace emit failures, labeled by keeper"
    `Counter;
  add
    Keeper_metrics.metric_keeper_transition_audit_failures
    "Total keeper transition audit store failures, labeled by site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_execution_receipt_failures
    "Total keeper execution receipt failures (unmapped/emit failed/stale broadcast), \
     labeled by keeper and site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_llm_bridge_failures
    "Total keeper LLM bridge failures (timeout/cancelled/error), labeled by site. The \
     bridge is a generic timeout helper that does not receive keeper context; keeper \
     attribution is recovered from the surrounding Log.Keeper line."
    `Counter;
  add
    Keeper_metrics.metric_keeper_shell_bash_failures
    "Total keeper shell bash blockages (destructive/hard mode/generic), labeled by \
     keeper and site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_rollover_failures
    "Total keeper rollover failures (lineage append, checkpoint save, invalid trace ID), \
     labeled by keeper and site"
    `Counter;
  add
    Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
    "Total post-turn lifecycle dispatch rejections, labeled by keeper and event"
    `Counter;
  add
    Keeper_metrics.metric_keeper_paused_state_persist_errors
    "Total keeper paused-state persistence failures, labeled by phase \
     (boot_resume_check|boot_resume_persist|directive) and reason \
     (read_meta_error|meta_missing)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_unexpected_tool_partial_tolerance
    "Total keeper turns that tolerated unexpected tool names because at least one valid \
     keeper tool call was present. Labeled by keeper_name and logged=true|false so WARN \
     suppression remains observable."
    `Counter;
  add
    Keeper_metrics.metric_keeper_dead_total
    "Total keeper transitions to Dead phase after the supervisor exhausts max_restarts. \
     Labeled by keeper and reason. Any rate >0 is operator-actionable: the supervisor \
     will not retry the keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_auto_resumed_total
    "Total keepers auto-resumed by the self-healing circuit breaker after the back-off \
     timer elapsed. Labeled by keeper. A positive rate means the system is self-healing \
     from transient provider outages."
    `Counter;
  add
    Keeper_metrics.metric_keeper_auto_resume_blocked_total
    "Total keepers whose auto-resume was blocked because the cascade health probe \
     reported unhealthy. Labeled by keeper and cascade. A positive rate means the health \
     gate is protecting the fleet from resuming into a still-failing cascade."
    `Counter;
  add
    Keeper_metrics.metric_keeper_supervisor_cleanup_failures
    "Total supervisor finally-cleanup failures suppressed to avoid Fun.Finally_raised. \
     Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_slot_force_released
    "Total turn-slot semaphores force-released because the holding fiber did not return \
     after the supervisor declared the keeper crashed. Labels: keeper, label \
     (turn|autonomous|reactive)."
    `Counter;
  add
    Keeper_metrics.metric_keeper_spawn_slot_denied
    "Total keeper launch/admission attempts denied before a fiber was started. Labels: \
     keeper, surface (supervisor|keepalive), reason \
     (fd_pressure_active|disk_pressure_active|fd_admission_blocked|disk_admission_blocked|\
     max_active_keepers)."
    `Counter;
  add
    Keeper_metrics.metric_keeper_registry_update_dropped
    "Total Keeper_registry.update_entry drops (caller raced a deregistration, no entry \
     found). Labeled by name. Sustained per-keeper rate => orphan turn fiber. Pairs with \
     masc_keeper_registry_orphan_threshold_breached_total."
    `Counter;
  add
    Keeper_metrics.metric_keeper_registry_orphan_threshold_breached
    "Total per-keeper threshold breach events: drop count crossed the \
     orphan_drop_threshold inside orphan_drop_window_sec. Edge-triggered (one increment \
     per breach window). Labeled by name."
    `Counter;
  add
    Keeper_metrics.metric_keeper_stale_watchdog_tick_failures
    "Total stale watchdog tick failures suppressed during poll. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_skip_idle_wake_resumed
    "Total cycles where an external wakeup_keeper / board signal cut a Skip_idle backoff \
     sleep short and the heartbeat cycle was resumed (cycle_continues_after_wake -> \
     true). Positive signal for the #12271 fix; pairs with \
     masc_keeper_stale_termination_by_class_total {class=idle_turn} which should drop in \
     proportion. Labels: keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_event_queue_override
    "RFC-0020 Rule 2 — total times run_smart_heartbeat_gate forced Keeper_heartbeat_smart.Emit. \
     The [reason] label disambiguates the two override paths: [event_queue] = the Event \
     Layer queue (Keeper_registry_event_queue.snapshot) held an unprocessed stimulus; \
     [durable_state] = the queue was empty but a durable world-observation signal \
     (#13078) called for a cycle resume before the stale-watchdog deadline. Pairs with \
     masc_keeper_skip_idle_wake_resumed: skip-idle-resumed measures the fiber_wakeup \
     hint path, this measures the queue / durable-signal payload paths. Labels: keeper, \
     reason (event_queue|durable_state)."
    `Counter;
  add
    Keeper_metrics.metric_keeper_stimulus_consumed
    "Total stimuli consumed at turn entry, classified by stimulus_class. Labels: keeper, \
     class (board_signal|bootstrap|alive_but_stuck_recovery|unsupported). Pairs with \
     masc_keeper_unsupported_stimulus_total for unsupported-only drill-down with payload \
     prefix."
    `Counter;
  add
    Keeper_metrics.metric_keeper_unsupported_stimulus
    "Unsupported stimuli consumed at turn entry — the dequeued payload did not match any \
     known stimulus class. Each increment represents a wake -> no_signal gap per #12684. \
     Labels: keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_near_exhaustion_total
    "Total keeper restart attempts at restart_count = max_restarts - 1, i.e. one failure \
     away from Dead. Soft pre-warning; labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_lifecycle_transitions
    "Total keeper lifecycle phase transitions emitted only when the registry phase \
     changes. Labeled by keeper, from_phase, and to_phase; deliberately omits \
     event/reason payloads to keep cardinality bounded."
    `Counter;
  add
    Keeper_metrics.metric_keeper_lifecycle_callback_failures
    "Total keeper callback failures that would otherwise hide lifecycle, SSE, \
     tool-call-log, or action-metric gaps. Labels: callback plus optional keeper at \
     per-keeper hook sites."
    `Counter;
  add
    metric_memory_pipeline_flushes
    "Total memory AfterTurn flush attempts. A success with zero records proves the \
     pipeline ran but had no episodic/procedural deltas; an error surfaces a hidden hook \
     failure. Labels: agent_name, outcome=success|error."
    `Counter;
  add
    metric_memory_pipeline_flush_records
    "Total memory records persisted by the AfterTurn bridge. Labels: agent_name, \
     tier=episodic|procedural."
    `Counter;
  add
    metric_memory_pipeline_flush_duration_seconds
    "Wall-clock seconds spent in the memory AfterTurn flush bridge. Labels: agent_name, \
     outcome=success|error."
    `Histogram;
  add
    Keeper_metrics.metric_keeper_event_bus_drain
    "Total per-turn OAS event-bus drain helper runs. Labels: site and \
     outcome=drained|empty."
    `Counter;
  add
    Keeper_metrics.metric_keeper_restart_attempts
    "Total supervisor restart attempts for crashed keepers. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_restart_outcomes
    "Total supervisor restart outcomes. Labeled by keeper and bounded \
     outcome=started|meta_unavailable."
    `Counter;
  add
    Keeper_metrics.metric_keeper_liveness_recovery_attempts
    "#12801 Total Liveness Recovery Supervisor attempts to auto-recover Dead keepers \
     whose root cause has cleared. Labeled by keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_liveness_recovery_outcomes
    "#12801 Total Liveness Recovery Supervisor outcomes. Labeled by keeper and \
     outcome=started|not_running|meta_missing|meta_read_failed|meta_write_failed."
    `Counter;
;;
