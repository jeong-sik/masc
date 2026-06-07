(** Global + per-keeper keeper-turn capacity gate.

    This is intentionally separate from {!Keeper_turn_holders}: holders are
    diagnostics for turns that are already running, while this module admits or
    rejects new turn bodies. *)

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
  (capacity_wait_ms:int -> 'a) ->
  ('a, rejection) result

val inflight_for_test : unit -> int
val per_keeper_inflight_for_test : string -> int
