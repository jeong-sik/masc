(** Bounded ingestion queue for addressed IDE observation events.

    The keeper tool-execution hook fires event sinks on the keeper turn fiber
    (the main Eio domain). Parsing tool output and appending JSONL there stalls
    the whole fleet under load (task-1647 freeze class). This queue lets a sink
    defer the ingestion work as a job; a single writer fiber drains the queue
    and runs the jobs (parse + append). This is a separate fiber, not a domain.

    At capacity, the producer fiber waits for space instead of evicting an
    accepted job. When no writer is running (tests, pre-bootstrap or after
    teardown), {!submit} drains retained jobs and runs the new job inline. *)

type job = unit -> unit

val submit : job -> unit
(** Enqueue [job] for the writer fiber, waiting cooperatively at capacity.
    Active-writer calls require an Eio fiber; inactive calls also work outside
    Eio. Cancellation while waiting propagates without inserting [job]. Once
    enqueued, ownership passes to the writer or shutdown drain. *)

val run_writer : unit -> unit
(** Writer-fiber body: marks the queue active, then blocks draining jobs one at
    a time. Exactly one writer may run, under the server switch; never returns. A job
    that raises is logged and skipped; [Eio.Cancel.Cancelled] propagates so
    switch teardown cancels the fiber. Teardown marks the queue inactive and
    wakes waiting producers, which use the inline path if still live. An
    interrupted running job is not retried; queued jobs remain for the drain. *)

val drain_pending : unit -> unit
(** Run every currently-queued job synchronously. Registered as the shutdown
    drain hook so queued events are flushed before exit. *)

val depth : unit -> int
(** Current number of queued jobs. *)

(** Test-only controls. Production reaches the queue through {!submit} /
    {!run_writer} / {!drain_pending} with the default capacity. *)
module For_testing : sig
  val reset : ?capacity_override:int -> unit -> unit
  val set_active : bool -> unit
end
