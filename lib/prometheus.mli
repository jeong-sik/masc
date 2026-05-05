(** Prometheus-Compatible Metrics for masc-mcp.

    Lightweight metrics collection with Prometheus text format export.
    Thread-safe via [Stdlib.Mutex] — works across OCaml 5 domains and
    during module initialisation before any Eio scheduler exists.

    @since 0.4.0 *)

(** {1 Types} *)

type label = string * string

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric = {
  name : string;
  help : string;
  metric_type : metric_type;
  mutable value : float;
  labels : label list;
}

(** {1 Metric Registration} *)

val register_counter :
  name:string -> help:string -> ?labels:label list -> unit -> unit

val register_gauge :
  name:string -> help:string -> ?labels:label list -> unit -> unit

val register_histogram :
  name:string -> help:string -> ?labels:label list -> unit -> unit

(** {1 Metric Updates} *)

val inc_counter :
  string -> ?labels:label list -> ?delta:float -> unit -> unit

val set_gauge :
  string -> ?labels:label list -> float -> unit

val inc_gauge :
  string -> ?labels:label list -> ?delta:float -> unit -> unit

val dec_gauge :
  string -> ?labels:label list -> ?delta:float -> unit -> unit

val observe_histogram :
  string -> ?labels:label list -> float -> unit

(** {1 Metric Queries} *)

val get_metric_value :
  string -> ?labels:label list -> unit -> float option

val metric_value_or_zero :
  string -> ?labels:label list -> unit -> float

val metric_total : string -> float

(** {1 Metric Name Constants}

    Shared SSOT between registration (in [init]) and call-sites in
    keeper/bridge modules. Importing [Prometheus.<constant>] ensures
    the compiler catches typos that would otherwise silently create
    dead series. *)

val metric_keeper_turns : string
val metric_keeper_input_tokens : string
val metric_keeper_output_tokens : string
val metric_keeper_cache_creation_tokens : string
val metric_keeper_cache_read_tokens : string
val metric_keeper_usage_anomalies : string

(** #10530: keeper required-tool-contract violations.
    Labels: keeper_name, kind \in \{passive,text_only\}. *)
val metric_keeper_contract_violations : string

(** #12838: keepers detected as alive-but-stuck.  Bounded to one
    increment per dedup window per keeper. Labels: keeper. *)
val metric_keeper_alive_but_stuck : string

(** #12838 follow-up: alive-but-stuck recovery requests.  Each increment
    means the supervisor requested a supervised restart via
    [failure_reason] plus [fiber_stop]/[fiber_wakeup]. Labels: keeper. *)
val metric_keeper_alive_but_stuck_recovery_requests : string

(** #12838 follow-up: bounded recovery wakeups queued by
    [Keeper_supervisor.alive_but_stuck_scan]. Labels: keeper, outcome. *)
val metric_keeper_alive_but_stuck_recovery : string

val metric_keeper_metric_emit_dropped : string
val metric_keeper_context_max_observed : string
(** #9953: bucketed counter for observed [context_max] values.
    Labels: [keeper, model_used, resolved_model_id,
    context_max_bucket].  Bucket vocabulary:
    [64k | 128k | 200k | 256k | 1m | other | zero]. *)
