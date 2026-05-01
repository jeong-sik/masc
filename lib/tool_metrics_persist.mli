open Base

(** Tool_metrics_persist — JSONL disk persistence for tool metrics.

    Periodically flushes in-memory tool invocation records to
    [data/tool-metrics/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.
    On server startup, restores previous records into {!Tool_metrics}.

    Flush failures are logged but do not affect server operation.

    @since 2.108.0 — Issue #3280 *)

val enqueue : Tool_result.t -> unit
(** [enqueue result] buffers a tool invocation record for eventual disk flush.
    Safe to call from any fiber. Records are batched and written periodically. *)

val start_flush_fiber : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> base_path:string -> unit
(** [start_flush_fiber ~sw ~clock ~base_path] spawns a background fiber that
    drains buffered records to JSONL every 5 minutes.  Also registers a
    shutdown hook to flush remaining records.
    [base_path] is the workspace root (e.g. [state.room_config.base_path]). *)

val restore : base_path:string -> int
(** [restore ~base_path] reads all existing JSONL day-files under
    [base_path/data/tool-metrics/] and replays them into {!Tool_metrics}.
    Returns the number of records restored. *)

val flush_now : unit -> unit
(** [flush_now ()] immediately drains the write queue to disk.
    Intended for shutdown hooks and testing. *)

val reset_for_testing : unit -> unit
(** Clear cached store state and drop any queued records held in memory.

    This does not cancel or modify any background flush fiber or shutdown
    hook previously started via [start_flush_fiber]; those may still flush
    records based on the store instance they captured.

    For reliable test isolation, call this either before
    [start_flush_fiber] is invoked, or only after the [Eio.Switch.t]
    passed to [start_flush_fiber] has been cancelled so that no flush
    fiber is active. *)
