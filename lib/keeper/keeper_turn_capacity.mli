(** Global keeper-turn capacity gate.

    This is intentionally separate from {!Keeper_turn_holders}: holders are
    diagnostics for turns that are already running, while this module admits or
    rejects new turn bodies. *)

type rejection =
  { limit : int
  ; inflight : int
  ; waited_ms : int
  }

val with_turn_capacity :
  ?timeout_s:float ->
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (capacity_wait_ms:int -> 'a) ->
  ('a, rejection) result

val force_release_for_keeper : keeper_name:string -> int

val inflight_for_test : unit -> int
val reset_for_test : unit -> unit
