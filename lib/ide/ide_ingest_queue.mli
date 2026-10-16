(** Bounded ingestion queue for addressed IDE observation events.

    The keeper tool-execution hook fires event sinks on the keeper turn fiber
    (the main Eio domain). Parsing tool output and appending JSONL there stalls
    the whole fleet under load (task-1647 freeze class). This queue lets a sink
    defer the ingestion work as a job; a single writer fiber drains the queue
    and runs the jobs (parse + append). This is a separate fiber, not a domain.

    At capacity, admission refuses the new observation without waiting or
    evicting accepted jobs. The sink publishes the refusal through metrics.
    When no writer is running (tests, pre-bootstrap or after
    teardown), {!submit} drains retained jobs and runs the new job inline. *)

type job = unit -> unit

type submit_result = Accepted | Capacity_refused

val submit : job -> submit_result
(** While a writer is active, return immediately: [Accepted] transfers ownership
    to the writer/shutdown drain; [Capacity_refused] retains no reference to the
    new job and leaves accepted FIFO jobs intact. Submission does not suspend
    or require an Eio fiber, including when a writer callback submits again.
    Inactive submission instead drains retained jobs and runs the new job
    synchronously, and may block in those callbacks. This fallback also works
    outside Eio. [Accepted] does not promise successful or durable execution. *)

val run_writer : unit -> unit
(** Writer-fiber body: marks the queue active, then blocks draining jobs one at
    a time. Exactly one writer may run, under the server switch; never returns. A job
    that raises is logged and skipped; [Eio.Cancel.Cancelled] propagates so
    switch teardown cancels the fiber. Teardown marks the queue inactive; later
    submissions use the synchronous fallback. An
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