val metric_keeper_turn_starts : string
val metric_keeper_turn_reattempts : string
val metric_keeper_turn_regressions : string
val metric_keeper_turn_livelock_blocks : string
(** #10121: keeper turn livelock observer counters.  Labels:
    [keeper].  Re-attempt = same turn id started again before
    the counter advanced; regression = turn id moved strictly
    backwards (write_meta race symptom — #9733); livelock blocks
    are labeled by [keeper, reason]. *)
val metric_keeper_turn_latency_bucket : string
(** #9943: per-keeper turn latency distribution.  Labels:
    [keeper, bucket].  Bucket vocabulary:
    [under_60s | 60-300s | 300-600s | 600-1200s | over_1200s]. *)

val metric_keeper_turn_latency_by_model_bucket : string
(** #9933: per-keeper turn latency distribution split by effective
    model/cascade surface.  Labels:
    [keeper, channel, provider_kind, model_used, resolved_model_id,
    cascade_profile, bucket]. *)

val metric_keeper_provider_cooldown_skip : string
(** P-DASH-01: provider cooldown skip counter.  Incremented when a
    cascade is in provider cooldown and the keeper fail-opens to a
    fallback cascade.  Labels: [keeper, from_cascade, to_cascade]. *)

val metric_keeper_provider_cooldown_remaining_sec : string
(** P-DASH-01: provider cooldown remaining seconds gauge.
    Exposes the current cooldown duration so operators can see
    which cascade is blocked and for how long.  Labels: [keeper, cascade]. *)

val metric_keeper_provider_block_duration_sec : string
(** P-DASH-13: provider block duration histogram.
    Records the duration (in seconds) for which a provider is placed
    in cooldown each time a cooldown is applied or extended.
    Labels: [provider]. *)

val metric_board_persist_lock_acquire_sec : string
(** #10569 diagnostic: time spent waiting to acquire the board
    persist mutex.  High values point to writer-side contention:
    if N concurrent fibers serialize through this lock and any one
    holds it for K seconds during disk I/O, the (N-1)-th waiter
    sees ~(N-1)*K acquisition latency.

    Used together with [metric_board_persist_lock_held_sec] to
    distinguish queueing (acquire high, held low) from syscall stall
    (acquire low, held high).  Recorded once per [with_persist_lock]
    entry. *)

val metric_board_persist_lock_held_sec : string
(** #10569 diagnostic: time spent inside the board persist lock,
    measured from acquisition to release.  Captures the actual disk
    I/O latency (append + rotate / atomic save) per persist call.

    Combined with [metric_board_persist_lock_acquire_sec] this
    gives operators the data to choose between (a) raising the
    per-board tool timeout, (b) introducing a write queue / batch,
    or (c) leaving the path synchronous when held time is already
    sub-second. *)

val metric_keeper_turn_queue_depth : string
(** P-DASH-02: turn queue depth gauge.  Semaphore waiter count
    surfaced so operators can alert on queue pressure without log
    parsing.  Labels: [keeper, channel]. *)

(** #10125: supervisor sweep liveness counters.  See {!Prometheus.ml}
    for the rationale.  Counter increments on each Pulse start;
    gauge advances on every successful beat. *)
val metric_keeper_supervisor_sweep_starts : string
val metric_keeper_supervisor_last_sweep_unixtime : string

val metric_tool_join_required_guard : string
(** #9770: count fires of the [join_required] guard in
    [Mcp_server_eio_execute].  Labels:
    [tool, agent_name, reason] with reason
    [room_uninitialized | agent_not_joined]. *)

val metric_keeper_semaphore_wait_timeout : string
(** #9771: counter for keeper turn-slot semaphore wait timeouts.
    Labels: [keeper, channel] with channel in
    [autonomous_queue_head | autonomous | turn]. *)

val metric_keeper_turn_queue_depth : string
(** P-DASH-02: gauge for keeper turn wait queue depth.
    Labels: [channel] with [autonomous_queue] for the explicit autonomous
    FIFO wait queue. Reactive turn depth is intentionally not inferred from
    semaphore availability. *)

val metric_timeout_policy_overshoot : string
(** #9662: cooperative-cancel timeout overshoot counter emitted by
    [Timeout_policy].  Labels: [layer, origin]. *)

val metric_keeper_compactions : string
val metric_keeper_compaction_ratio_change : string
val metric_keeper_compaction_saved_tokens : string

(** #9943: per-keeper noop compaction counter.  Increments when
    a snapshot records [compaction_before_tokens =
    compaction_after_tokens > 0] — the trigger fired but the
    strategy returned the same token budget.  Pre-fix, 956/972
    (98.4%) of compaction snapshots in production were silent
    noops because [masc_keeper_compactions_total] counts
    triggers rather than savings.  Labels: [keeper, trigger]. *)
val metric_keeper_compaction_noop : string

(** Tier K5 — registry size for the per-keeper tool-emission
    accumulator (Tier K4c). Operators can alert on divergence from
    the active keeper count — a steady-state leak shows up as the
    gauge climbing past live keeper count without trending back
    down on keeper_down / supervisor cleanup. No labels. *)
val metric_keeper_tool_emission_registry_size : string

(** Tier K6 — per-keeper tagged tool-emission push counter. Labels:
    [keeper]. Incremented by [Keeper_tool_emission_hook.push] each
    time the PostToolUse hook captures a parsed JSON tool result
    into the keeper's accumulator. *)
val metric_keeper_tool_emission_pushes : string

val metric_keeper_operator_compact : string
val metric_keeper_operator_clear : string

(** #10349: counter incremented whenever
    [Keeper_alerting_path.resolve_keeper_read_path] rejects a
    path.  Replaces the previous user-facing leak of resolver
    allowed roots ([(roots=[<list>])] and
    [(sandbox roots: [<list>])]) which became a side-channel
    oracle for sibling sandboxes when keeper identity drifted
    across contract/gate/FS-resolver layers.  Labels:
    [kind="out_of_roots"|"not_found_relative"]. *)
val metric_keeper_path_rejection : string

val metric_keeper_admission_shadow_outcome : string
(** RFC-0026 PR-E-1.6 shadow observation. Counter; labels
    [keeper] and [outcome \in {legacy, dispatch, wait, surface}]. *)

val metric_keeper_heartbeat_successes : string
val metric_keeper_heartbeat_failures : string
val metric_keeper_cleanup_tracking_failures : string
val metric_keeper_tool_call_duration : string
val metric_keeper_write_meta_failures : string
val metric_keeper_meta_read_failures : string
val metric_keeper_approval_queue_failures : string
val metric_keeper_guards_failures : string
val metric_keeper_profile_load_failures : string
val metric_keeper_compact_audit_failures : string
val metric_keeper_fs_failures : string
val metric_keeper_crash_persistence_failures : string
val metric_keeper_generation_lineage_failures : string
val metric_keeper_keepalive_signal_failures : string

val metric_keeper_board_signal_no_wake_total : string
(** Total board signals that did not produce a wake decision for a
    running keeper. Increments per (keeper, kind) when
    [Keeper_world_observation.board_signal_wake_reason] returns
    [None] — no explicit_mention, scope feed disabled, and no
    external reply after a self-comment. Discoverability for the
    REPO_WAKE_UP audit finding: keepers with
    [room_signal_prompt_enabled = false] (Minimal preset default)
    silently drop board posts. Labels: keeper,
    kind=post_created|comment_added. *)

val metric_keeper_meta_json_failures : string
val metric_keeper_tools_oas_failures : string
val metric_keeper_turn_up_update_failures : string
val metric_keeper_exec_tools_failures : string
val metric_keeper_circuit_breaker_trips : string
val metric_keeper_prompt_failures : string
val metric_keeper_run_context_failures : string
val metric_keeper_shell_ops_failures : string
val metric_keeper_tag_dispatch_failures : string
val metric_keeper_trace_emit_failures : string
val metric_keeper_transition_audit_failures : string
val metric_keeper_execution_receipt_failures : string
val metric_keeper_llm_bridge_failures : string
val metric_keeper_shell_bash_failures : string
val metric_keeper_rollover_failures : string
val metric_keeper_task_load_failures : string
val metric_keeper_tool_selection_failures : string
val metric_keeper_tool_policy_failures : string
val metric_tool_policy_unloaded_query : string
val metric_tool_policy_init_failed : string
val metric_keeper_reconcile_failures : string
val metric_keeper_decision_audit_flush_failures : string
val metric_keeper_oas_cancel : string
val metric_keeper_claim_auto_provision : string
val metric_egress_audit_missing : string
val metric_egress_audit_stale_orphan : string
val metric_keeper_toml_invalid : string
val metric_keeper_persona_drift_missing : string
val metric_keeper_room_init_failures : string
val metric_keeper_presence_sync_failures : string
val metric_keeper_self_preservation_universal : string
val metric_keeper_stale_storm_paused : string
val metric_keeper_oas_timeout_budget_loop_paused : string
val metric_keeper_cycle_exceptions : string
val metric_keeper_snapshot_write_failures : string
val metric_keeper_sse_broadcast_failures : string
val metric_keeper_room_heartbeat_failures : string
val metric_keeper_turn_metrics_snapshot_failures : string
val metric_keeper_oas_execution_errors : string
val metric_keeper_episode_create_failures : string
val metric_keeper_supervisor_sweep_failures : string
val metric_keeper_toml_reconcile_sweep_failures : string
val metric_keeper_tool_usage_flush_failures : string
val metric_keeper_turn_livelock_blocks : string
val metric_keeper_turn_timeout_committed : string
val metric_keeper_turn_error_after_tools : string
val metric_keeper_cascade_sync_failures : string
val metric_keeper_thinking_persist_failures : string
val metric_keeper_checkpoint_failures : string
val metric_keeper_memory_write_failures : string
val metric_keeper_write_meta_cycle_failures : string
val metric_keeper_alert_persist_failures : string
val metric_keeper_metrics_sse_failures : string
val metric_keeper_dispatch_event_failures : string
val metric_keeper_directive_failures : string
val metric_keeper_session_cleanup_failures : string
val metric_keeper_chat_store_failures : string
val metric_keeper_observation_query_failures : string
val metric_keeper_lifecycle_dispatch_rejections : string
val metric_keeper_paused_state_persist_errors : string
val metric_keeper_unexpected_tool_partial_tolerance : string
val metric_keeper_require_tool_use_violations : string
(** #10091: labelled [keeper, has_current_task, contract_status]
    so fleet histograms can distinguish the active-task strict
    path from the no-task path covered by #10031. *)
val metric_keeper_tool_alias_canonicalizations : string
val metric_keeper_profile_config_conflicts : string
val metric_keeper_oas_timeout_classifications : string
val metric_keeper_no_tool_provider : string
(** #10474: counter incremented when a keeper's cascade has zero
    tool-capable providers.  Labels: keeper, cascade. *)
val metric_keeper_proactive_outcome : string
(** #10474: counter classifying each scheduled autonomous cycle outcome.
    Labels: keeper, outcome=[tool_called|noop|error]. *)
val metric_keeper_passive_loop_detected_total : string
(** #12799 Total passive-loop detections: keeper completed N consecutive turns
    using only passive read-only tools, violating the proactive contract.
    Incremented once per loop episode (streak resets on any execution-progress
    turn). Labels: [keeper]. *)

val metric_keeper_consecutive_idle : string
(** Task-138 Current consecutive-idle streak (passive-only turns) per
    keeper.  Resets to 0 on the next execution/completion turn.  Pairs
    with [metric_keeper_passive_loop_detected_total]: the counter fires
    only at the threshold crossing, this gauge lets dashboards see the
    streak rising before the latch.  Labels: [keeper]. *)

val metric_keeper_last_productive_ts : string
(** Task-138 Unix timestamp of the most recent productive turn
    (execution/completion class) per keeper.  Reads as 0 until the
    keeper has produced anything in this process.  Labels: [keeper]. *)
val metric_keeper_ollama_saturation_skip : string
(** PR-B: counter incremented when [run_keeper_cycle] skips a turn
    because the keeper's resolved cascade is ollama-only and the
    [/api/ps] probe reports zero process_available slots.  Labelled
    by [keeper] and [cascade] so dashboards can attribute starvation
    to specific cascade profiles. *)
val metric_persistence_read_drops : string
val metric_codex_cli_mcp_tool_omission : string
(** #10097: per-tool counter for codex_cli keeper-bound runtime
    MCP omissions.  Paired with a once-per-fingerprint WARN log
    so logs carry structural facts and Prometheus carries
    frequency. *)

val metric_telemetry_coverage_gap : string
(** #9520: total telemetry coverage gaps recorded. Labels:
    [source, producer, dashboard_surface, stale_reason]. This is the
    alertable pair to the durable
    [.masc/telemetry-coverage-gaps/YYYY-MM/DD.jsonl] store. *)

val metric_coord_telemetry_drop : string
(** #10358 (c1): total times [lib/coord.ml]'s lifecycle hook caught
    [Stdlib.Effect.Unhandled] and dropped its Audit_log + Telemetry
    pair because dispatch happened outside an Eio scheduler. Labels:
    [event_family] (one of [agent_lifecycle] / [task_transition] /
    [accountability]) and [event_kind] (the variant). For
    [agent_lifecycle], [event_kind] is one of [join] / [rejoin] /
    [leave] (3 values). For both [task_transition] and
    [accountability], [event_kind] uses the 8
    [Masc_domain.task_action_to_string] values: [claim] / [start] /
    [done] / [cancel] / [release] / [submit_for_verification] /
    [approve] / [reject]. Cardinality bound: 19 series (3 + 8 + 8).
    Non-zero rate means a production path is firing the lifecycle
    outside an Eio fiber and the corresponding audit/telemetry rows
    are missing — the silent root cause behind the [#10358] 5-tag → 2-tag
    durable-ledger attrition. *)

val metric_oas_bridge_timeout : string
(** #10094: labelled [caller, timeout_s] so operators can
    distinguish fantasy 60s budgets from intentional 120/180s
    budgets when both fire timeouts in the same session. *)
val metric_oas_bridge_cancel : string
(** #10942 mirror for [masc_oas_bridge].  Labelled [caller, bucket]
    where bucket is wall-class (fast<60s, short_tail<300s,
    mid_tail<600s, long_mid<1800s, long_tail>=1800s) — identical
    boundaries to [masc_keeper_oas_cancel_total] so PromQL can
    union the two sources for a fleet-wide bimodal view. *)
val metric_oas_sse_relay_retries : string
val metric_oas_sse_relay_drops : string
val metric_oas_sse_relay_queue_depth : string
val metric_mcp_tool_schema_count : string
val metric_mcp_tool_schema_tokens_approx : string

(** {1 Core counters / gauges} *)

val metric_mcp_requests : string
val metric_llm_inference_duration : string

val metric_llm_prompt_tok_per_sec : string
(** [masc_llm_prompt_tok_per_sec] — prefill throughput histogram.
    Observed in [Keeper_hooks_oas] after_turn when [response.telemetry.timings]
    is [Some] and [prompt_per_second] is positive. Labels: [model], [provider_kind]. *)

val metric_llm_decode_tok_per_sec : string
(** [masc_llm_decode_tok_per_sec] — decode throughput histogram.
    Observed alongside {!metric_llm_prompt_tok_per_sec} from the same turn
    when [predicted_per_second] is positive. Silent for providers that do
    not emit timings; inspect [masc_after_turn_telemetry_missing_total] to
    tell absence apart from zero. *)

val metric_after_turn_hook : string
val metric_after_turn_telemetry_missing : string
val metric_after_turn_telemetry_zero_latency : string
val metric_tasks : string
val metric_errors : string
val metric_error_events : string
val metric_active_agents : string
val metric_pending_tasks : string
val metric_uptime_seconds : string
val metric_sse_connections_active : string
val metric_sse_reconnects : string
val metric_sse_idle_evictions : string
val metric_sse_capacity_evictions : string
val metric_sse_write_failures : string
val metric_sse_rejects : string
val metric_provider_prefix_cache_creation_tokens : string
val metric_provider_prefix_cache_read_tokens : string
val metric_tool_call : string
val metric_tool_call_duration : string
val metric_llm_provider_http_status : string
val metric_llm_provider_request_latency : string
val metric_llm_provider_capability_drops : string
val metric_llm_provider_cache_hits : string
val metric_llm_provider_cache_misses : string
val metric_llm_provider_requests_started : string
val metric_llm_provider_errors : string
val metric_llm_provider_retries : string
val metric_llm_provider_input_tokens : string
val metric_llm_provider_output_tokens : string
val metric_fallback_triggered : string
(** §7.3.2 Zero Silent Failure measurement: aggregate counter for every
    fallback event across the cascade pipeline. Labels: [kind] enumerates
    the fallback class (cross_cascade, cascade_empty, capability_drop,
    cli_unsupported, …); [detail] carries the specific reason within
    the kind (e.g. for cross_cascade: source provider; for cascade_empty:
    rejection_reason_label). Detail counters
    ([masc_cross_cascade_fallback_total],
    [masc_llm_provider_capability_drops_total]) remain for per-class
    drill-down; this counter exists so the "Zero Silent Failure"
    dashboard panel has a single numerator across all classes. *)
val metric_board_truncated_posts : string
val metric_anti_rationalization_fallback : string
val metric_anti_rationalization_excuse_pattern : string
(** #10113: per-pattern + per-decision counter for the gate 2
    excuse substring detector.  Decision label is
    [advisory_to_llm | terminal_reject | advisory_safety_net_reject]. *)
val metric_cascade_strategy_decisions : string
val metric_cascade_capacity_events : string

val metric_cascade_attempt_liveness_kill : string
(** RFC-0022 §9 — would-be ([mode=observe]) and actual ([mode=enforce])
    in-attempt liveness kills, broken down by failure class.

    Labels: [kind, mode, provider] where:
    - [kind] ∈ [no_first_token | inter_chunk_idle | wall_exceeded | provider_error]
    - [mode] ∈ [observe | enforce]
    - [provider] is the cascade label that produced the attempt

    Use the {b observe}-mode counter to calibrate the per-profile
    budgets (cloud_fast / cloud_thinking / local_27b / local_70b_plus)
    against [scripts/diag-keeper-cycle.sh] before flipping any profile
    to {b enforce}. *)

val metric_cascade_attempt_liveness_observed : string
(** RFC-0022 PR-2 §3 — per-attempt finalizer counter regardless of
    outcome. Labels: [cascade], [provider], [outcome] ∈ {success |
    kill | wire_error}. The kill-rate is
    [kill_total / observed_total]. *)


val metric_cascade_server_error_skip_total : string
(** #12797 Total cascade label-ranking skips triggered by recent server-error
    (5xx) score decay for a provider.  Labels: [provider_key]. *)

val metric_cascade_fallback_cycle_detected_total : string
(** Total cascade fallback_cascade cycles detected during [load_catalog].
    A cycle means a provider stall propagates through every cascade in
    the loop silently for 600s+ without escaping.  Labels: [cascade]
    (the entry point of the detected cycle).  Discovered during the
    2026-05-05 fleet-stuck investigation:
    [big_three → glm_coding_plan_only → big_three]. *)

val metric_provider_health_probe_skipped : string
(** Total bootstrap/runtime-catalog provider health probes intentionally
    skipped as advisory. Labels: [provider_name, profile_name]. *)

val metric_provider_actual_health_status : string
(** Last advisory provider health status observed by runtime catalog
    validation. Values: 0=unknown/skipped, 1=healthy, 3=unhealthy.
    Labels: [provider_name, profile_name, model_id]. *)

val metric_keeper_invariant_violations : string

(** PR-I: cross-FSM edge transition counter. Labels: [edge] with values
    drawn from the static coupling graph documented in
    [docs/keeper-fsm-graph.dot]. Allowed values:
    - [ksm_to_kcl_routing] — phase decides cascade routing
      (Keeper_cascade_routing.select_cascade caller)
    - [ksm_to_kmc_compact_trigger] — Auto_compact_triggered dispatch
      (Keeper_registry compaction entry path)
    - [kmc_to_ksm_compact_completed] — Compaction_completed dispatch
    - [kcl_to_ktc_exhaustion] — cascade exhaustion observed during
      a turn, recorded into the registry's cascade_state
    Cardinality is bounded by the documented edge set (≤ 8 series on
    a fleet of any size). *)
val metric_keeper_fsm_edge_transitions : string

(** Step 4 (bloodflow plan): typed turn-FSM transition counter.

    Bumped once per [Keeper_turn_fsm.emit_transition] call so
    operators can chart turn-state distribution per keeper.
    Labels:
    - [from]   — previous [turn_state_label] ("-" if absent)
    - [to]     — new [turn_state_label]
    - [action] — TLA+ action name (e.g. "PhaseGateSkip", "ContractOk");
                 "unknown" when the edge is not in [classify_transition].
    - [keeper] — keeper name

    Distinct from [metric_keeper_fsm_edge_transitions], which
    encodes TLA+ edge names ("ksm_to_kcl_routing", etc.) as a
    single [edge] label.  This counter exposes the typed ADT
    states directly so downstream PromQL can filter on
    individual states (e.g.
    [count_over_time(masc_keeper_turn_fsm_transitions_total{to=~"failed:.*"}[5m])]).

    Cardinality upper bound: 10 turn_state labels × 10 prev × ~16
    keepers = ≤ 1600 series; reachable subset is much smaller. *)
val metric_keeper_turn_fsm_transitions : string

(** Keeper lifecycle phase transitions emitted by [Keeper_registry] only
    when the persisted registry phase changes. Labels:
    [keeper, from_phase, to_phase].  No event/reason label is included so
    free-form transition payloads cannot create unbounded series. *)
val metric_keeper_lifecycle_transitions : string

(** Cycle 43 (Tier I3 follow-up to fsm_guard smoke at
    [keeper_turn_fsm.ml:118]): runtime [@@fsm_guard] assert violations
    that the [Keeper_fsm_guard_runtime.wrap_unit] caught and recovered
    from. Bumped by the wrap helper before swallowing
    [Assert_failure] in counter mode (default), and also bumped before
    re-raising in assert mode ([MASC_FSM_GUARD_ASSERT=1]).

    Labels: [action, stage]. [action] is the spec-action name
    ([WakeupSignal], [HeartbeatTick], [TurnComplete],
    [SubmitTask], [AssignTask], [EmptyQueueSleep]) or a runtime
    contract surface such as [KeeperTurnFSM.Next]. [stage] is [pre],
    [post], or a compact contract edge such as [streaming->done].

    Operator signal: a non-zero value on any [action,stage] pair
    indicates the OCaml runtime drifted from the
    [specs/keeper-state-machine/Keeper{Heartbeat,TaskAcquisition}.tla]
    contract. The first violation per pair should trigger spec/code
    reconciliation review.

    Cardinality upper bound: ~7 actions × 2 stages × ~16 keepers
    ≤ 224 series; fleet-bounded. *)
val metric_fsm_guard_violation : string

(** PR-J: post-turn lifecycle callbacks raised exceptions that were
    silently swallowed before this counter existed. Labels: [callback]
    with values:
    - [on_compaction_started] — fired from
      [Keeper_post_turn.apply_post_turn_lifecycle]
    - [on_handoff_started] — fired from
      [Keeper_rollover.maybe_rollover_oas_handoff]
    Cardinality: ≤ 2 series, fleet-independent. *)
val metric_keeper_lifecycle_callback_failures : string
val metric_keeper_supervisor_cleanup_failures : string
val metric_keeper_stale_watchdog_tick_failures : string

(** PR-J: number of times the per-turn OAS event-bus drain helper ran,
    labelled by call-site so operators can attribute drain pressure
    (e.g. background poller vs. unsubscribe vs. retry path).
    Labels: [site, outcome]. [outcome] is [drained] (events were
    pulled) or [empty] (subscriber returned no pending events). *)
val metric_keeper_event_bus_drain : string
val metric_keeper_dead_total : string
(** Total keeper transitions to [Dead] phase after restart-budget exhaustion.
    Labeled by [keeper] and [reason]. Operators should alert on any rate >0:
    by construction Dead means the supervisor gave up and no further
    restart will be attempted. *)

val metric_keeper_auto_resumed_total : string
(** Total keepers auto-resumed by the self-healing circuit breaker in
    [Keeper_supervisor.sweep_and_recover] after the per-keeper back-off
    timer elapsed.  Labeled by [keeper].  A positive rate indicates the
    system is self-healing from transient provider outages without operator
    intervention.  A sustained zero rate while [auto_resume_after_sec] is
    set in meta files indicates a sweep or meta-write regression. *)

val metric_keeper_skip_idle_wake_resumed : string

(** RFC-0020 Rule 2 evidence — incremented every time
    [run_smart_heartbeat_gate] overrides a [Skip_busy] / [Skip_idle]
    decision because the Event Layer queue
    ([Keeper_registry.event_queue_snapshot]) was non-empty. A zero
    rate against ongoing keeper activity means either the queue
    write path (PR-C1 [wakeup_keeper ?stimulus]) is not firing or
    the smart heartbeat is already returning [Emit] on its own —
    either way operators can distinguish. Labels: [keeper]. *)
val metric_keeper_event_queue_override : string
(** Positive signal for the #12271 Skip_idle + Woken fix path. Increments
    each time [run_smart_heartbeat_gate] observes an external [wakeup_keeper]
    cut a Skip_idle backoff sleep short and the cycle was resumed
    ([cycle_continues_after_wake] -> [true]). Operator-meaningful pair with
    [masc_keeper_stale_termination_by_class_total] (class=idle_turn): a
    healthy fleet should show non-zero rates here proportional to inbound
    board signals, with the idle_turn kill rate trending toward zero. A
    zero rate after operator-visible signals suggests either the wakeup
    never reached the atomic, or a regression silently re-introduced
    MissedWakeup (KeeperHeartbeat.tla bug action).
    Labels: [keeper]. *)

val metric_keeper_stimulus_consumed : string
(** Total stimuli consumed at turn entry, classified by [stimulus_class].
    Labels: [keeper], [class]
    (board_signal|bootstrap|alive_but_stuck_recovery|unsupported).
    Pairs with [masc_keeper_unsupported_stimulus_total] for unsupported-only
    drill-down with payload prefix. *)

val metric_keeper_unsupported_stimulus : string
(** Unsupported stimuli consumed at turn entry — the dequeued payload
    did not match any known stimulus class. Each increment represents a
    wake -> no_signal gap per #12684. Labels: [keeper]. *)

val metric_keeper_near_exhaustion_total : string
(** Total times a keeper restart attempt landed at
    [restart_count = max_restarts - 1], i.e. one attempt away from Dead.
    Soft pre-warning; labeled by [keeper]. *)

val metric_keeper_restart_attempts : string
(** Total supervisor restart attempts for crashed keepers. Labels:
    [keeper]. *)

val metric_keeper_restart_outcomes : string
(** Total supervisor restart outcomes. Labels:
    [keeper, outcome]. Outcome is one of [started | meta_unavailable]. *)

val metric_keeper_liveness_recovery_attempts : string
(** #12801 Total Liveness Recovery Supervisor scan attempts to auto-recover
    Dead keepers. Increments each time a Dead keeper passes eligibility
    checks and a recovery is launched. Labels: [keeper]. *)

val metric_keeper_liveness_recovery_outcomes : string
(** #12801 Total Liveness Recovery Supervisor outcomes. Labels:
    [keeper, outcome]. Outcome is one of:
    - [started]: keeper re-registered and fiber launched successfully
    - [not_running]: keeper re-registered but not in Running state after launch
    - [meta_missing]: no keeper meta file found — recovery skipped
    - [meta_read_failed]: meta read I/O error — recovery skipped
    - [meta_write_failed]: meta write to clear [paused] failed *)

val metric_keeper_oas_timeout_budget_strike : string
(** PR-M (Leak 9): consecutive [oas_timeout_budget] cycle FAILED strikes.
    Labeled by [keeper] and [outcome]:
    - [outcome=warn]: strike below [oas_timeout_budget_strike_limit];
      cycle continues, supervisor not yet involved.
    - [outcome=promote]: strike at or above limit; [Keeper_fiber_crash]
      raised so [Keeper_supervisor.sweep_and_recover] respawns the
      fiber with a fresh context budget. Counter reset on any
      successful turn. *)

val metric_oas_bus_subscriber_stream_depth : string
val metric_oas_bus_publish_block_seconds : string
val metric_oas_bus_publish : string
val metric_runtime_ollama_probe_generate_skips : string
val metric_process_timeout : string
(** #9632: subprocess executions that exceeded their configured
    timeout. Labels: [program, timeout_sec]. *)
val metric_distributed_lock_acquire_failed : string
(** #9645: distributed lock acquire retry-budget exhaustions.
    Labels: [key, attempts]. *)

(** #10130: boot-time sweep of save_file_atomic orphan temp files.
    Labels: [size_class = empty | with_data]. *)
val metric_fs_atomic_orphans_cleaned : string

(** #9786: Auth rejects where bearer token owner does not match the
    requested agent_name.  Labels: [expected_agent, actual_agent].
    Dashboards alert on rate advancing after a server restart as a
    signal of shared credential state (connection pool / fork). *)
val metric_auth_bearer_token_mismatch : string

val metric_auth_strict_unknown_tool_denials : string
(** #10183: strict Auth rejects for unknown external tools.  Labels:
    [agent_name, tool_class] where [tool_class] is bounded to
    [empty | external]. *)

val metric_keeper_dispatch_event_failures : string
(** A1 track: counter for keeper registry dispatch_event failures that
    were previously silently dropped via [ignore].  Labels:
    [keeper, reason] where reason is [terminal_state] or
    [invalid_transition]. *)

val metric_keeper_directive_failures : string
(** gRPC directive routing failures — target agent not in registry
    or directive malformed.  Labels: [keeper, site]. *)

val metric_auth_credential_token_duplicate : string
(** #9786 follow-up: boot-time audit counter for credentials
    sharing the same token hash.  Increments once per boot per
    duplicate group.  Operator alert: any non-zero rate is a
    routing-ambiguity that must be rotated. *)

val metric_auth_credential_token_rotated : string
(** #10304 prevention counter.  Increments once per credential that
    boot-time repair rotates out of a shared bearer-token group.
    Labels: [token_hash_prefix, scope]. *)

val metric_config_credential_archived_starvation : string
(** Bare-form keeper credential files archived because they are dead after
    PR-3b1 starvation. Labels: [keeper_name]. *)

val metric_auth_credential_ambiguous_lookup : string
(** #9786 runtime complement: every [find_credential_by_token]
    lookup that hits N>=2 matches fires this counter.
    Labels: [first_match] = the agent_name that won the
    [List.find] race.  Distinguishes a stale audit warning
    from active wrong-agent serving. *)

val metric_silent_auth_token_resolve_error : string
(** PR-I (2026-04-25): mcp_server_eio_execute silently fell back to
    the caller's agent_name when [Auth.resolve_agent_from_token]
    returned [Error _].  Labels: [error_kind], [agent]. *)

val metric_silent_dashboard_actor_fallback : string
(** PR-I (2026-04-25): Server_auth.dashboard_actor_for_request
    silently fell back to [request_actor_hint] because the bearer
    token resolved to no agent ([Ok None]) or an error.
    Labels: [outcome] = "none" | "error". *)

val metric_auth_strict_would_reject : string
(** Phase A F2 (2026-04-27): paired with
    [metric_silent_auth_token_resolve_error] to measure "how many of
    those silent fallbacks would be rejected under Strict mode" before
    Phase B PR-2 actually performs the rejection.  Labels:
    [mode] = "off" | "dry_run" | "strict",
    [error_kind] = same kinds as silent_auth,
    [agent] = the alias the request would have kept. *)

val metric_empty_tool_universe_observed : string
(** Phase A F3 (2026-04-28): increments every time
    [keeper_agent_run] enters the [Keeper_tool_surface_empty] blocker
    branch — tool gate is required but the visible tool surface is
    empty.  Phase B PR-4 will promote this from "blocker emit" to a
    typed terminal state with LLM-visible feedback; this counter is
    the soak-window measurement that motivates the promotion.  Labels:
    [keeper_name],
    [turn_lane] = "text_only" | "tool_optional" | "tool_required"
                | "retry" | "tool_disabled",
    [fallback_used] = "true" | "false". *)

val metric_coord_join_normalize_outcome : string
(** RFC P3-a (2026-04-26): Coord.join identity normalization by
    [Keeper_identity.normalize_all_names].
    Labels: [outcome] = "ok" | "empty_input" | "persona_not_found"
    | "credential_missing" | "name_ambiguous" | "ephemeral_suffix_rejected".
    Non-ok outcomes reject [masc_join] at the fail-closed identity gate.
    Cross-reference [metric_silent_auth_token_resolve_error] for auth/name
    drift diagnosis. *)

val metric_config_unknown_keys_ignored : string
(** Unknown config keys ignored after warning. Labels: [file_path]. *)

val metric_governance_judge_unparseable : string
(** Governance/operator judge responses that remained unparseable after
    deterministic JSON recovery. Labels: [judge]. *)

val metric_governance_lenient_json_fallback_hit : string
(** Lenient_json fallback hits for governance/operator judge output.
    Labels: [judge]. *)


(** {1 Transport metrics} *)

val metric_sse_sessions : string
val metric_sse_broadcast_duration : string
val metric_sse_broadcast_events : string
val metric_sse_broadcast_failures : string
val metric_sse_external_subscriber_callback_failures : string
val metric_oas_sse_relay_drop_marker_failures : string
val metric_sse_stream_queue_depth : string
val metric_sse_queue_depth_avg : string
val metric_sse_queue_depth_max : string
val metric_sse_external_subscribers : string
val metric_grpc_active_streams : string
val metric_grpc_heartbeat_latency : string
val metric_grpc_subscribers : string
val metric_grpc_events_delivered : string
val metric_grpc_events_dropped : string
val metric_ws_sessions : string
val metric_ws_parse_cache_hits : string
val metric_ws_parse_cache_misses : string
val metric_ws_bytes_cache_hits : string
val metric_ws_bytes_cache_misses : string

(** PR-0.2.A (RFC 2026-04-masc-ide-strategy): cache lookup hit/miss
    counters. Labels: [cache] with values
    - ["eio"]      — [Cache_eio.get] (filesystem-backed key/value cache).
    - ["dashboard"] — [Dashboard_cache.get_or_compute] (in-memory
                     stale-while-revalidate cache for dashboard responses).
    Operator query: [hit_ratio = hits / (hits + misses)] per [cache] label
    quantifies cache effectiveness. Pure observation — registering or
    incrementing these counters never changes cache logic. *)
val metric_cache_hits_total : string

val metric_cache_misses_total : string
(** Companion to {!metric_cache_hits_total}; same [cache] label values. *)
val metric_ws_client_buffered_bytes : string
val metric_ws_client_acks : string
val metric_ws_throttled_deliveries : string
val metric_ws_slice_fanout_skipped : string
val metric_ws_bytes_sent : string
val metric_grpc_bytes_sent : string
val metric_ws_delta_built : string

val metric_ws_message_bytes : string
(** Histogram of WebSocket message payload size in bytes, observed at
    the wire boundary. Labels: [direction = send | recv]. Complements
    the [masc_ws_bytes_sent_total] counter by exposing per-message
    distribution (p50/p95/p99) so operators can distinguish a few
    large frames from many small frames. *)

val metric_grpc_backlog_replay_lines_scanned : string
(** Lines walked while replaying [.masc/backlog.jsonl] on a gRPC
    Subscribe RPC, including those filtered out by [since_seq]. *)

val metric_grpc_backlog_replay_events_replayed : string
(** Backlog events actually delivered (post-[since_seq] filter)
    on a gRPC Subscribe RPC. The gap between scanned-lines and
    replayed-events isolates wasted scan cost. *)

(** {1 Admission queue metrics} *)

val metric_inference_queue_depth : string
val metric_inference_queue_inflight : string
val metric_inference_queue_acquired : string
val metric_inference_queue_wait : string
val metric_inference_queue_cancelled : string
val metric_inference_queue_max_concurrent : string

(** {1 Agent health metrics} *)

val metric_agent_heartbeat_age_seconds : string
val metric_agent_stale_total : string

(** {1 OCaml GC sampler gauges (PR-0.2.D)}

    Populated by {!module:Gc_sampler} once per sampling interval from
    [Gc.quick_stat]. The cumulative word counters are exposed as
    [Gauge] (not [Counter]) because they are read from the OCaml
    runtime as point-in-time snapshots; PromQL [rate()] still works on
    monotonic-by-construction gauges. [heap_words] and [live_words]
    are point-in-time heap structure values, naturally a gauge. *)

val metric_gc_minor_words : string
(** Cumulative words allocated in the minor heap since program start. *)

val metric_gc_major_words : string
(** Cumulative words allocated in the major heap since program start. *)

val metric_gc_heap_words : string
(** Current size of the major heap, in words. *)

val metric_gc_live_words : string
(** Number of live words in the major heap at last sample. *)

val metric_gc_compactions : string
(** Number of major-heap compactions since program start. *)

val metric_gc_promoted_words : string
(** Cumulative words promoted from minor to major heap since program start. *)

val metric_keeper_stale_termination_total : string
val metric_keeper_stale_termination_by_class : string
val metric_keeper_oas_timeout_budget_watchdog_termination : string
val metric_keeper_stale_termination_threshold_breached : string
val metric_keeper_stale_termination_batch : string
val metric_keeper_stale_broadcast_emit_failures : string
  (* Centralized metric constants for inline string replacement. *)
val metric_keeper_tool_use_failure : string
val metric_keeper_tool_not_allowed : string
(** #13xxx: counter incremented every time the keeper dispatch layer
    denies a tool call because the tool is not in the keeper's allowlist.
    Surfaces preset drift (e.g. [board_core] group omitted from the
    keeper's [tool_groups]) and deny-list collisions as a Prometheus
    alert rather than requiring operators to grep
    [keepers/*.decisions.jsonl] after the fact.
    Labels:
    - [keeper] — keeper name
    - [tool]   — tool name attempted (bounded by tool registry, ~100)
    - [reason] — [not_in_candidate_set | denied_by_policy |
                  not_in_allow_set]
    Operator alert: [rate(masc_keeper_tool_not_allowed_total[5m]) > 0]
    on any [(keeper, tool)] pair means that keeper is looping without
    making progress — its BDI is requesting a tool that its preset
    does not permit. *)
val metric_after_turn_response_model_empty : string
val metric_after_turn_response_model_alias : string
val metric_pricing_catalog_miss : string
val metric_cost_emit_zero_source : string
val metric_cost_ledger_status : string
val metric_keeper_turn_gate_rejected_terminal : string
val metric_keeper_receipt_unmapped_disposition : string
val metric_keeper_bash_network_upgrade : string
val metric_keeper_bash_local_execution : string
val metric_keeper_docker_runtime_discarded : string
val metric_keeper_proactive_skip : string
val metric_keeper_stay_silent_loop_detected : string
val metric_keeper_usage_trust : string
val metric_keeper_usage_anomaly_reason : string
val metric_keeper_config_env_parse_failures : string
val metric_keeper_post_turn_wirein_failures : string
(* metric_keeper_meta_read_failures declared earlier in this interface (line 200) *)
val metric_keeper_recurring_failures : string
val metric_keeper_turn_cleanup_failures : string

(** {1 Process monitoring} *)

val approximate_open_fd_count : unit -> int

val fd_warn_threshold : int

val set_tool_schema_stats : count:int -> approx_tokens:int -> unit

(** {1 Prometheus Export} *)

val type_to_string : metric_type -> string

val labels_to_string : label list -> string

val to_prometheus_text : unit -> string

(** {1 Convenience Functions} *)

val record_request : unit -> unit
val record_task_completed : unit -> unit
val record_task_failed : unit -> unit
val record_error : ?error_type:string -> unit -> unit
val set_active_agents : int -> unit
val set_pending_tasks : int -> unit
val reconcile_active_agents_gauge : string -> unit
val update_uptime : unit -> unit

(** {1 Initialisation}

    Called automatically at module load via [let () = init ()].
    Idempotent — safe to call again. *)
val init : unit -> unit

(** {1 Diagnostics — issue #10682}

    The most recent EDEADLK backtrace captured by [with_lock]. [None]
    until the first re-entrant lock failure. Set side-effectfully when
    [Stdlib.Mutex.lock metrics_mutex] raises [Sys_error]. The backtrace
    pinpoints the offending re-entrant caller without requiring repro. *)
val last_deadlock_backtrace_for_test : unit -> string option
