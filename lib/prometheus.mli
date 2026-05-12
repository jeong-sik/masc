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

(** {1 Metric Name Constants}

    Shared SSOT between registration (in [init]) and call-sites in
    keeper/bridge modules. Importing [Prometheus.<constant>] ensures
    the compiler catches typos that would otherwise silently create
    dead series. *)

(** Goal-loop Observe turn-success denominator. Labels: [keeper_name]. *)

(** Goal-loop Observe turn-success numerator. Labels: [keeper_name]. *)

(** Current keeper world-observation idle seconds. Updated from
    [observation.idle_seconds] during keeper metrics emission so long idle
    gaps are visible as a scrapeable gauge, not only in message text.
    Labels: [keeper_name]. *)

(** #10530: keeper required-tool-contract violations.
    Labels: keeper_name, kind \in \{passive,text_only\}. *)

(** #12838: keepers detected as alive-but-stuck.  Bounded to one
    increment per dedup window per keeper. Labels: keeper. *)

(** Current alive-but-stuck elapsed seconds. Labels: [keeper_name]. *)

(** Alive-but-stuck detector threshold seconds. Labels: [keeper_name]. *)

(** #12838 follow-up: alive-but-stuck recovery requests.  Each increment
    means the supervisor requested a supervised restart via
    [failure_reason] plus [fiber_stop]/[fiber_wakeup]. Labels: keeper. *)

(** #12838 follow-up: bounded recovery wakeups queued by
    [Keeper_supervisor.alive_but_stuck_scan]. Labels: keeper, outcome. *)

(** #9953: bucketed counter for observed [context_max] values.
    Labels: [keeper, model_used, resolved_model_id,
    context_max_bucket].  Bucket vocabulary:
    [64k | 128k | 200k | 256k | 1m | other | zero]. *)

