(** Bounded, drop-oldest ingestion queue for IDE observation events.

    The keeper tool-execution hook fires event sinks on the keeper turn fiber
    (the main Eio domain). Parsing tool output and appending JSONL there stalls
    the whole fleet under load (task-1647 freeze class). This queue lets a sink
    enqueue the ingestion work as a job and return immediately; a single writer
    fiber drains the queue and runs the jobs (parse + append) off the hot path.

    Backpressure is bounded and visible: when the ring is full the oldest queued
    job is dropped and a counter is incremented — never a silent unbounded
    queue, never a blocking hot path. When no writer has been installed (tests,
    pre-bootstrap) {!submit} runs the job inline, matching the previous
    synchronous behavior. *)

type job = unit -> unit

val submit : job -> unit
(** Enqueue [job] for the writer fiber when a writer is running; otherwise run
    it inline. Enqueue never blocks the caller: at capacity it drops the oldest
    queued job (counted by {!dropped_count}) to make room. *)

val run_writer : unit -> unit
(** Writer-fiber body: marks the queue active, then blocks draining jobs one at
    a time. Intended to be forked under the server switch; never returns. A job
    that raises is logged and skipped; [Eio.Cancel.Cancelled] propagates so
    switch teardown cancels the fiber. *)

val drain_pending : unit -> unit
(** Run every currently-queued job synchronously. Registered as the shutdown
    drain hook so queued events are flushed before exit. *)

val dropped_count : unit -> int
(** Total jobs dropped due to a full ring since process start (or since the last
    {!For_testing.reset}). *)

val depth : unit -> int
(** Current number of queued jobs. *)

(** Test-only controls. Production reaches the queue through {!submit} /
    {!run_writer} / {!drain_pending} with the default capacity. *)
module For_testing : sig
  val reset : ?capacity_override:int -> unit -> unit
  val set_active : bool -> unit
  val is_active : unit -> bool
end
