(** Keeper_types — health, continuity, and context types.

    This module owns types that cannot live closer to their consumer
    without creating circular dependencies. *)

(** {1 Health types} *)

type fiber_health =
  | Fiber_alive
  | Fiber_zombie
  | Fiber_unknown

type keeper_health =
  | KH_healthy
  | KH_idle
  | KH_failing
  | KH_offline

(** {1 Per-tool usage tracking} *)

type tool_call_entry = {
  count : int;
  successes : int;
  deferred : int;
  failures : int;
  last_used_at : float;
}

(** {1 Working Context Types} *)

type working_context = {
  checkpoint : Agent_core.Checkpoint.t;
}

type session_context = {
  session_id : string;
  session_dir : string;
}
