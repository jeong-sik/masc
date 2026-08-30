
(** Tool_metrics_persist — JSONL disk persistence for tool metrics.

    Restores current-format tool invocation records at startup and periodically
    flushes new in-memory records to
    [data/tool-metrics/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.

    Flush failures are logged but do not affect server operation. The
    process-scoped snapshot keeps queue loss and recovery visible separately
    from the hydrated aggregate tool statistics.

    @since 2.108.0 — Issue #3280 *)

val enqueue : base_path:string -> Tool_result.result -> unit
(** [enqueue ~base_path result] publishes an atomic pending-spool file before
    buffering the invocation record for eventual batched JSONL flush.
    A successful publication survives process termination after [enqueue]
    returns; this is not a host power-loss or network-filesystem guarantee.
    Safe to call from any fiber. Records are batched and written periodically.
    Reaching half of the bounded queue wakes the background writer early.
    If the bounded best-effort queue is full, the record is dropped instead of
    blocking the tool completion path. A record whose disk append fails stays
    inside the same capacity bound and is retried before newer records. The
    background writer applies a bounded retry delay rather than spinning while
    storage remains unavailable. If pending publication fails, the record stays
    in the memory queue and the failure is visible in [persistence_snapshot]. *)

type hydrate_report = {
  loaded_records : int;
  malformed_records : int;
  invalid_records : int;
  pruned_files : int;
  recovered_pending_records : int;
  deduplicated_pending_records : int;
  invalid_pending_files : int;
}

type persistence_snapshot = {
  runtime_instance_id : string;
  process_started_at : string;
  observed_at_unix : float;
  writer_active : bool;
  queue_depth : int;
  retry_queue_depth : int;
  in_flight_records : int;
  spooling_records : int;
  spool_backed_queue_depth : int;
  queue_capacity : int;
  queue_high_watermark : int;
  queue_full_dropped_records : int;
  append_failed_records : int;
  spool_write_failed_records : int;
  spool_delete_failed_records : int;
  flushed_records : int;
  flush_batches : int;
  last_flush_trigger : string option;
  last_flush_rows : int option;
  last_flush_failed_rows : int option;
  last_flush_at_unix : float option;
  last_append_error : string option;
  last_spool_error : string option;
}

val persistence_snapshot : unit -> persistence_snapshot
(** Current-process observation of the bounded persistence queue and writer.
    [queue_depth] includes ready, retry, in-flight, and still-publishing spool
    records. [spool_backed_queue_depth] is the subset already represented by
    an atomic pending file. Counters start at zero on process start and are not
    hydrated from JSONL.

    [append_failed_records] counts failed append attempts; the same retained
    record can contribute more than once while storage remains unavailable. *)

val persistence_snapshot_to_json : persistence_snapshot -> Yojson.Safe.t
(** Current-only JSON projection. Absent last-event fields are JSON [null]. *)

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

  val set_pending_write_guard :
    (string -> string -> (unit, string) result) -> unit
end