(** #10121: keeper turn livelock observer counters.  Labels:
    [keeper].  Re-attempt = same turn id started again before
    the counter advanced; regression = turn id moved strictly
    backwards (write_meta race symptom — #9733); livelock blocks
    are labeled by [keeper, reason]. *)

(** #9943: per-keeper turn latency distribution.  Labels:
    [keeper, bucket].  Bucket vocabulary:
    [under_60s | 60-300s | 300-600s | 600-1200s | over_1200s]. *)

(** #9933: per-keeper turn latency distribution split by effective
    model/cascade surface.  Labels:
    [keeper, channel, provider_kind, model_used, resolved_model_id,
    cascade_profile, bucket]. *)

(** P-DASH-01: provider cooldown skip counter.  Incremented when a
    cascade is in provider cooldown and the keeper fail-opens to a
    fallback cascade.  Labels: [keeper, from_cascade, to_cascade]. *)

(** P-DASH-01: provider cooldown remaining seconds gauge.
    Exposes the current cooldown duration so operators can see
    which cascade is blocked and for how long.  Labels: [keeper, cascade]. *)

(** P-DASH-13: provider block duration histogram.
    Records the duration (in seconds) for which a provider is placed
    in cooldown each time a cooldown is applied or extended.
    Labels: [provider]. *)

(** #10569 diagnostic: time spent waiting to acquire the board
    persist mutex.  High values point to writer-side contention:
    if N concurrent fibers serialize through this lock and any one
    holds it for K seconds during disk I/O, the (N-1)-th waiter
    sees ~(N-1)*K acquisition latency.

    Used together with [metric_board_persist_lock_held_sec] to
    distinguish queueing (acquire high, held low) from syscall stall
    (acquire low, held high).  Recorded once per [with_persist_lock]
    entry. *)
val metric_board_persist_lock_acquire_sec : string

(** #10569 diagnostic: time spent inside the board persist lock,
    measured from acquisition to release.  Captures the actual disk
    I/O latency (append + rotate / atomic save) per persist call.

    Combined with [metric_board_persist_lock_acquire_sec] this
    gives operators the data to choose between (a) raising the
    per-board tool timeout, (b) introducing a write queue / batch,
    or (c) leaving the path synchronous when held time is already
    sub-second. *)
val metric_board_persist_lock_held_sec : string

(** Time spent waiting to acquire [Backend.FileSystem.t.mutex] before
    a write/delete operation.  Labels: [op] in
    {[set | delete | set_if_not_exists]}.

    Combined with [metric_backend_mutex_held_sec] this distinguishes
    keeper write contention (acquire high) from disk I/O stall (held
    high) inside the storage layer. Read paths are not measured by
    these histograms.

    Wired by [Backend.FileSystem.set_mutex_observers] from the main
    library at startup so that [masc_backend] does not depend on
    [Prometheus]. *)
val metric_backend_mutex_acquire_sec : string

(** Time spent inside the backend persist lock, from acquisition to
    release. Labels: [op] in {[set | delete | set_if_not_exists]}.

    Captures time spent in the write critical section, used together
    with [metric_backend_mutex_acquire_sec]. *)
val metric_backend_mutex_held_sec : string

(** P-DASH-02: turn queue depth gauge.  Semaphore waiter count
    surfaced so operators can alert on queue pressure without log
    parsing.  Labels: [keeper, channel]. *)

(** #10125: supervisor sweep liveness counters.  See {!Prometheus.ml}
    for the rationale.  Counter increments on each Pulse start;
    gauge advances on every successful beat. *)

(** #9770: count fires of the [join_required] guard in
    [Mcp_server_eio_execute].  Labels:
    [tool, agent_name, reason] with reason
    [room_uninitialized | agent_not_joined]. *)
val metric_tool_join_required_guard : string

(** #9771: counter for keeper turn-slot semaphore wait timeouts.
    Labels: [keeper, channel] with channel in
    [autonomous_queue_head | autonomous | turn]. *)

(** Counter for cancellation-safe keeper turn-slot release bookkeeping
    callbacks that could not complete. Labels: [op, kind] with
    kind in [cancelled | exception]. *)

(** Cumulative keeper turn-slot semaphore wait seconds. Labels:
    [keeper_name, cascade_profile, channel]. *)

(** Cumulative bucket counter for keeper turn-slot semaphore wait seconds.
    Labels: [keeper_name, cascade_profile, channel, le]. *)

(** P-DASH-02: gauge for keeper turn wait queue depth.
    Labels: [channel] with [autonomous_queue] for the explicit autonomous
    FIFO wait queue. Reactive turn depth is intentionally not inferred from
    semaphore availability. *)

(** #9662: cooperative-cancel timeout overshoot counter emitted by
    [Timeout_policy].  Labels: [layer, origin]. *)
val metric_timeout_policy_overshoot : string

(** #9943: per-keeper noop compaction counter.  Increments when
    a snapshot records [compaction_before_tokens =
    compaction_after_tokens > 0] — the trigger fired but the
    strategy returned the same token budget.  Pre-fix, 956/972
    (98.4%) of compaction snapshots in production were silent
    noops because [masc_keeper_compactions_total] counts
    triggers rather than savings.  Labels: [keeper, trigger]. *)

(** Tier K5 — registry size for the per-keeper tool-emission
    accumulator (Tier K4c). Operators can alert on divergence from
    the active keeper count — a steady-state leak shows up as the
    gauge climbing past live keeper count without trending back
    down on keeper_down / supervisor cleanup. No labels. *)

(** Tier K6 — per-keeper tagged tool-emission push counter. Labels:
    [keeper]. Incremented by [Keeper_tool_emission_hook.push] each
    time the PostToolUse hook captures a parsed JSON tool result
    into the keeper's accumulator. *)

(** #13387: per-keeper count of allowed tools that the diversity
    analyzer classifies as unused or below threshold. Labels:
    [keeper]. *)

(** #13387: per-tool gauge for allowed keeper tools that are unused
    or below threshold. Value is [1.0] when underused and [0.0]
    otherwise. Labels: [keeper], [tool]. *)

(** #10349: counter incremented whenever
    [Keeper_alerting_path.resolve_keeper_read_path] rejects a
    path.  Replaces the previous user-facing leak of resolver
    allowed roots ([(roots=[<list>])] and
    [(sandbox roots: [<list>])]) which became a side-channel
    oracle for sibling sandboxes when keeper identity drifted
    across contract/gate/FS-resolver layers.  Labels:
    [kind="out_of_roots"|"not_found_relative"]. *)

(** RFC-0026 PR-E-1.6 shadow observation. Counter; labels
    [keeper] and [outcome \in {legacy, dispatch, wait, surface}]. *)

val metric_write_meta_cas_retry_total : string

(** Total board signals that did not produce a wake decision for a
    running keeper. Increments per (keeper, kind) when
    [Keeper_world_observation.board_signal_wake_reason] returns
    [None] — no explicit_mention, scope feed disabled, and no
    external reply after a self-comment. Discoverability for the
    REPO_WAKE_UP audit finding: keepers with
    [room_signal_prompt_enabled = false] (Minimal preset default)
    silently drop board posts. Labels: keeper,
    kind=post_created|comment_added. *)

(** Total keeper OAS hook tool-output JSON parse failures. Labels:
    [surface] is [pr_review_action] or [pr_work_action]. *)
val metric_tool_policy_unloaded_query : string

val metric_tool_policy_init_failed : string
val metric_cache_desync_cleared : string
val metric_egress_audit_missing : string

(** Cascade state synchronization failures: pause/resume/auto-pause paths
    only. Local discovery refresh failures use
    [metric_keeper_local_discovery_failures] so dashboards can attribute
    distinct failure classes. *)
val metric_egress_audit_stale_orphan : string

(** Local discovery readiness failures observed during create/turn paths.
    Separated from [metric_keeper_cascade_sync_failures] so dashboards do
    not conflate cascade-state sync with discovery-refresh incompleteness. *)

(** #10091: labelled [keeper, has_current_task, contract_status]
    so fleet histograms can distinguish the active-task strict
    path from the no-task path covered by #10031. *)

(** #10474: counter incremented when a keeper's cascade has zero
    tool-capable providers.  Labels: keeper, cascade. *)

(** #10474: counter classifying each scheduled autonomous cycle outcome.
    Labels: keeper, outcome=[tool_called|noop|error]. *)

(** #12799 Total passive-loop detections: keeper completed N consecutive turns
    using only passive read-only tools, violating the proactive contract.
    Incremented once per loop episode (streak resets on any execution-progress
    turn). Labels: [keeper]. *)

(** #13362 Total required-tool contract loops: keeper hit N consecutive
    actionable required-tool failures before making execution/completion
    progress.  Incremented once per loop episode. Labels: [keeper, kind]. *)

(** Goal-loop Observe counter for no-progress keeper loops. Emitted by the
    passive/required-tool loop detector when progress-signalling turns make no
    execution or completion progress. Incremented once per loop episode.
    Labels: [keeper_name]. *)

(** #13631 Total Require_tool_use gate suppressions caused by actionable
    affordances whose visible keeper tool surface contains no
    contract-satisfying tool. Labels: [affordance]. *)

(** Task-138 Current consecutive-idle streak (passive-only turns) per
    keeper.  Resets to 0 on the next execution/completion turn.  Pairs
    with [metric_keeper_passive_loop_detected_total]: the counter fires
    only at the threshold crossing, this gauge lets dashboards see the
    streak rising before the latch.  Labels: [keeper]. *)

(** Task-138 Unix timestamp of the most recent productive turn
    (execution/completion class) per keeper.  Reads as 0 until the
    keeper has produced anything in this process.  Labels: [keeper]. *)

(** PR-B: counter incremented when [run_keeper_cycle] skips a turn
    because the keeper's resolved cascade is ollama-only and the
    [/api/ps] probe reports zero process_available slots.  Labelled
    by [keeper] and [cascade] so dashboards can attribute starvation
    to specific cascade profiles. *)
val metric_persistence_read_drops : string

(** Goal-loop Observe counter for persistence UTF-8 repairs. No labels. *)
val metric_persistence_utf8_repair : string

val metric_discovery_history_failures : string

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
    Labels: [model_bucket] only. *)
val metric_oas_inference_cost_usd : string

val metric_mcp_tool_schema_count : string
val metric_mcp_tool_schema_tokens_approx : string

(** {1 Core counters / gauges} *)

val metric_mcp_requests : string
val metric_llm_inference_duration : string

(** [masc_llm_prompt_tok_per_sec] — prefill throughput histogram.
    Observed in [Keeper_hooks_oas] after_turn when [response.telemetry.timings]
    is [Some] and [prompt_per_second] is positive. Labels: [model], [provider_kind]. *)
val metric_llm_prompt_tok_per_sec : string

(** [masc_llm_decode_tok_per_sec] — decode throughput histogram.
    Observed alongside {!metric_llm_prompt_tok_per_sec} from the same turn
    when [predicted_per_second] is positive. Silent for providers that do
    not emit timings; inspect [masc_after_turn_telemetry_missing_total] to
    tell absence apart from zero. *)
val metric_llm_decode_tok_per_sec : string

val metric_after_turn_hook : string
val metric_after_turn_telemetry_missing : string
val metric_after_turn_telemetry_zero_latency : string
val metric_tasks : string
val metric_errors : string
val metric_error_events : string
val metric_workspace_route_failures : string
val metric_active_agents : string
val metric_pending_tasks : string
val metric_uptime_seconds : string

(** Goal attainment percentage by [goal_id]. Companion
    {!metric_goal_attainment_measured} distinguishes real 0% from
    unmeasured goals. *)
val metric_goal_attainment_pct : string

(** Gauge by [goal_id]: [1] when goal attainment percentage is measured,
    [0] when the dashboard projection is currently unmeasured. *)
val metric_goal_attainment_measured : string

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
val metric_llm_provider_request_latency_clamped : string
val metric_llm_provider_capability_drops : string
val metric_llm_provider_cache_hits : string
val metric_llm_provider_cache_misses : string
val metric_llm_provider_requests_started : string
val metric_llm_provider_errors : string
val metric_llm_provider_errors_by_reason : string
val metric_llm_provider_retries : string
val metric_llm_provider_input_tokens : string
val metric_llm_provider_output_tokens : string

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
    Labels: [cascade], [provider]. *)
val metric_cascade_ttfb_seconds : string

(** Histogram: inter-chunk gap during streaming (TBT).
    Labels: [cascade], [provider]. *)
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
    (the entry point of the detected cycle).  Discovered during the
    2026-05-05 fleet-stuck investigation:
    [default → glm_coding_plan_only → default]. *)
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
val metric_runtime_ollama_probe_generate_skips : string

