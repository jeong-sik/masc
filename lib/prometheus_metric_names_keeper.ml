(** Private Prometheus metric-name constants split out of [Prometheus].

    Keep these modules pure: string constants only, no observer wiring or
    runtime registration side effects. *)

(* Keeper turn lifecycle (registered in init, incremented in
   keeper_unified_turn.ml). *)
let metric_keeper_turns = "masc_keeper_turns_total"
let metric_keeper_input_tokens = "masc_keeper_input_tokens_total"
let metric_keeper_output_tokens = "masc_keeper_output_tokens_total"
let metric_keeper_cache_creation_tokens =
  "masc_keeper_cache_creation_tokens_total"
let metric_keeper_cache_read_tokens =
  "masc_keeper_cache_read_tokens_total"
let metric_keeper_usage_anomalies =
  "masc_keeper_usage_anomalies_total"
let metric_keeper_total_cost_usd =
  "masc_keeper_total_cost_usd"
let metric_keeper_turn_scheduled =
  "masc_keeper_turn_scheduled_total"
let metric_keeper_turn_completed =
  "masc_keeper_turn_completed_total"
let metric_keeper_idle_seconds = "masc_keeper_idle_seconds"

(** #10530: keeper required-tool-contract violations (passive-only or
    text-only turns rejected by the keeper agent loop).
    Labels: keeper_name, kind \in \{passive,text_only\}. *)
let metric_keeper_contract_violations =
  "masc_keeper_contract_violations_total"

(** #12838: keepers detected as alive-but-stuck — non-Dead, non-paused,
    keepalive_running, but [proactive_rt.last_ts] has been frozen while
    autonomous turns kept advancing.  Per-keeper dedup window
    ([alive_but_stuck_dedup_ttl_sec]) bounds emission rate so a single
    stuck keeper does not flood the counter on every 30s sweep.
    Labels: keeper. *)
let metric_keeper_alive_but_stuck =
  "masc_keeper_alive_but_stuck_total"
let metric_keeper_alive_but_stuck_seconds =
  "masc_keeper_alive_but_stuck_seconds"
let metric_keeper_alive_but_stuck_threshold_seconds =
  "masc_keeper_alive_but_stuck_threshold_seconds"

(** #12838 follow-up: supervisor recovery requests emitted after an
    alive-but-stuck detection.  Each increment means the supervisor set
    [failure_reason] + [fiber_stop]/[fiber_wakeup] so the existing sweep
    path can force a crash/restart instead of leaving the keeper at
    detection-only.  Labels: keeper. *)
let metric_keeper_alive_but_stuck_recovery_requests =
  "masc_keeper_alive_but_stuck_recovery_requests_total"

(** #12838 follow-up: bounded recovery wakeups queued by
    [alive_but_stuck_scan].  Labels: keeper, outcome. *)
let metric_keeper_alive_but_stuck_recovery =
  "masc_keeper_alive_but_stuck_recovery_total"

(* #10047: [append_metrics_snapshot] failures in [keeper_turn.ml] and
   [keeper_unified_turn.ml] used to be log-only, masking state/metric
   divergence. Surface as a counter so dashboards can alert on silent
   metric drops and operators stop trusting metric jsonl as ground
   truth when keepers are running. *)
let metric_keeper_metric_emit_dropped =
  "masc_keeper_metric_emit_dropped_total"

(* #9953: counter of observed [context_max] values labelled by
   [keeper, model_used, resolved_model_id, context_max_bucket].
   The bucket label collapses raw token counts into a small set
   of strings ("64k" | "128k" | "200k" | "256k" | "1m" | "other"
   | "zero") so the cardinality stays bounded.

   Operators use this counter to detect drift: the same
   ([model_used], [resolved_model_id]) pair should land in ONE
   bucket; observing two buckets means the resolution path
   produced different ceilings on different turns.  The 42% /
   17% / 41% split for [claude_code:auto] reported in #9953 is
   directly visible here as three counter rows. *)
