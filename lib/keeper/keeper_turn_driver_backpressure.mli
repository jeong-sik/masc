(** Keeper_turn_driver_backpressure — Capacity backpressure classification.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Pure functions: classify HTTP/agent-core errors into capacity backpressure signals.

    @since God file decomposition *)

(* [capacity_backpressure_of_core_error] was removed (#23438): a dead substring
   classifier that laundered opaque [Internal] errors into the auto-recoverable
   capacity-backpressure class. *)