(** #9632: subprocess executions that exceeded their configured
    timeout. Labels: [program, timeout_sec]. *)
val metric_process_timeout : string

(** Background-task PID sidecar persistence failures. Labels:
    [site] = [write | read | read_parse | readdir | is_dir | unlink]. *)
val metric_bg_task_sidecar_failures : string

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

(** #9786: Auth rejects where bearer token owner does not match the
    requested agent_name.  Labels: [expected_agent, actual_agent].
    Dashboards alert on rate advancing after a server restart as a
    signal of shared credential state (connection pool / fork). *)
val metric_auth_bearer_token_mismatch : string

(** #10183: strict Auth rejects for unknown external tools.  Labels:
    [agent_name, tool_class] where [tool_class] is bounded to
    [empty | external]. *)
val metric_auth_strict_unknown_tool_denials : string

(** A1 track: counter for keeper registry dispatch_event failures that
    were previously silently dropped via [ignore].  Labels:
    [keeper, reason] where reason is [terminal_state] or
    [invalid_transition]. *)

(** gRPC directive routing failures — target agent not in registry
    or directive malformed.  Labels: [keeper, site]. *)

(** #9786 follow-up: boot-time audit counter for credentials
    sharing the same token hash.  Increments once per boot per
    duplicate group.  Operator alert: any non-zero rate is a
    routing-ambiguity that must be rotated. *)
