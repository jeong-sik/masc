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
  add metric_mcp_requests "Total MCP requests received" `Counter;
  add metric_llm_inference_duration "LLM inference request duration in seconds" `Histogram;
  add
    metric_llm_prompt_tok_per_sec
    "LLM prefill (prompt_eval) throughput in tokens/second from \
     inference_telemetry.timings.prompt_per_second. Per-turn observation labelled by \
     model and provider_kind. Silent for providers that do not emit timings \
     (Anthropic/Gemini); use masc_after_turn_telemetry_missing_total to detect that."
    `Histogram;
  add
    metric_llm_decode_tok_per_sec
    "LLM decode (predicted) throughput in tokens/second from \
     inference_telemetry.timings.predicted_per_second. Per-turn observation labelled by \
     model and provider_kind. Distinct from masc_llm_prompt_tok_per_sec: decode rate is \
     the hardware generation speed, prompt rate is the prefill ingestion speed."
    `Histogram;
  add
    metric_after_turn_hook
    "Times the keeper AfterTurn hook ran (labeled by model). Divergence from \
     masc_llm_inference_duration_seconds_count identifies missing telemetry."
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_on_stop
    "Times the keeper OnStop hook ran after an OAS response terminated. Labels: keeper, \
     stop_reason."
    `Counter;
  add
    Keeper_metrics.metric_keeper_oas_on_idle_escalated
    "Times the keeper OnIdleEscalated hook ran. Labels: keeper, severity, decision."
    `Counter;
  add
    metric_after_turn_telemetry_missing
    "AfterTurn responses where response.telemetry was None."
    `Counter;
  add
    metric_after_turn_telemetry_zero_latency
    "AfterTurn responses where telemetry was present but request_latency_ms was 0."
    `Counter;
  add
    metric_after_turn_response_content_empty
    "AfterTurn responses that completed without visible assistant text or tool \
     progress. Labels: keeper, stop_reason, shape."
    `Counter;
  add
    metric_oas_inference_telemetry_tokens
    "OAS InferenceTelemetry token histogram for events suppressed from SSE. Labels are \
     bounded to model_bucket, phase, and token_bucket; max token histogram cardinality \
     is 8 * 2 * 5 = 80 labelled series."
    `Histogram;
  add
    metric_oas_inference_prompt_tok_per_sec
    "OAS InferenceTelemetry prompt throughput histogram for events suppressed from SSE. \
     Labelled only by bounded model_bucket."
    `Histogram;
  add
    metric_oas_inference_decode_tok_per_sec
    "OAS InferenceTelemetry decode throughput histogram for events suppressed from SSE. \
     Labelled only by bounded model_bucket."
    `Histogram;
  add
    metric_oas_inference_cost_usd
    "OAS AgentCompleted cost_usd histogram. Labelled by bounded provider and \
     model_bucket; enables provider-level spend tracking plus per-model cost \
     distribution (P50/P99)."
    `Histogram;
  add metric_tasks "Total tasks processed" `Counter;
  add metric_errors "Total errors" `Counter;
  (* [type] label is bound by [Error_event_type.t] — adding a new value
     requires extending the closed sum and re-running every emit site
     through the compiler. *)
  add metric_error_events "Error events by type (parsing, missing_config)" `Counter;
  add
    metric_workspace_route_failures
    "Total workspace route filesystem/git/read exceptions, labeled by site"
    `Counter;
  add metric_active_agents "Currently active agents" `Gauge;
  add metric_pending_tasks "Tasks waiting to be claimed" `Gauge;
  add metric_uptime_seconds "Server uptime in seconds" `Gauge;
  add
    metric_goal_attainment_pct
    "Goal attainment percentage by goal_id. Use masc_goal_attainment_measured to \
     distinguish real 0% from unmeasured."
    `Gauge;
  add
    metric_goal_attainment_measured
    "Whether goal attainment percentage is currently measured by goal_id (1 = measured, \
     0 = unmeasured)."
    `Gauge;
  (* PR-0.2.D: OCaml runtime GC sampler gauges.  See [Gc_sampler]. *)
  add
    metric_gc_minor_words
    "Cumulative words allocated in the minor heap since program start (from \
     Gc.quick_stat)"
    `Gauge;
  add
    metric_gc_major_words
    "Cumulative words allocated in the major heap since program start (from \
     Gc.quick_stat)"
    `Gauge;
  add
    metric_gc_heap_words
    "Current size of the major heap in words (from Gc.quick_stat)"
    `Gauge;
  add
    metric_gc_live_words
    "Live words in the major heap at last sample (from Gc.quick_stat)"
    `Gauge;
  add
    metric_gc_compactions
    "Number of major-heap compactions since program start (from Gc.quick_stat)"
    `Gauge;
  add
    metric_gc_promoted_words
    "Cumulative words promoted from minor to major heap since program start (from \
     Gc.quick_stat)"
    `Gauge;
  add
    metric_memory_usage_bytes
    "Approximate live OCaml heap memory usage in bytes, derived from Gc.quick_stat \
     live_words and Sys.word_size"
    `Gauge;
  add metric_sse_connections_active "Active SSE connections" `Gauge;
  add metric_sse_reconnects "Total SSE reconnects (same session reattached)" `Counter;
  add metric_sse_idle_evictions "Total SSE clients evicted by idle reaper" `Counter;
  add
    metric_sse_capacity_evictions
    "Total SSE clients evicted due to max client capacity"
    `Counter;
  add metric_sse_write_failures "Total SSE write failures by reason" `Counter;
  add metric_sse_rejects "Total SSE connections rejected by storm guard" `Counter;
  (* #9953: context_max distribution per keeper / model / resolved
     model.  Operators query [count by (model_used, resolved_model_id)
     (masc_keeper_context_max_observed_total)] to detect drift —
     a count > 1 indicates the same model resolved to different
     ceilings on different turns. *)
  add
    Keeper_metrics.metric_keeper_context_max_observed
    "Total observed keeper context_max values, bucketed (labels: keeper, model_used, \
     resolved_model_id, context_max_bucket=64k|128k|200k|256k|1m|other|zero)"
    `Counter;
  (* #10121: keeper turn livelock observer counters.  Operator
     alert: rate(masc_keeper_turn_reattempts_total[5m]) > 0
     surfaces stuck (keeper, turn) pairs without grepping logs. *)
  add
    Keeper_metrics.metric_keeper_turn_starts
    "Total keeper turn starts (every dispatch increments, regardless of whether the turn \
     id is new or repeated)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_reattempts
    "Total keeper turn re-attempts: same turn id started again before the counter \
     advanced (livelock signal — #10121)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_regressions
    "Total keeper turn regressions: turn id moved to a strictly LOWER value than \
     previously observed (write_meta race losing an in-memory counter increment — #9733 \
     / #10121)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_livelock_blocks
    "Total keeper turn dispatches blocked by the stuck-turn livelock guard (labels: \
     keeper, reason=attempts_exhausted|stuck_age_exceeded)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_livelock_blocks_repeated
    "Total repeated keeper turn livelock blocks demoted to DEBUG (labels: keeper, \
     gate_kind)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_livelock_blocks_threshold_park
    "Total keeper turn livelock block streams that crossed the threshold-park boundary \
     (labels: keeper, gate_kind)"
    `Counter;
  (* #9943: per-keeper turn latency bucket distribution.  Each
     completed turn increments exactly one bucket.  Bucket vocabulary
     [under_60s | 60-300s | 300-600s | 600-1200s | over_1200s]. *)
  add
    Keeper_metrics.metric_keeper_turn_latency_bucket
    "Total keeper turn completions, bucketed by latency (labels: keeper, \
     bucket=under_60s|60-300s|300-600s|600-1200s|over_1200s)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_latency_by_model_bucket
    "Total keeper turn completions, bucketed by latency and effective model surface \
     (labels: keeper, channel, provider_kind, model_used, resolved_model_id, \
     cascade_profile, bucket=under_60s|60-300s|300-600s|600-1200s|over_1200s)"
    `Counter;
  (* #10125: supervisor sweep liveness.  `Counter increments on
     each [start_supervisor_sweep] that actually creates a Pulse;
     gauge advances on every successful sweep beat. *)
  add
    Keeper_metrics.metric_keeper_supervisor_sweep_starts
    "Total times keeper supervisor sweep Pulse was started (labels: base_path)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_supervisor_last_sweep_unixtime
    "Wall-clock unixtime of the most recent successful supervisor sweep beat (labels: \
     base_path).  Stale (> 2 × interval) means the sweep stalled."
    `Gauge;
  add
    metric_tool_join_required_guard
    "Total join-required guard rejections before tool execution (labels: tool, \
     agent_name, reason=room_uninitialized|agent_not_joined)"
    `Counter;
  add
    metric_tool_metrics_persist_dropped
    "Total JSONL records dropped by tool_metrics_persist because the bounded \
     write queue is full. No labels."
    `Counter;
  add
    metric_keeper_tool_call_log_queue_dropped
    "Total full-I/O keeper tool-call log records dropped because the bounded \
     async write queue is full. No labels."
    `Counter;
  add
    metric_tool_keeper_cache_cas_conflicts
    "Total tool_keeper.cached_text_by_key Atomic CAS retry events. Each \
     increment corresponds to one extra compute() call. No labels."
    `Counter;
  add
    metric_file_lock_table_cas_retries
    "Total File_lock_eio lock-table CAS retries across \
     prune_stale_entries and get_entry. No labels."
    `Counter;
  add
    metric_memory_jsonl_parse_drops
    "Total Memory_jsonl.parse_line silent drop events. \
     Labels: reason in {no_key | not_assoc | json_parse_error}. \
     Empty lines not counted."
    `Counter;
  add
    metric_tool_keeper_cache_ttl_parse_failures
    "Total tool_keeper.cache_ttl_seconds env-var parse fallback events. \
     Labels: env_var, reason in {invalid_float | negative_or_nan}."
    `Counter;
  add
    Keeper_metrics.metric_keeper_turn_queue_depth
    "Current keeper turn wait queue depth (labels: channel=autonomous_queue)"
    `Gauge;
  (* [kind] is bound by [Keeper_bookkeeping_failure_kind.t]; [op] is free-form
     dynamic context (e.g. ["drop_holder <label>"]) needed to
     disambiguate which bookkeeping callback failed. *)
  add
    Keeper_metrics.metric_keeper_turn_slot_bookkeeping_failures
    "Total keeper turn-slot release bookkeeping callbacks that could not complete while \
     preserving semaphore release (labels: op, kind=cancelled|exception)"
    `Counter;
  register_histogram
    ~name:Keeper_metrics.metric_keeper_semaphore_wait_seconds
    ~help:
      "Seconds spent waiting to acquire keeper turn semaphores (labels: keeper_name, \
       cascade_profile, channel)."
    ();
  register_histogram
    ~name:Keeper_metrics.metric_keeper_turn_phase_duration
    ~help:
      "Seconds a keeper turn dwelt in a single FSM phase before transitioning out. \
       Sample is recorded on every emit_transition with a known prior state. Labels: \
       keeper, from."
    ();
  (* P-DASH-13: provider block duration histogram.
     Records the duration (in seconds) for which a provider is placed in
     cooldown each time a cooldown is applied or extended.  Labels: provider. *)
  register_histogram
    ~name:Keeper_metrics.metric_keeper_provider_block_duration_sec
    ~help:
      "Duration in seconds for which a provider is placed into cooldown (observed each \
       time a cooldown is applied or extended). Labels: provider."
    ();
  (* #10569: board persist mutex diagnostic histograms.  acquire =
     wait-for-lock, held = inside-lock disk I/O.  Operators read
     these together to size the persist serialization bottleneck
     before deciding queue vs timeout-tuning. *)
  register_histogram
    ~name:metric_board_persist_lock_acquire_sec
    ~help:
      "Seconds spent waiting to acquire the board persist mutex. High values indicate \
       writer contention."
    ();
  register_histogram
    ~name:metric_board_persist_lock_held_sec
    ~help:
      "Seconds the board persist mutex is held by one fiber, covering the disk I/O \
       performed inside the lock."
    ();
  (* Backend filesystem mutex diagnostic histograms.  acquire =
     wait-for-write-lock, held = time spent in the write critical
     section. Together they let operators decide whether keeper storage
     I/O latency is queueing (acquire high) or filesystem work while
     holding the mutex (held high), without inferring from external symptoms.
     Labels: op in {set, delete, set_if_not_exists}. *)
  register_histogram
    ~name:metric_backend_mutex_acquire_sec
    ~help:
      "Seconds spent waiting to acquire the backend filesystem write mutex.  Labels: op."
    ();
  register_histogram
    ~name:metric_backend_mutex_held_sec
    ~help:
      "Seconds the backend filesystem mutex is held by one fiber, covering the write \
       critical section. Labels: op."
    ();
  add
    Keeper_metrics.metric_keeper_slot_yield_total
    "Total autonomous turn slot yields (successfully yielded and reacquired). Labels: \
     keeper."
    `Counter;
  add
    metric_timeout_policy_overshoot
    "Total cooperative-cancel timeout overshoots (labels: layer, origin)"
    `Counter;
  (* Keeper compaction metrics — emitted by keeper_compact_policy.ml *)
  add
    Keeper_metrics.metric_keeper_compactions
    "Total keeper compactions performed"
    `Counter;
  add
    Keeper_metrics.metric_keeper_compaction_ratio_change
    "Context ratio change after compaction (pre - post)"
    `Gauge;
  add
    Keeper_metrics.metric_keeper_compaction_saved_tokens
    "Total tokens removed by keeper context compaction"
    `Counter;
  (* #9943: noop compactions — trigger fired but strategy did
     not reduce token budget. *)
  add
    Keeper_metrics.metric_keeper_compaction_noop
    "Total compaction snapshots where before_tokens == after_tokens > 0 (compaction \
     triggered but produced no savings; labels: keeper, trigger)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_continuity_no_state
    "Total post-turn continuity observations where no parseable STATE snapshot was \
     present. The cooldown timestamp is still advanced; labels: keeper."
    `Counter;
  add
    Keeper_metrics.metric_keeper_tool_pair_repair
    "Total keeper reducer repairs that downgraded broken tool-call metadata to plain \
     text instead of fabricating tool results. Labels: keeper, kind \
     (dangling_tool_use|orphan_tool_result), site."
    `Counter;
  (* C1 (CRIT) from oas-internal-audit.html §6: compaction call site
     fabrication counter. Repaired messages also carry was_fabricated:true
     metadata plus bounded provenance. Kind label is a closed 2-value
     vocabulary tied directly to pair_repair_stats from
     Keeper_context_core.repair_broken_tool_call_pairs_with_stats. *)
  add
    Keeper_metrics.metric_keeper_compaction_pair_repair_fabrications
    "Total tool-call pair-repair downgrades at the compaction call site \
     (Keeper_compact_policy, after Context_compact_oas.compact + keeper fold reducer). \
     Incremented by pair_repair_stats counts, not by 1, so operators alert on \
     fabrication volume rather than call frequency. Labels: keeper, kind \
     (downgraded_tool_use|downgraded_tool_result)."
    `Counter;
  (* K5: per-keeper tool-emission accumulator registry size.
     Updated by Keeper_tool_emission_hook on register/drop. *)
  add
    Keeper_metrics.metric_keeper_tool_emission_registry_size
    "Number of keepers with a registered tool-emission accumulator (Tier K4c per-keeper \
     isolation registry size)"
    `Gauge;
  (* K6: per-keeper tagged tool-emission push count. *)
  add
    Keeper_metrics.metric_keeper_tool_emission_pushes
    "Total tagged tool results captured into the K4c per-keeper accumulator (labels: \
     keeper)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_tool_underused_allowed_count
    "Number of keeper-allowed tools that have no calls or are below the diversity \
     threshold (labels: keeper)"
    `Gauge;
  add
    Keeper_metrics.metric_keeper_tool_underused_allowed
    "Whether an allowed keeper tool is unused or below the diversity threshold (1=yes, \
     0=no; labels: keeper, tool)"
    `Gauge;
  (* Operator-initiated overflow recovery — emitted by tool_keeper.ml.
     [result] label is bound by [Keeper_operator_compact_result.t]; adding a
     new value requires extending the closed sum and re-running every
     emit site through the compiler. *)
  add
    Keeper_metrics.metric_keeper_operator_compact
    "Total operator-invoked masc_keeper_compact calls (labels: \
     result=ok|no_checkpoint|precondition|not_found)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_operator_clear
    "Total operator-invoked masc_keeper_clear calls (labels: preserve_system=true|false)"
    `Counter;
  (* Keeper heartbeat metrics — emitted by keeper_keepalive.ml *)
  add
    Keeper_metrics.metric_keeper_heartbeat_successes
    "Total keeper heartbeat successes"
    `Counter;
  add
    Keeper_metrics.metric_keeper_heartbeat_failures
    "Total keeper heartbeat failures (labels: keeper, site)"
    `Counter;
  add
    Keeper_metrics.metric_keeper_cleanup_tracking_failures
    "Total keeper cleanup_tracking failures in heartbeat finally (labels: keeper, site)"
    `Counter;
  register_histogram
    ~name:Keeper_metrics.metric_keeper_tool_call_duration
    ~help:
      "Keeper tool call latency in seconds, labeled by keeper, provider, tool, and \
       outcome"
    ();
  add
    metric_provider_prefix_cache_creation_tokens
    "Total provider prefix cache creation tokens (Anthropic)"
    `Counter;
  add
    metric_provider_prefix_cache_read_tokens
    "Total provider prefix cache read tokens (Anthropic)"
    `Counter;
  add
    metric_tool_call
    "Total keeper tool calls labeled by provider, tool, and outcome"
    `Counter;
  add
    metric_tool_input_validation
    "Total tool input validation outcomes labeled by tool, result, and reason"
    `Counter;
;;
