(** Otel_metric_store metric-name string constants — public counterpart to
    [Otel_metric_names.ml]. Extracted from [Otel_metric_store] to keep
    the parent interface under the Godfile size cap.

    [Otel_metric_store.mli] uses [include module type of Otel_metric_names]
    so callers see every [val metric_X : string] under the [Otel_metric_store]
    namespace unchanged. *)

(** {1 Metric Name Constants}

    Shared SSOT between registration (in [init]) and call-sites in
    keeper/bridge modules. Importing [Otel_metric_store.<constant>] ensures
    the compiler catches typos that would otherwise silently create
    dead series. *)

(** Goal-loop Observe turn-success denominator. Labels: [keeper_name]. *)

(** Goal-loop Observe turn-success numerator. Labels: [keeper_name]. *)

(** Current keeper world-observation idle seconds. Updated from
    [observation.idle_seconds] during keeper metrics emission so long idle
    gaps are visible as a scrapeable gauge, not only in message text.
    Labels: [keeper_name]. *)

(** #10530: keeper completion-contract violations.
    Labels: keeper_name, kind \in \{passive,text_only\}. *)

(** #9953: bucketed counter for observed [context_max] values.
    Labels: [keeper, model_used, resolved_model_id,
    context_max_bucket].  Bucket vocabulary:
    [64k | 128k | 200k | 256k | 1m | other | zero]. *)

(** Objective Keeper turn-attempt observer counters. Labels:
    [keeper].  Re-attempt = same turn id started again before
    the counter advanced; regression = turn id moved strictly
    backwards (write_meta race symptom — #9733). *)

(** #9943: per-keeper turn latency distribution.  Labels:
    [keeper, bucket].  Bucket vocabulary:
    [under_60s | 60-300s | 300-600s | 600-1200s | over_1200s]. *)

(** #9933: per-keeper turn latency distribution split by effective
    model/runtime surface.  Labels:
    [keeper, channel, provider_kind, model_used, resolved_model_id,
    runtime_profile, bucket]. *)

(** P-DASH-01: provider cooldown skip counter.  Incremented when a
    runtime is in provider cooldown and the keeper fail-opens to a
    fallback runtime.  Labels: [keeper, from_runtime, to_runtime]. *)

(** P-DASH-01: provider cooldown remaining seconds gauge.
    Exposes the current cooldown duration so operators can see
    which runtime is blocked and for how long.  Labels: [keeper, runtime]. *)

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
    [Otel_metric_store]. *)
val metric_backend_mutex_acquire_sec : string

(** Time spent inside the backend persist lock, from acquisition to
    release. Labels: [op] in {[set | delete | set_if_not_exists]}.

    Captures time spent in the write critical section, used together
    with [metric_backend_mutex_acquire_sec]. *)
val metric_backend_mutex_held_sec : string

(** P-DASH-02: turn queue depth gauge.  Semaphore waiter count
    surfaced so operators can alert on queue pressure without log
    parsing.  Labels: [keeper, channel]. *)

(** #10125: supervisor sweep liveness counters.  See {!Otel_metric_store.ml}
    for the rationale.  Counter increments on each Pulse start;
    gauge advances on every successful beat. *)

(** Counter for [tool_metrics_persist] write-queue overflow drops. No labels. *)
val metric_tool_metrics_persist_dropped : string

(** Gauge of waiting/deferred rows by [scope] and [source] for the keeper
    waiting inventory dashboard projection. Labels: [scope], [source]. *)
val metric_keeper_waiting_count : string

(** Gauge of the oldest currently visible waiting-row age in seconds by
    [scope] and [source]. Labels: [scope], [source]. *)
val metric_keeper_waiting_age_seconds : string

(** Gauge of keepers by inventory state. Labels: [state]. *)
val metric_keeper_waiting_keeper_count : string

(** Schedule unsupported payload counter. Label: [phase] in
    {[creation | dispatch]}. Raw payload kinds are not
    labels; they remain in typed errors/projections to avoid unbounded metric
    cardinality. *)
val metric_schedule_payload_unsupported_total : string

(** Counter for bind-required guard rejects. Labels: [tool],
    [agent_name], and [reason]. *)
val metric_tool_bind_required_guard : string

(** Counter for [Keeper_tool_call_log] async write-queue overflow drops.
    No labels. *)
val metric_keeper_tool_call_log_queue_dropped : string

(** Counter for [keeper_tool_surface.cached_text_by_key] Atomic CAS retry events.
    Each increment corresponds to one extra [compute ()] call. No labels. *)
val metric_tool_keeper_cache_cas_conflicts : string

(** Counter for [File_lock_eio] lock-table CAS retries (both
    [prune_stale_entries] and [get_entry] share the same single
    [table] Atomic). Each increment corresponds to one extra
    [Atomic.compare_and_set] failure under fiber contention.
    Sustained non-zero rate indicates fan-out into the lock table
    under load. No labels — only one shared atomic in the module. *)
val metric_file_lock_table_cas_retries : string

(** Counter for [keeper_tool_surface.cache_ttl_seconds] env-var parse fallback events.
    Increments when the operator-supplied env var is present but unparseable
    or out-of-range, and the helper falls back to its default. Labels:
    [env_var, reason] with reason in [invalid_float | negative_or_nan]. *)
val metric_tool_keeper_cache_ttl_parse_failures : string

(** Counter for cancellation-safe keeper turn-holder release bookkeeping
    callbacks that could not complete. Labels: [op, kind] with
    kind in [cancelled | exception]. *)

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
    across contract/gate/FS-resolver layers. Label [kind="out_of_roots"]
    records objective allowed-root containment failures. *)

