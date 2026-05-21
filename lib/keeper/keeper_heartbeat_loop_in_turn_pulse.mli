(** In-turn liveness pulse helpers for keeper heartbeat loops. *)

open Keeper_types

val in_turn_liveness_pulse_interval_sec : unit -> float

val with_in_turn_liveness_pulse_for_test :
  sw:Eio.Switch.t ->
  clock:'clock Eio.Time.clock ->
  interval_sec:float ->
  tick:(unit -> unit) ->
  (unit -> 'result) ->
  'result

val emit_in_turn_liveness_pulse :
  ctx:'clock context -> meta:keeper_meta -> unit

val with_in_turn_liveness_pulse :
  ctx:'clock context ->
  meta:keeper_meta ->
  stop:bool Atomic.t ->
  (unit -> 'result) ->
  'result
