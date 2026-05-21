(** In-turn liveness pulse helpers for keeper heartbeat turns. *)

val in_turn_liveness_pulse_interval_sec : unit -> float

val with_in_turn_liveness_pulse_for_test :
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  interval_sec:float ->
  tick:(unit -> unit) ->
  (unit -> 'b) ->
  'b

val emit_in_turn_liveness_pulse :
  ctx:'a Keeper_types.context -> meta:Keeper_types.keeper_meta -> unit

val with_in_turn_liveness_pulse :
  ctx:'a Keeper_types.context ->
  meta:Keeper_types.keeper_meta ->
  stop:bool Atomic.t ->
  (unit -> 'b) ->
  'b
