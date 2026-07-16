(** Keeper_types — health, continuity, and context types.

    This module owns types that cannot live closer to their consumer
    without creating circular dependencies.

    Formerly a facade that re-exported [Keeper_meta_contract],
    [Keeper_types_profile], [Keeper_meta_json], and [Keeper_meta_store].
    Removed by RFC-0205 — consumers access those modules directly
    via qualified names (e.g. [Keeper_meta_contract.keeper_meta]). *)

(** {1 Health types} *)

type fiber_health =
  | Fiber_alive
  | Fiber_zombie
  | Fiber_dead
  | Fiber_unknown

type keeper_health =
  | KH_healthy
  | KH_idle
  | KH_offline
  | KH_stale
  | KH_degraded
  | KH_zombie
  | KH_dead

type keeper_continuity =
  | Continuity_healthy
  | Continuity_recovering
  | Continuity_not_running

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
  checkpoint : Agent_sdk.Checkpoint.t;
  max_tokens : int;
}

type session_context = {
  session_id : string;
  session_dir : string;
}
