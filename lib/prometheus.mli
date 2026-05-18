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

type metric =
  { name : string
  ; help : string
  ; metric_type : metric_type
  ; mutable value : float
  ; labels : label list
  }

(** {1 Metric Registration} *)

val register_counter : name:string -> help:string -> ?labels:label list -> unit -> unit
val register_gauge : name:string -> help:string -> ?labels:label list -> unit -> unit
val register_histogram : name:string -> help:string -> ?labels:label list -> unit -> unit

(** {1 Metric Updates} *)

val inc_counter : string -> ?labels:label list -> ?delta:float -> unit -> unit
val set_gauge : string -> ?labels:label list -> float -> unit
val inc_gauge : string -> ?labels:label list -> ?delta:float -> unit -> unit
val dec_gauge : string -> ?labels:label list -> ?delta:float -> unit -> unit
val observe_histogram : string -> ?labels:label list -> float -> unit

(** {1 Metric Queries} *)

val get_metric_value : string -> ?labels:label list -> unit -> float option
val metric_value_or_zero : string -> ?labels:label list -> unit -> float
val metric_total : string -> float


include module type of Prometheus_metric_names


(** #10097: per-(provider, tool) counter for keeper-bound runtime MCP
    omissions.  Paired with a once-per-fingerprint WARN log so logs
    carry structural facts and Prometheus carries frequency.

    RFC-0058 §2.4 / Phase 5.4: renamed from
    `masc_codex_cli_mcp_tool_omission_total` to keep provider identity
    out of the metric name; `provider` is now a label. *)
val metric_provider_mcp_tool_omission : string

(** #9520: total telemetry coverage gaps recorded. Labels:
    [source, producer, dashboard_surface, stale_reason]. This is the
    alertable pair to the durable
    [.masc/telemetry-coverage-gaps/YYYY-MM/DD.jsonl] store. *)
val metric_telemetry_coverage_gap : string

(** Total telemetry unified source discovery/read failures. Labels:
    [source] is {!Telemetry_unified.source_to_string}; [site] is a bounded
    read/discovery call-site vocabulary. *)
val metric_telemetry_unified_source_read_failures : string

(** Total tool-assignment telemetry decode/read failures. Labels:
    [site] is a bounded read/warm-up call-site vocabulary. *)
val metric_tool_assignment_telemetry_failures : string

(** Total {!Telemetry_observe} wrapper failures caught and returned as
    [Error]/default. Labels: [kind] is the wrapper call-site vocabulary.
    [Eio.Cancel.Cancelled] is re-raised and not counted. *)
val metric_telemetry_observe_failures : string

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
val metric_coord_claim_post_provision_failures : string
(** Total best-effort claim post-provision hook failures. Labels: [site]
    and [agent_name]. *)

(** #10094: labelled [caller, timeout_s] so operators can
    distinguish fantasy 60s budgets from intentional 120/180s
    budgets when both fire timeouts in the same session. *)
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

(** #10942 mirror for [masc_oas_bridge].  Labelled [caller, bucket]
    where bucket is wall-class (fast<60s, short_tail<300s,
    mid_tail<600s, long_mid<1800s, long_tail>=1800s) — identical
    boundaries to [masc_keeper_oas_cancel_total] so PromQL can
    union the two sources for a fleet-wide bimodal view. *)
val metric_oas_sse_relay_retries : string

val metric_oas_sse_relay_drops : string

(** Histogram populated from OAS [InferenceTelemetry] events that are
    intentionally not relayed over SSE. Labels: [model_bucket], [phase],
    and [token_bucket]. Cardinality bound: 8 model buckets * 2 phases *
    5 token buckets = 80 labelled series. *)
val metric_oas_sse_relay_queue_depth : string

(** Histogram populated from OAS [InferenceTelemetry] events that are
    intentionally not relayed over SSE. Labels: [model_bucket], [phase],
    and [token_bucket]. Cardinality bound: 8 model buckets * 2 phases *
    5 token buckets = 80 labelled series. *)
val metric_oas_inference_telemetry_tokens : string

(** Histogram populated from OAS [InferenceTelemetry.prompt_ms] and
    [prompt_tokens]. Labels: [model_bucket] only. *)
