(** Global + per-keeper keeper-turn capacity gate.

    Two-tier admission:
    - Global limit ([keeper.turn.capacity_limit], default 32): machine-level
      concurrent turn cap shared across all keepers.
    - Per-keeper limit ([keeper.turn.per_keeper_capacity_limit], default 2):
      prevents a single keeper from monopolising provider capacity.

    Both limits must be satisfied for admission. Rejection records which
    limit was hit so the caller can log the specific bottleneck. *)

type rejection =
  { limit : int
  ; inflight : int
  ; waited_ms : int
  ; per_keeper_limit : int
  ; per_keeper_inflight : int
  }

val with_turn_capacity :
  ?timeout_s:float ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (unit -> 'a) ->
  ('a, rejection) result

val inflight_for_test : unit -> int
val per_keeper_inflight_for_test : string -> int
