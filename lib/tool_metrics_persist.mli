
(** Tool_metrics_persist — JSONL disk persistence for tool metrics.

    Periodically flushes in-memory tool invocation records to
    [data/tool-metrics/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.

    Flush failures are logged but do not affect server operation.

    @since 2.108.0 — Issue #3280 *)

val enqueue : Tool_result.result -> unit
(** [enqueue result] buffers a tool invocation record for eventual disk flush.
    Safe to call from any fiber. Records are batched and written periodically.
    If the bounded best-effort queue is full, the record is dropped instead of
    blocking the tool completion path. *)

val start_flush_fiber : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> base_path:string -> unit
(** [start_flush_fiber ~sw ~clock ~base_path] spawns a background fiber that
    drains buffered records to JSONL every 5 minutes.  Also registers a
    shutdown hook to flush remaining records.
    [base_path] is the workspace root (e.g. [state.workspace_config.base_path]). *)

val flush_now : base_path:string -> unit
(** [flush_now ~base_path] immediately drains the write queue to the
    current JSONL store. Intended for shutdown hooks and testing. *)

val reset_for_testing : unit -> unit
(** Clear cached store state and drop any queued records held in memory.

    This does not cancel or modify any background flush fiber or shutdown
    hook previously started via [start_flush_fiber]; those may still flush
    records based on the store instance they captured.

    For reliable test isolation, call this either before
    [start_flush_fiber] is invoked, or only after the [Eio.Switch.t]
    passed to [start_flush_fiber] has been cancelled so that no flush
    fiber is active. *)