val metric_oas_inference_prompt_tok_per_sec : string

(** Histogram populated from OAS [InferenceTelemetry.decode_tok_s] or
    [decode_ms] plus [completion_tokens]. Labels: [model_bucket] only. *)
val metric_oas_inference_decode_tok_per_sec : string

(** Histogram populated from [AgentCompleted] [usage.cost_usd].
    Labels: [provider] and [model_bucket]. *)
val metric_oas_inference_cost_usd : string

val metric_mcp_tool_schema_count : string
val metric_mcp_tool_schema_tokens_approx : string

(** {1 Core counters / gauges} *)

include module type of Prometheus_core_metric_names

(** §7.3.2 Zero Silent Failure measurement: aggregate counter for every
    fallback event across the cascade pipeline. Labels: [kind] enumerates
    the fallback class (cascade_empty, capability_drop, cli_unsupported,
    …); [detail] carries the specific reason within the kind (e.g. for
    cascade_empty: rejection_reason_label). This counter exists so the
    "Zero Silent Failure" dashboard panel has a single numerator across all
    fallback classes. *)
val metric_board_truncated_posts : string

(** Counter for board flusher actor startup non-success outcomes.
    Closed-vocab label [outcome]: [switch_finished | cas_exhausted].
    Cardinality: 2 series. *)
val metric_board_dispatch_flusher_start_outcomes : string

val metric_anti_rationalization_fallback : string

(** #10113: per-pattern + per-decision counter for the gate 2
    excuse substring detector.  Decision label is
    [advisory_to_llm | terminal_reject | advisory_safety_net_reject]. *)
val metric_anti_rationalization_excuse_pattern : string

(** #10113: per-pattern + per-decision counter for the gate 2
    excuse substring detector.  Decision label is
    [advisory_to_llm | terminal_reject | advisory_safety_net_reject]. *)
val metric_cascade_strategy_decisions : string

val metric_cascade_capacity_events : string

(** RFC-0022 §9 — would-be ([mode=observe]) and actual ([mode=enforce])
    in-attempt liveness kills, broken down by failure class.

    Labels: [kind, mode, provider] where:
    - [kind] ∈ [no_first_token | inter_chunk_idle | wall_exceeded | provider_error]
    - [mode] ∈ [observe | enforce]
    - [provider] is the cascade label that produced the attempt

    Use the {b observe}-mode counter to calibrate bootstrap and
    observed-success budgets against [scripts/diag-keeper-cycle.sh]
    before flipping attempt liveness to {b enforce}. *)
val metric_cascade_attempt_liveness_kill : string

(** RFC-0022 PR-2 §3 — per-attempt finalizer counter regardless of
    outcome. Labels: [cascade], [provider], [outcome] ∈ {success |
    kill | wire_error}. The kill-rate is
    [kill_total / observed_total]. *)
val metric_cascade_attempt_liveness_observed : string

(** Histogram: time from cascade attempt start to first non-Done chunk (TTFT).
    Labels: [cascade], [provider] where [provider] is a bounded public
    provider bucket. *)
val metric_cascade_ttfb_seconds : string

(** Histogram: inter-chunk gap during streaming (TBT).
    Labels: [cascade], [provider] where [provider] is a bounded public
    provider bucket. *)
val metric_cascade_inter_chunk_seconds : string

(** Gauge: composite health score per cascade provider.
    [success_rate * speed_score * cost_score] in [0.0, 1.0].
    Labels: [provider_key]. *)
val metric_cascade_provider_health_score : string

(** Counter: cascade routing decisions emitted by [Cascade_fsm.decide].
    Labels: [decision] in [accept|accept_on_exhaustion|try_next|exhausted]. *)
val metric_cascade_decisions : string

(** Counter: cascade fallback transitions ([Try_next] outcomes).
    Labels: [reason] in [call_err|slot_full|accept_rejected|health_filter]. *)
val metric_cascade_fallbacks : string

(** Counter: terminal exhaustion events emitted when a cascade has no
    further provider candidates. *)
val metric_cascade_providers_exhausted : string

(** Counter: cascade routing phase overrides applied during decision.
    Labels: [phase], [from_cascade], [to_cascade]. *)