val metric_write_meta_cas_retry_total : string

(** Total board signals that did not produce a wake decision for a
    running keeper. Increments per (keeper, kind) when
    [Keeper_world_observation.board_signal_wake_reason] returns
    [None] — no explicit_mention, scope feed disabled, and no
    external reply after a self-comment. Discoverability for the
    REPO_WAKE_UP audit finding: keepers with narrow mention targets
    can silently drop board posts. Labels: keeper, kind=post_created|comment_added. *)

val metric_cache_desync_cleared : string

(** Runtime state synchronization failures: explicit pause/resume paths
    only. Local discovery refresh failures use
    [metric_keeper_local_discovery_failures] so dashboards can attribute
    distinct failure classes. *)

(** Local discovery readiness failures observed during create/turn paths.
    Separated from [metric_keeper_runtime_sync_failures] so dashboards do
    not conflate runtime-state sync with discovery-refresh incompleteness. *)

(** #10091: labelled [keeper, has_current_task, contract_status]
    so fleet histograms can distinguish the active-task strict
    path from the no-task path covered by #10031. *)

(** #10474: counter incremented when a keeper's runtime has zero
    tool-capable providers.  Labels: keeper, runtime. *)

(** #10474: counter classifying each scheduled autonomous cycle outcome.
    Labels: keeper, outcome=[tool_called|noop|error]. *)

(** #12799 Total passive-loop detections: keeper completed N consecutive turns
    using only passive read-only tools, violating the proactive contract.
    Incremented once per loop episode (streak resets on any execution-progress
    turn). Labels: [keeper]. *)

(** #13362 Total completion-contract loops: keeper hit N consecutive
    actionable completion-contract failures before making execution/completion
    progress.  Incremented once per loop episode. Labels: [keeper, kind]. *)

(** Goal-loop Observe counter for no-progress keeper loops. Emitted by the
    passive/completion-contract loop detector when progress-signalling turns make no
    execution or completion progress. Incremented once per loop episode.
    Labels: [keeper_name]. *)

(** Task-138 Current consecutive-idle streak per keeper. Resets to 0 on
    the next execution/completion turn. Labels: [keeper]. *)

(** Task-138 Unix timestamp of the most recent productive turn
    (execution/completion class) per keeper.  Reads as 0 until the
    keeper has produced anything in this process.  Labels: [keeper]. *)

(** PR-B: counter incremented when [run_keeper_cycle] skips a turn
    because the keeper's resolved runtime is ollama-only and the
    [/api/ps] probe reports zero process_available slots.  Labelled
    by [keeper] and [runtime] so dashboards can attribute starvation
    to specific runtime profiles. *)
val metric_persistence_read_drops : string

(** Goal-loop Observe counter for persistence UTF-8 repairs. No labels. *)
val metric_persistence_utf8_repair : string

val metric_discovery_history_failures : string

(** #18855: per-tool correction_pipeline fix counter.
    Incremented when the OAS agent_tools module reports that
    correction_pipeline fixed input fields for a tool.
    Labels: [tool_name]. *)
val metric_oas_correction_pipeline_fixes_total : string
