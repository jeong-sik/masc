
(** Tool_metrics_persist — JSONL disk persistence for tool metrics.

    Restores current-format tool invocation records at startup and periodically
    flushes new in-memory records to
    [data/tool-metrics/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.

    Flush failures are logged but do not affect server operation.

    @since 2.108.0 — Issue #3280 *)

val enqueue : Tool_result.result -> unit
(** [enqueue result] buffers a tool invocation record for eventual disk flush.
    Safe to call from any fiber. Records are batched and written periodically.
    Reaching half of the bounded queue wakes the background writer early.
    If the bounded best-effort queue is full, the record is dropped instead of
    blocking the tool completion path. *)

type hydrate_report = {
  loaded_records : int;
  malformed_records : int;
  invalid_records : int;
  pruned_files : int;
}

val hydrate :
  base_path:string ->
  retention_days:int ->
  (hydrate_report, Dated_jsonl.read_error) result
(** [hydrate ~base_path ~retention_days] prunes expired day files, streams the
    remaining current-format rows into a replacement {!Tool_metrics} snapshot,
    and publishes that snapshot only after the complete store was read.
    Malformed JSON and rows that do not match the current record format are
    counted and skipped. Repeating hydration replaces rather than appends, so
    persisted calls are not double-counted. Call before installing live metric
    producers. *)

val start_flush_fiber : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> base_path:string -> unit
(** [start_flush_fiber ~sw ~clock ~base_path] spawns a background fiber that
    drains buffered records to JSONL on the configured interval (0.5 seconds
    by default) or when the queue reaches its high watermark. Also registers a
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

module For_testing : sig
  val high_watermark : int
  val queued_record_count : unit -> int

  val await_flush_trigger :
    clock:_ Eio.Time.clock ->
    interval_s:float ->
    [ `High_watermark | `Timer ]
end
