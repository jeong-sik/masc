(** Admission_queue_metrics — Prometheus integration for inference admission queue.

    Emits metrics on every acquire/release event.
    Called internally by [Admission_queue]; callers do not invoke directly.

    @since 3.0.0 *)

(** Called after successful acquire. Increments inflight gauge,
    records wait time histogram. *)
val on_acquire : keeper_name:string -> cascade_name:string -> wait_ms:int -> unit

(** Called on release. Decrements inflight gauge. *)
val on_release : keeper_name:string -> cascade_name:string -> unit

(** Syncs the configured admission queue capacity into Prometheus. *)
val set_max_concurrent : int -> unit
