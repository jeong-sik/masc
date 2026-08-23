(** Console mirror sink — the console is a convenience mirror of the log
    stream; the JSONL file sink and in-memory ring are authoritative.

    Before {!start}, {!write} performs the write synchronously on the
    caller (historical behavior — tests and CLI one-shots unchanged).
    After {!start}, {!write} enqueues into a bounded queue drained by a
    dedicated OS thread, so a blocked console fd (full pty buffer:
    terminal scrollback, copy-mode, slow renderer) can no longer halt
    the calling domain. On overflow, incoming mirror lines are dropped
    and counted; a marker reporting the drop count is emitted when the
    writer unblocks. See issue #20684 for the live incident. *)

(** Switch to enqueue mode and spawn the writer thread (idempotent).
    Call once at server startup, before keepers boot. *)
val start : unit -> unit

(** Emit one console line (no trailing newline). Never blocks after
    {!start}; synchronous before. *)
val write : string -> unit

(** Replace the single process-wide callback invoked after every console writer
    attempt, including failed or partially completed writes. The callback may
    run on the sink's OS writer thread, so it must be fast, non-blocking, and
    must not perform I/O or re-enter logging. Observer exceptions are ignored.
    They never change the writer's original result or exception. Pass [None]
    when the interactive terminal owner exits. *)
val set_after_write_observer : (unit -> unit) option -> unit

(** Total mirror lines dropped due to a blocked console writer. *)
val dropped_count : unit -> int

(** Lines currently queued for the writer thread. A rising depth means
    the console fd is blocked (the failure mode behind #20684). *)
val queue_depth : unit -> int

module For_testing : sig
  (** Replace the fd writer ([None] restores stderr). *)
  val set_writer : (string -> unit) option -> unit

  (** Toggle enqueue mode WITHOUT spawning the writer thread, so tests
      drain deterministically via {!drain_now}. *)
  val set_enqueue_active : bool -> unit

  val queued_count : unit -> int

  (** Drain the queue synchronously on the calling thread; returns the
      number of lines written. *)
  val drain_now : unit -> int

  (** Drain using the supplied prior drop-report count; returns the number of
      queued lines and the updated count. This deterministically exercises the
      production drop-marker path without starting its infinite writer thread. *)
  val drain_now_since : int -> int * int

  (** Clear queue/counters and restore synchronous mode, stderr writer, and no
      after-write observer. *)
  val reset : unit -> unit
end
