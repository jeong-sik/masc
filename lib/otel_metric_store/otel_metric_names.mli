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
    [set | delete | set_if_not_exists].

    Combined with [metric_backend_mutex_held_sec] this distinguishes
    keeper write contention (acquire high) from disk I/O stall (held
    high) inside the storage layer. Read paths are not measured by
    these histograms.

    Wired by [Backend.FileSystem.set_mutex_observers] from the main
    library at startup so that [masc_backend] does not depend on
    [Otel_metric_store]. *)
val metric_backend_mutex_acquire_sec : string

(** Time spent inside the backend persist lock, from acquisition to
    release. Labels: [op] in [set | delete | set_if_not_exists].

    Captures time spent in the write critical section, used together
    with [metric_backend_mutex_acquire_sec]. *)
val metric_backend_mutex_held_sec : string

(** Counter for tool metric rows that SQLite could not persist. No labels. *)
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
    [creation | dispatch]. Raw payload kinds are not
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

(** Total board signals that did not produce a wake decision for a
    running keeper ([masc_keeper_board_signal_no_wake_total]).
    Increments per (keeper, kind, audience) when typed-audience routing
    ([Keeper_board_audience.route_for_keeper]) returns [Ignore], or
    [Judge_discoverable] — the latter issues no wake and records a board
    attention candidate instead, so the [audience] label distinguishes
    the two. Discoverability for the REPO_WAKE_UP audit finding:
    keepers with narrow mention targets can silently drop board posts.
    Labels: keeper, kind=post_created|comment_added, audience. *)

val metric_cache_desync_cleared : string

(** Runtime state synchronization failures: explicit pause/resume paths
    only. Local discovery refresh failures use
    [masc_keeper_local_discovery_failures_total] so dashboards can attribute
    distinct failure classes. *)

(** Local discovery readiness failures observed during create/turn paths.
    Separated from [masc_keeper_runtime_sync_failures_total] so dashboards do
    not conflate runtime-state sync with discovery-refresh incompleteness. *)

(** Task-138 Unix timestamp of the most recent productive turn
    (execution/completion class) per keeper.  Reads as 0 until the
    keeper has produced anything in this process.  Labels: [keeper]. *)

(** Counter for persisted read-model entries dropped on read. Labels:
    [surface] and [reason] ([Read_drop_reason.to_wire]). *)
val metric_persistence_read_drops : string

(** Goal-loop Observe counter for persistence UTF-8 repairs. No labels. *)
val metric_persistence_utf8_repair : string
