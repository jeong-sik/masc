(** SSE broadcast helpers for keeper lifecycle events.

    Pure side-effect wrappers — no registry state read or written. *)

(** Broadcast a [keeper_composite_changed] SSE event on both the main
    broadcast channel and the presence stream.

    Exceptions from [Sse.broadcast] are caught, counted on the
    [keeper_lifecycle_dispatch_rejections] Prometheus counter (with
    the [broadcast_composite_failed] event label), and logged at WARN.
    [Eio.Cancel.Cancelled] propagates so cancellation semantics are
    preserved. *)
val composite_changed : name:string -> ts_unix:float -> unit

(** Account for a [keeper_phase_changed] SSE broadcast failure: bump the
    [keeper_sse_broadcast_failures] Prometheus counter (site label
    [phase_changed]) and log the exception at WARN. *)
val record_phase_failure : name:string -> exn -> unit