val metric_cascade_routing_phase_overrides : string

(** Gauge: context overflow ratio [estimated_tokens / limit_tokens] when
    [ContextOverflowImminent] fires.  Labels: [agent_name]. *)
val metric_oas_context_overflow_ratio : string

(** Counter: total context compaction actions from OAS event bus.
    Labels: [agent_name, trigger]. *)
val metric_oas_context_compaction_total : string

(** #12797 Total cascade label-ranking skips triggered by recent server-error
    (5xx) score decay for a provider.  Labels: [provider_key]. *)
val metric_cascade_server_error_skip_total : string

(** Total cascade fallback_cascade cycles detected during [load_catalog].
    A cycle means a provider stall propagates through every cascade in
    the loop silently for 600s+ without escaping.  Labels: [cascade]
    (the entry point of the detected cycle). *)
val metric_cascade_fallback_cycle_detected_total : string

(** Total bootstrap/runtime-catalog provider health probes intentionally
    skipped as advisory. Labels: [provider_name, profile_name]. *)
val metric_provider_health_probe_skipped : string

(** Last advisory provider health status observed by runtime catalog
    validation. Values: 0=unknown/skipped, 1=healthy, 3=unhealthy.
    Labels: [provider_name, profile_name, model_id]. *)
val metric_provider_actual_health_status : string

(** Total provider health probe errors observed during runtime catalog
    validation. Counter complement to
    [metric_provider_actual_health_status] — the gauge only shows the
    last observed status, so a sustained probe failure rate is
    otherwise invisible. Labels: [provider_name, profile_name]. *)
val metric_provider_health_probe_error : string

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

(** Histogram of seconds a keeper turn dwells in a single FSM phase
    before transitioning out. Sample is recorded by
    [Keeper_turn_fsm.emit_transition] whenever a [prev] state is
    supplied. Labels: keeper, from. *)

(** Keeper lifecycle phase transitions emitted by [Keeper_registry] only
    when the persisted registry phase changes. Labels:
    [keeper, from_phase, to_phase].  No event/reason label is included so
    free-form transition payloads cannot create unbounded series. *)

