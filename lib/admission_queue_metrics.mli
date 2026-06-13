(** Admission_queue_metrics — Otel_metric_store integration for inference admission queue.

    Emits metrics on every acquire/release event.
    Called internally by [Admission_queue]; callers do not invoke directly.

    @since 3.0.0 *)

type rejection_surface = With_permit | Try_with_permit
(** Bounded [surface] label vocabulary for rejected admission requests. *)

type rejection_reason = Host_resource_saturated
(** Bounded [reason] label vocabulary for rejected admission requests. *)

val rejection_surface_label : rejection_surface -> string
(** Otel_metric_store label value for a rejection surface. *)

val rejection_reason_label : rejection_reason -> string
(** Otel_metric_store label value for a rejection reason. *)

val on_acquire :
  keeper_name:string ->
  runtime_id:string ->
  wait_ms:int ->
  unit
(** Called after successful acquire. Increments inflight gauge,
    records wait time histogram. *)

val on_release :
  keeper_name:string -> runtime_id:string -> unit
(** Called on release. Decrements inflight gauge. *)

val on_reject : surface:rejection_surface -> reason:rejection_reason -> unit
(** Called when admission rejects before running the callback.
    Emits [surface=with_permit|try_with_permit] and
    [reason=host_resource_saturated]. *)

val set_max_concurrent : int -> unit
(** Syncs the configured admission queue capacity into Otel_metric_store. *)