let metric_keeper_context_max_observed =
  "masc_keeper_context_max_observed_total"

(* #10121: keeper turn livelock observer.  Each turn-start
   bumps [metric_keeper_turn_starts]; a re-start of the SAME
   turn id (turn counter did not advance) bumps the dedicated
   [metric_keeper_turn_reattempts].  Operators alert on
   [rate(masc_keeper_turn_reattempts_total[5m]) > 0] and pick
   up stuck-turn pairs without grepping log lines.  See also
   [metric_keeper_turn_regressions] when the FSM moves to a
   strictly LOWER turn id (very unusual; indicative of
   write_meta race losing an in-memory counter increment,
   #9733). *)
let metric_keeper_turn_starts = "masc_keeper_turn_starts_total"
let metric_keeper_turn_reattempts = "masc_keeper_turn_reattempts_total"
let metric_keeper_turn_regressions = "masc_keeper_turn_regressions_total"
let metric_keeper_turn_livelock_blocks =
  "masc_keeper_turn_livelock_blocks_total"

(* #9943: per-keeper turn-latency bucket counter.  Each completed
   turn lands in exactly one [latency_bucket] label so a Prometheus
   query like
     rate(masc_keeper_turn_latency_bucket_total{bucket="600-1200s"}[5m])
   directly surfaces slow-turn keepers without needing the JSONL
   ledger.  20-minute turns from oas_timeout_budget exhaustion
   (#9933, observed 1,204,542 ms = 20 min on taskmaster
   2026-04-24) appear in the [over_1200s] bucket and operators can
   alert on its rate.  Existing [masc_llm_inference_duration_seconds]
   histogram is labelled by [model] only (per-LLM-call latency); this
   counter labels by [keeper] (per-turn latency) and uses bucket
   strings instead of histogram observations so dashboards can group
   counts directly. *)
let metric_keeper_turn_latency_bucket =
  "masc_keeper_turn_latency_bucket_total"

(* #9933 follow-up: per-turn latency buckets split by the effective
   provider/model/cascade surface.  [metric_keeper_turn_latency_bucket]
   tells operators which keeper is slow; this counter answers the next
   operational question: which provider/cascade/profile is burning the
   timeout budget.  Labels are bounded by fleet size, configured model
   labels, configured cascades, channel vocabulary, and the five bucket
   names from [Keeper_unified_metrics.turn_latency_bucket]. *)
let metric_keeper_turn_latency_by_model_bucket =
  "masc_keeper_turn_latency_by_model_bucket_total"

(* P-DASH-01: provider cooldown skip counter.
   When a cascade's provider is in cooldown and the keeper
   fail-opens to a fallback cascade, increment this counter
   so operators can see how often cooldown is triggering
   cascade switches.  Labels: keeper, from_cascade, to_cascade. *)
let metric_keeper_provider_cooldown_skip =
  "masc_keeper_provider_cooldown_skip_total"

(* P-DASH-01: provider cooldown remaining seconds gauge.
   Exposes the current cooldown duration so operators can see
   which cascade is blocked and for how long without log parsing.
   Labels: keeper, cascade. *)
let metric_keeper_provider_cooldown_remaining_sec =
  "masc_keeper_provider_cooldown_remaining_sec"

(* P-DASH-13: provider block duration histogram.
   Records the duration (in seconds) for which a provider is placed
   in cooldown each time a cooldown is applied or extended.
   Labels: provider. *)
let metric_keeper_provider_block_duration_sec =
  "masc_keeper_provider_block_duration_sec"

(* #10569: board persist mutex acquire / held latency.  Recorded by
   [Board_core.with_persist_lock] so operators can distinguish
   queueing from syscall stall when keeper_board_post / comment / vote
   tool calls hit the 60s default tool timeout. *)
let metric_board_persist_lock_acquire_sec =
  "masc_board_persist_lock_acquire_sec"

let metric_board_persist_lock_held_sec =
  "masc_board_persist_lock_held_sec"

(* Backend filesystem mutex contention diagnostic.  Recorded by
   [Backend.FileSystem.with_observed_mutex] via
   [Backend.FileSystem.set_mutex_observers] (installed once from the
   main library at startup).  Scoped to writer paths
   (set / delete / set_if_not_exists). Read paths are not measured by
   these histograms. Labels: [op]. *)
let metric_backend_mutex_acquire_sec =
  "masc_backend_mutex_acquire_sec"

let metric_backend_mutex_held_sec =
  "masc_backend_mutex_held_sec"

(* P-DASH-02: turn queue depth gauge.  Semaphore waiters are
   observable via [autonomous_waiter_snapshot_for_test] but were
   only emitted as a debug log line.  Surfacing as a gauge lets
   operators alert on queue pressure without log parsing.
   Labels: keeper, channel. *)
let metric_keeper_turn_queue_depth =
  "masc_keeper_turn_queue_depth"

(* #10125: keeper supervisor sweep observability.

   The supervisor sweep is a Pulse loop that recovers crashed
   keepers.  When the loop fails to start (or stops), the fleet
   silently dies — keepers exit on cascade exhaustion and nobody
   restarts them.  Observed 2026-04-24: 14 keepers dead, supervisor
   "started" log line missing for 4h+ across a server restart.

   Two metrics surface the sweep liveness directly so dashboards
   can alert on absence instead of relying on a log grep:

   - [metric_keeper_supervisor_sweep_starts_total] — increments
     once each time [start_supervisor_sweep] actually creates a
     Pulse (i.e., once per process unless explicitly stopped).
     If the counter does not advance after a server restart, the
     supervisor never came up.
   - [metric_keeper_supervisor_last_sweep_unixtime] — gauge updated
     on every successful sweep beat.  Operator alert:
     [time() - masc_keeper_supervisor_last_sweep_unixtime > 90]
     means the sweep is stalled (default sweep interval is 30s). *)
let metric_keeper_supervisor_sweep_starts =
  "masc_keeper_supervisor_sweep_starts_total"
let metric_keeper_supervisor_last_sweep_unixtime =
  "masc_keeper_supervisor_last_sweep_unixtime"

(* #9770: counter for the [join_required] guard firing in
   [Mcp_server_eio_execute].  Production observed agents calling
   [masc_claim_next] (and similar) without [masc_join] first; the
   guard returns a polite error message but no fleet-wide signal
   exists for "how often does this happen, and which agent / tool
   pair is most affected".  Labels:
     [tool]: tool name that hit the guard (bounded by tool surface
       size, ~50).
     [agent_name]: agent that called the tool (bounded by fleet
       size, ~10).
     [reason]: ["room_uninitialized" | "agent_not_joined"].
   Cardinality: ~50 × ~10 × 2 = ~1000 series, safe for Prometheus. *)
let metric_tool_join_required_guard =
  "masc_tool_join_required_guard_total"

(* #9771: keeper turn-slot semaphore wait timeout counter.

   Production observed multiple keepers ([sangsu], [janitor],
   [ramarama], [qa-king], [taskmaster]) repeatedly skipping turns
   with [semaphore wait > 60s, peers holding slot] — peers holding
   the slot for a long-running OAS call (276s-963s observed) ran
   past the 60s wait budget, every waiting keeper timed out, and
   the WARN log was the only signal.

   Three observable channels at which the timeout fires:
     - [autonomous_queue_head]: fairness-FIFO head wait exceeded
     - [autonomous]: autonomous-track semaphore acquire timed out
     - [turn]: shared turn semaphore acquire timed out

   Labels: [keeper, channel].  Cardinality = ~10 keepers × 3
   channels = ~30 series, well within Prometheus best practice. *)
let metric_keeper_semaphore_wait_timeout =
  "masc_keeper_semaphore_wait_timeout_total"

let metric_keeper_turn_slot_bookkeeping_failures =
  "masc_keeper_turn_slot_bookkeeping_failures_total"

(* Goal-loop Observe contract: the Grafana p99 query consumes
   [masc_keeper_semaphore_wait_seconds_bucket] grouped by keeper and cascade.
   The generic [register_histogram] exporter currently exposes summaries, so
   keeper_turn_slot emits the cumulative bucket companion explicitly. *)
let metric_keeper_semaphore_wait_seconds =
  "masc_keeper_semaphore_wait_seconds"
let metric_keeper_semaphore_wait_seconds_bucket =
  "masc_keeper_semaphore_wait_seconds_bucket"

let metric_keeper_slot_yield_total =
  "masc_keeper_slot_yield_total"

let metric_timeout_policy_overshoot =
  "masc_timeout_policy_overshoot_total"

(* Keeper compaction (keeper_compact_policy.ml, tool_keeper.ml). *)
let metric_keeper_compactions = "masc_keeper_compactions_total"
let metric_keeper_compaction_ratio_change =
  "masc_keeper_compaction_ratio_change"
let metric_keeper_compaction_saved_tokens =
  "masc_keeper_compaction_saved_tokens_total"
let metric_keeper_operator_compact = "masc_keeper_operator_compact_total"
let metric_keeper_operator_clear = "masc_keeper_operator_clear_total"

(* #9943: per-keeper counter of "compaction triggered but
   resulted in no token reduction".  2026-04-24 audit found
   956/972 (98.4%) of recorded compaction snapshots had
   [compaction_before_tokens = compaction_after_tokens > 0],
   meaning a trigger fired but the strategy returned the same
   token budget — a silent failure mode that
   [masc_keeper_compactions_total] hides because that counter
   is incremented on the trigger rather than the savings.  This
   counter labels by [keeper, trigger] so dashboards separate
   "context_overflow_imminent triggered noop" from "manual
   trigger noop" etc. and operators can attribute blame.  Pair
   with [masc_keeper_compaction_saved_tokens_total] (already
   shipping) — that one tracks the bytes saved by the 1.6%
   that DID save anything; this one tracks the 98.4% that
   ran for nothing. *)
let metric_keeper_compaction_noop =
  "masc_keeper_compaction_noop_total"

(* Tier K5 — observability over the K4c per-keeper tool-emission
   accumulator registry. The registry is process-local; this gauge
   exposes its size so operators can alert on divergence from the
   active keeper count (a leak symptom would be registry size >
   live keeper count without trending down on teardown). *)
let metric_keeper_tool_emission_registry_size =
  "masc_keeper_tool_emission_registry_size"

(* Tier K6 — per-keeper tagged tool-emission push counter. Increments
   each time [Keeper_tool_emission_hook.push] captures a parsed JSON
   tool result into the keeper's accumulator. Lets operators rank
   keepers by multimodal output volume and detect silent emission
   stalls (a keeper that should be emitting goes flat). Labels:
   [keeper]. *)
let metric_keeper_tool_emission_pushes =
  "masc_keeper_tool_emission_pushes_total"

(* #13387: keeper tool diversity gauges. The count gauge gives
   dashboard/operator summaries a cheap per-keeper signal; the per-tool
   gauge identifies exactly which allowed tools are available but unused
   or below the diversity threshold. Labels:
   - [keeper] for the count gauge
   - [keeper, tool] for the per-tool gauge *)
let metric_keeper_tool_underused_allowed_count =
  "masc_keeper_tool_underused_allowed_count"

let metric_keeper_tool_underused_allowed =
  "masc_keeper_tool_underused_allowed"

(* #10349: keeper FS path rejection counter.  Pre-fix the
   user-facing read-path rejection strings carried the resolver's
   view of allowed sandbox roots (for example [(roots=[<list>])]
   and [(sandbox roots: [<list>])]) to the LLM.  Combined with
   the keeper identity drift documented in the issue (turn 433:
   contract emitted [masc-improver/Docker] while the resolver
   enumerated [analyst]'s sandbox), the error became a
   side-channel oracle for sibling sandboxes.

   The leak lives strictly in the user-visible string; the
   structured side-channel (Eio.traceln + this counter) keeps
   the rejection observable for operators without echoing the
   roots list back to the LLM.  Labels:
   - [kind] = "out_of_roots" (path resolved outside allowed)
              | "not_found_relative" (relative path matched no root) *)
let metric_keeper_path_rejection =
  "masc_keeper_path_rejection_total"

(* RFC-0026 PR-E-1.6 admission router shadow observation
   (keeper_admission_runtime.ml). Labels:
     - keeper:  keeper_id
     - outcome: legacy | dispatch | wait | surface

   "legacy" dominates until PR-E-1.7 wires the registry + bucket
   lookups via [Keeper_admission_runtime.set_*_lookup]. *)
let metric_keeper_admission_shadow_outcome =
  "masc_keeper_admission_shadow_outcome_total"

(* Keeper keepalive (keeper_keepalive.ml). *)
let metric_keeper_heartbeat_successes =
  "masc_keeper_heartbeat_successes_total"
let metric_keeper_heartbeat_failures =
  "masc_keeper_heartbeat_failures_total"
let metric_keeper_cleanup_tracking_failures =
  "masc_keeper_cleanup_tracking_failures_total"
let metric_keeper_dispatch_event_failures =
  "masc_keeper_dispatch_event_failures_total"
let metric_keeper_directive_failures =
  "masc_keeper_directive_failures_total"
let metric_keeper_tool_call_duration =
  "masc_keeper_tool_call_duration_seconds"
let metric_keeper_write_meta_failures =
  "masc_keeper_write_meta_failures_total"
let metric_write_meta_cas_retry_total =
  "masc_write_meta_cas_retry_total"
let metric_keeper_meta_read_failures =
  "masc_keeper_meta_read_failures_total"
let metric_keeper_approval_queue_failures =
  "masc_keeper_approval_queue_failures_total"
let metric_keeper_guards_failures =
  "masc_keeper_guards_failures_total"
let metric_keeper_profile_load_failures =
  "masc_keeper_profile_load_failures_total"
let metric_keeper_compact_audit_failures =
  "masc_keeper_compact_audit_failures_total"
let metric_keeper_fs_failures =
  "masc_keeper_fs_failures_total"
let metric_keeper_crash_persistence_failures =
  "masc_keeper_crash_persistence_failures_total"
let metric_keeper_generation_lineage_failures =
  "masc_keeper_generation_lineage_failures_total"
let metric_keeper_keepalive_signal_failures =
  "masc_keeper_keepalive_signal_failures_total"
let metric_keeper_board_signal_no_wake_total =
  "masc_keeper_board_signal_no_wake_total"
let metric_keeper_meta_json_failures =
  "masc_keeper_meta_json_failures_total"
let metric_keeper_tools_oas_failures =
  "masc_keeper_tools_oas_failures_total"
let metric_keeper_oas_hook_output_parse_failures =
  "masc_keeper_oas_hook_output_parse_failures_total"
let metric_keeper_turn_up_update_failures =
  "masc_keeper_turn_up_update_failures_total"
let metric_keeper_exec_tools_failures =
  "masc_keeper_exec_tools_failures_total"
let metric_keeper_circuit_breaker_trips =
  "masc_keeper_circuit_breaker_trips_total"
let metric_keeper_prompt_failures =
  "masc_keeper_prompt_failures_total"
let metric_keeper_run_context_failures =
  "masc_keeper_run_context_failures_total"
let metric_keeper_shell_ops_failures =
  "masc_keeper_shell_ops_failures_total"
let metric_keeper_tag_dispatch_failures =
  "masc_keeper_tag_dispatch_failures_total"
let metric_keeper_trace_emit_failures =
  "masc_keeper_trace_emit_failures_total"
let metric_keeper_transition_audit_failures =
  "masc_keeper_transition_audit_failures_total"
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
  "masc_keeper_metrics_sse_failures_total"
let metric_keeper_session_cleanup_failures =
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
