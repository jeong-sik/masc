(** SSE broadcast helpers for keeper lifecycle events.

    Pure side-effect wrappers — no registry state read or written. *)

(** Install the function {!composite_changed} calls before it broadcasts.
    The server installs one that drops the Keeper's cached composite, so a
    reader that fetches [/api/v1/keepers/:name/composite] on the event
    computes it again. An
    exception from it is logged and the event is still sent;
    {!Eio.Cancel.Cancelled} propagates. *)
val install_before_composite_changed : (base_path:string -> name:string -> unit) -> unit

(** Broadcast a signal-only [keeper_composite_changed] SSE event to observers
    and presence sessions belonging to [base_path]. External subscribers must
    carry the same runtime authority to receive the observer event.

    The payload is intentionally minimal: keeper [name] + wall-clock
    [ts_unix]. It is *not* the authoritative composite snapshot.
    Consumers must re-fetch [/api/v1/keepers/:name/composite] to observe
    the new state. See docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md
    §Read Model Rules.

    Broadcast exceptions are caught, counted on the
    [keeper_lifecycle_dispatch_rejections] Otel_metric_store counter (with
    the [broadcast_composite_failed] event label), and logged at WARN.
    [Eio.Cancel.Cancelled] propagates so cancellation semantics are
    preserved. *)
val composite_changed : base_path:string -> name:string -> ts_unix:float -> unit

(** Account for a [keeper_phase_changed] SSE broadcast failure: bump the
    [keeper_sse_broadcast_failures] Otel_metric_store counter (site label
    [phase_changed]) and log the exception at WARN. *)
val record_phase_failure : name:string -> exn -> unit