val metric_auth_credential_token_duplicate : string

(** #10304 prevention counter.  Increments once per credential that
    boot-time repair rotates out of a shared bearer-token group.
    Labels: [token_hash_prefix, scope]. *)
val metric_auth_credential_token_rotated : string

(** Bare-form keeper credential files archived because they are dead after
    PR-3b1 starvation. Labels: [keeper_name]. *)
val metric_config_credential_archived_starvation : string

(** #9786 runtime complement: every [find_credential_by_token]
    lookup that hits N>=2 matches fires this counter.
    Labels: [first_match] = the agent_name that won the
    [List.find] race.  Distinguishes a stale audit warning
    from active wrong-agent serving. *)
val metric_auth_credential_ambiguous_lookup : string

(** PR-I (2026-04-25): mcp_server_eio_execute silently fell back to
    the caller's agent_name when [Auth.resolve_agent_from_token]
    returned [Error _].  Labels: [error_kind], [agent]. *)
val metric_silent_auth_token_resolve_error : string

(** PR-I (2026-04-25): Server_auth.dashboard_actor_for_request
    silently fell back to [request_actor_hint] because the bearer
    token resolved to no agent ([Ok None]) or an error.
    Labels: [outcome] = "none" | "error". *)
val metric_silent_dashboard_actor_fallback : string

(** Phase A F2 (2026-04-27): paired with
    [metric_silent_auth_token_resolve_error] to measure "how many of
    those silent fallbacks would be rejected under Strict mode" before
    Phase B PR-2 actually performs the rejection.  Labels:
    [mode] = "off" | "dry_run" | "strict",
    [error_kind] = same kinds as silent_auth,
    [agent] = the alias the request would have kept. *)