(** Cycle 43 (Tier I3 follow-up to fsm_guard smoke at
    [keeper_turn_fsm.ml:118]): runtime [@@fsm_guard] assert violations
    observed by [Keeper_fsm_guard_runtime.wrap_unit]. Bumped by the
    wrap helper before re-raising [Assert_failure]. FSM guard
    violations are fail-closed; [MASC_FSM_GUARD_ASSERT=0] no longer
    enables counter-only mode.

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

(** Keeper callback failures that would otherwise look like missing
    lifecycle, SSE, tool-call-log, or action-metric rows. Lifecycle
    callback failures also write a durable [telemetry_coverage_gap]
    row through [Keeper_callback_failure.record] or
    [Keeper_lifecycle_hooks.run] when runtime context is available.
    Labels: [callback] plus optional [keeper] at per-keeper OAS hook
    sites.

    Callback-only labels:
    - [on_compaction_started] — fired from
      [Keeper_post_turn.apply_post_turn_lifecycle]
    - [on_handoff_started] — fired from
      [Keeper_rollover.maybe_rollover_oas_handoff]
    - [work_discovery_nudge] — fired from
      [Keeper_run_tools.prepare_agent_setup] before-turn work discovery

    Per-keeper hook labels:
    - [gate_tool_call_log]
    - [after_turn_sse_broadcast]
    - [post_tool_log_write]
    - [pr_review_action_metrics_append]
    - [pr_work_action_metrics_append]
    - [on_tool_executed]
    - [on_error]
    - [on_tool_error]
    - [keeper_lifecycle_hook]

    Cardinality is bounded by fleet size times this callback vocabulary. *)
val metric_memory_pipeline_flushes : string

val metric_memory_pipeline_flush_records : string

(** Counter incremented every time [Keeper_registry.update_entry] races
    a deregistration and the update is dropped. Labeled by [name]. A
    sustained per-keeper rate signals an orphan turn fiber dispatching
    against a missing registry entry. See masc-mcp 2026-05-07
    verifier-loop incident. *)
val metric_memory_pipeline_flush_duration_seconds : string

(** Counter incremented once per breach event when [update_entry] drops
    cross [orphan_drop_threshold] inside [orphan_drop_window_sec] for a
    given [name]. Edge-triggered: subsequent drops in the same window
    bump only [metric_keeper_registry_update_dropped]. Labeled by [name]. *)

(** PR-J: number of times the per-turn OAS event-bus drain helper ran,
    labelled by call-site so operators can attribute drain pressure
    (e.g. background poller vs. unsubscribe vs. retry path).
    Labels: [site, outcome]. [outcome] is [drained] (events were
    pulled) or [empty] (subscriber returned no pending events). *)

(** Total keeper transitions to [Dead] phase after restart-budget exhaustion.
    Labeled by [keeper] and [reason]. Operators should alert on any rate >0:
    by construction Dead means the supervisor gave up and no further
    restart will be attempted. *)

(** Total keepers auto-resumed by the self-healing circuit breaker in
    [Keeper_supervisor.sweep_and_recover] after the per-keeper back-off
    timer elapsed.  Labeled by [keeper].  A positive rate indicates the
    system is self-healing from transient provider outages without operator
    intervention.  A sustained zero rate while [auto_resume_after_sec] is
    set in meta files indicates a sweep or meta-write regression. *)

(** Total keepers whose auto-resume was blocked in
    [Keeper_supervisor.sweep_and_recover] because the cascade health probe
    reported unhealthy (failure ratio >= threshold).  Labeled by [keeper]
    and [cascade].  A positive rate means the health gate is protecting
    the fleet from resuming into a still-failing cascade. *)

(** RFC-0020 Rule 2 evidence — incremented every time
    [run_smart_heartbeat_gate] overrides a [Skip_busy] / [Skip_idle]
    decision because the Event Layer queue
    ([Keeper_registry.event_queue_snapshot]) was non-empty. A zero
    rate against ongoing keeper activity means either the queue
    write path (PR-C1 [wakeup_keeper ?stimulus]) is not firing or
    the smart heartbeat is already returning [Emit] on its own —
    either way operators can distinguish. Labels: [keeper]. *)

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

(** Total stimuli consumed at turn entry, classified by [stimulus_class].
    Labels: [keeper], [class]
    (board_signal|bootstrap|alive_but_stuck_recovery|unsupported).
    Pairs with [masc_keeper_unsupported_stimulus_total] for unsupported-only
    drill-down with payload prefix. *)

(** Unsupported stimuli consumed at turn entry — the dequeued payload
    did not match any known stimulus class. Each increment represents a
    wake -> no_signal gap per #12684. Labels: [keeper]. *)

(** Total times a keeper restart attempt landed at
    [restart_count = max_restarts - 1], i.e. one attempt away from Dead.
    Soft pre-warning; labeled by [keeper]. *)

(** Total supervisor restart attempts for crashed keepers. Labels:
    [keeper]. *)

(** Total supervisor restart outcomes. Labels:
    [keeper, outcome]. Outcome is one of [started | meta_unavailable]. *)

(** #12801 Total Liveness Recovery Supervisor scan attempts to auto-recover
    Dead keepers. Increments each time a Dead keeper passes eligibility
    checks and a recovery is launched. Labels: [keeper]. *)

(** #12801 Total Liveness Recovery Supervisor outcomes. Labels:
    [keeper, outcome]. Outcome is one of:
    - [started]: keeper re-registered and fiber launched successfully
    - [not_running]: keeper re-registered but not in Running state after launch
    - [meta_missing]: no keeper meta file found — recovery skipped
    - [meta_read_failed]: meta read I/O error — recovery skipped
    - [meta_write_failed]: meta write to clear [paused] failed *)

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

val metric_oas_bus_capacity : string
(** Gauge: per-subscriber [Eio.Stream] capacity chosen at bus creation.
    Labels: [bus] names the MASC bus ([oas_runtime] | [masc_domain]),
    [policy] names the [Agent_sdk.Event_bus.backpressure_policy].
    Published once per bus at [Masc_event_bus_policy.create_bus] so
    operators can interpret [metric_oas_bus_subscriber_stream_depth]
    as a fraction of capacity. *)
val metric_runtime_ollama_probe_generate_skips : string

(** #9632: subprocess executions that exceeded their configured
    timeout. Labels: [program, timeout_sec]. *)
val metric_process_timeout : string

(** Background-task PID sidecar persistence failures. Labels:
    [site] = [write | read | read_parse | readdir | is_dir | unlink]. *)
val metric_bg_task_sidecar_failures : string

(** iter 30: unexpected (non-EAGAIN / EWOULDBLOCK / EINTR / EOF)
    errors raised by [Unix.read] inside [Bg_task.drain_fd_to_buf].
    Replaces the previous silent-EOF catch-all that hid genuine read
    errors (EBADF, EIO, ENOMEM, …) and lost any output between the
    error and process exit.  Labels are closed-vocabulary and
    cardinality-bounded:
    - [fd_kind] = [stdout | stderr] (call-site tagged).
    - [error_kind] = [unix_error | other] (typed match arm).
    Total cardinality: 4. *)
val metric_bg_task_drain_unexpected_errors : string

(** Build identity git probe failures. Labels:
    [site] = [commit_ts_git_capture | commit_ts_git_status | commit_ts_parse]. *)
val metric_build_identity_probe_failures : string

(** Build identity git probe failures. Labels:
    [site] = [commit_ts_git_capture | commit_ts_git_status | commit_ts_parse]. *)
val metric_distributed_lock_acquire_failed : string
(** #9645: distributed lock acquire retry-budget exhaustions.
    Labels: [key, attempts]. *)

(** #10130: boot-time sweep of save_file_atomic orphan temp files.
    Labels: [size_class = empty | with_data]. *)
val metric_fs_atomic_orphans_cleaned : string

include module type of Prometheus_identity_metric_names

(** {1 Transport metrics} *)

include module type of Prometheus_transport_metric_names

(** {1 Admission queue metrics} *)

val metric_inference_queue_depth : string
val metric_inference_queue_inflight : string
val metric_inference_queue_acquired : string
val metric_inference_queue_wait : string
val metric_inference_queue_cancelled : string

(** Total admission requests rejected before execution. Labels:
    [surface=with_permit|try_with_permit] and
    [reason=host_resource_saturated]. *)
val metric_inference_queue_rejected : string

(** Total admission requests rejected before execution. Labels:
    [surface=with_permit|try_with_permit] and
    [reason=host_resource_saturated]. *)
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

(** Cumulative words allocated in the minor heap since program start. *)
val metric_gc_minor_words : string

(** Cumulative words allocated in the major heap since program start. *)
val metric_gc_major_words : string

(** Current size of the major heap, in words. *)
val metric_gc_heap_words : string

(** Number of live words in the major heap at last sample. *)
val metric_gc_live_words : string

(** Number of major-heap compactions since program start. *)
val metric_gc_compactions : string

(** Cumulative words promoted from minor to major heap since program start. *)
val metric_gc_promoted_words : string

(** Approximate live OCaml heap memory usage in bytes, derived from
    [Gc.quick_stat.live_words] and [Sys.word_size]. *)
val metric_memory_usage_bytes : string

(** [masc_keeper_oas_run_timeout_total] counter incremented in the
    cascade FSM each time an [Agent.run] / [run_stream] returns
    [Llm_provider.Retry.Timeout]. The [source] label distinguishes the
    timeout origin so dashboards can attribute hangs to root cause:

    - [source="max_execution_time"] — agent_sdk's
      [with_optional_timeout] fired because the per-OAS-call ceiling
      ([max_execution_time_s], wired in PR #13923/#13933) was reached.
      This is the canonical signal for OAS call timeout enforcement.
    - [source="provider"] — transport-level timeout from the upstream
      provider (HTTP read deadline, gRPC deadline, etc.). The agent
      did not have [max_execution_time_s] set, or the timeout fired
      below the wrapper.

    Labels: cascade, provider, source. *)
(* Centralized metric constants for inline string replacement. *)

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
(* metric_keeper_meta_read_failures declared earlier in this interface (line 200) *)

(** RFC-0040: sender-side mention dedup decision counter.
    Labels: [outcome] with values
    [skipped|passed|no_target|bypassed]. *)
val metric_mention_dedup_decisions_total : string

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
