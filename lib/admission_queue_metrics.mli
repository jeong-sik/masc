(** Admission_queue_metrics — Prometheus integration for inference admission queue.

    Emits metrics on every enqueue/dequeue/acquire/release event.
    Called internally by [Admission_queue]; callers do not invoke directly.

    @since 3.0.0 *)

val on_enqueue : keeper_name:string -> cascade_name:string -> unit
(** Called when a waiter enters the queue. Increments queue_depth gauge. *)

val on_dequeue : keeper_name:string -> cascade_name:string -> unit
(** Called when a waiter exits the queue (acquired or cancelled).
    Decrements queue_depth gauge. *)

val on_acquire : keeper_name:string -> cascade_name:string -> wait_ms:int -> unit
(** Called after successful acquire. Increments inflight gauge,
    records wait time histogram. *)

val on_release : keeper_name:string -> cascade_name:string -> unit
(** Called on release. Decrements inflight gauge. *)

val on_cancelled : keeper_name:string -> cascade_name:string -> unit
(** Called when a wait is cancelled by fiber cancellation.
    Increments cancelled counter. *)