val metric_auth_strict_would_reject : string

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
val metric_empty_tool_universe_observed : string

(** RFC P3-a (2026-04-26): Coord.join identity normalization by
    [Keeper_identity.normalize_all_names].
    Labels: [outcome] = "ok" | "empty_input" | "persona_not_found"
    | "credential_missing" | "name_ambiguous" | "ephemeral_suffix_rejected".
    Non-ok outcomes reject [masc_join] at the fail-closed identity gate.
    Cross-reference [metric_silent_auth_token_resolve_error] for auth/name
    drift diagnosis. *)
val metric_coord_join_normalize_outcome : string

(** Unknown config keys ignored after warning. Labels: [file_path]. *)
val metric_config_unknown_keys_ignored : string

(** Governance/operator judge responses that remained unparseable after
    deterministic JSON recovery. Labels: [judge]. *)
val metric_governance_judge_unparseable : string

(** Lenient_json fallback hits for governance/operator judge output.
    Labels: [judge]. *)
val metric_governance_lenient_json_fallback_hit : string

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
val metric_sse_client_evictions : string
val metric_coord_broadcast_duration : string
val metric_file_lock_retries : string
val metric_file_lock_acquire_seconds : string
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

(** Dashboard execution render phase latency histogram. Labels:
    [phase] = total | snapshot | operations | enrich | enrich_per_keeper
            | data_load | assemble.
    The per-phase series let operators distinguish broad dashboard N+1 /
    enrichment cost from unrelated snapshot or assembly latency. *)
val metric_dashboard_execution_render_phase_sec : string

(** Dashboard snapshot phase latency in seconds. *)
val metric_dashboard_snapshot_latency_seconds : string

(** Cumulative bucket counter for dashboard snapshot phase latency.
    Labels: [le]. *)
val metric_dashboard_snapshot_latency_seconds_bucket : string

(** Dashboard render sub-operation timing all-zero diagnostic.
    Labels: [keeper_name], using [__dashboard__] for the render-level
    singleton required by the Observe dashboard contract. *)
val metric_dashboard_metric_all_zeros : string

(** PR-0.2.A (RFC 2026-04-masc-ide-strategy): cache lookup hit/miss
    counters. Labels: [cache] with values
    - ["eio"]      — [Cache_eio.get] (filesystem-backed key/value cache).
    - ["dashboard"] — [Dashboard_cache.get_or_compute] (in-memory
                     stale-while-revalidate cache for dashboard responses).
    Operator query: [hit_ratio = hits / (hits + misses)] per [cache] label
    quantifies cache effectiveness. Pure observation — registering or
    incrementing these counters never changes cache logic. *)
val metric_cache_hits_total : string

(** Companion to {!metric_cache_hits_total}; same [cache] label values. *)
val metric_cache_misses_total : string

(** Companion to {!metric_cache_hits_total}; same [cache] label values. *)
val metric_ws_client_buffered_bytes : string

val metric_ws_client_acks : string
val metric_ws_throttled_deliveries : string
val metric_ws_slice_fanout_skipped : string
val metric_ws_bytes_sent : string
val metric_grpc_bytes_sent : string
val metric_ws_delta_built : string

(** Histogram of WebSocket message payload size in bytes, observed at
    the wire boundary. Labels: [direction = send | recv]. Complements
    the [masc_ws_bytes_sent_total] counter by exposing per-message
    distribution (p50/p95/p99) so operators can distinguish a few
    large frames from many small frames. *)
val metric_ws_message_bytes : string

(** Lines walked while replaying [.masc/backlog.jsonl] on a gRPC
    Subscribe RPC, including those filtered out by [since_seq]. *)
val metric_grpc_backlog_replay_lines_scanned : string

(** Backlog events actually delivered (post-[since_seq] filter)
    on a gRPC Subscribe RPC. The gap between scanned-lines and
    replayed-events isolates wasted scan cost. *)
val metric_grpc_backlog_replay_events_replayed : string

(** Primary HTTP listener accepted TCP connections. Labels: [mode]. *)
val metric_http_accepts : string

(** Primary HTTP listener accept-loop errors. Labels: [mode]. *)
val metric_http_accept_errors : string

(** Primary HTTP listener active accepted connections. *)
val metric_http_active_connections : string

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
      This is the canonical signal for cross-cascade fallback on hang.
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
