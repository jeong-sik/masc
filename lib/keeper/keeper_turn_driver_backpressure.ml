(** Keeper_turn_driver_backpressure — Capacity backpressure classification.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Pure functions: classify HTTP/agent-core errors into capacity backpressure signals.

    @since God file decomposition *)

open Keeper_internal_error

(* [capacity_backpressure_of_core_error] was removed (#23438).  It classified an
   [Agent_core.Error.Internal msg] into [Capacity_backpressure] via a substring
   match ([message_looks_like_capacity_backpressure]) — a string classifier that
   laundered opaque internal errors into the permanently-transient (auto-
   recoverable, not-counting-toward-crash) class, the same failure mode that
   made deterministic cooldowns oscillate.  The function had no live callers. *)
