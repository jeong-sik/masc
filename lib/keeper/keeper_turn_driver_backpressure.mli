(** Keeper_turn_driver_backpressure — Capacity backpressure classification.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Pure functions: classify HTTP/SDK errors into capacity backpressure signals.

    @since God file decomposition *)

(** Classify an HTTP error into a backpressure source, if applicable. *)

(** Build a capacity-backpressure internal error from an HTTP error,
    when the error indicates capacity exhaustion. *)

(** Build a capacity-backpressure internal error from a pending
    backpressure triple [(source, detail, retry_after)].  The retry-after
    component is either the provider-supplied [Explicit] value or
    [No_retry_hint]. No delay is synthesized. *)

(* [capacity_backpressure_of_sdk_error] was removed (#23438): a dead substring
   classifier that laundered opaque [Internal] errors into the auto-recoverable
   capacity-backpressure class. Legacy decoded [cooldown_cause] values are
   diagnostic-only. *)
