open Keeper_types

val in_turn_liveness_pulse_interval_sec : unit -> float

val with_in_turn_liveness_pulse_for_test :
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  interval_sec:float ->
  tick:(unit -> unit) ->
  (unit -> 'b) ->
  'b

val emit_in_turn_liveness_pulse :
  ctx:'a context -> meta:keeper_meta -> unit

val with_in_turn_liveness_pulse :
  ctx:'a context ->
  meta:keeper_meta ->
  stop:bool Atomic.t ->
  (unit -> 'b) -> 'b
