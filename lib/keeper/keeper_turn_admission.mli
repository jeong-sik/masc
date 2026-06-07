(** Central admission for keeper runtime-turn execution.

    This module owns the fleet-wide resource lease for [Runtime_turn]. It does
    not own per-keeper sequencing, autonomous FIFO fairness, voice I/O,
    sidecar output, or host FD/disk pressure gates. *)

type resource_kind =
  | Runtime_turn

type fleet_admission_state =
  | Running
  | Paused
  | Stopped

type runtime_capacity_snapshot =
  { resource_kind : resource_kind
  ; runtime_limit : int
  ; runtime_inflight : int
  }

type admission_error =
  | Fleet_paused
  | Fleet_stopped
  | Runtime_capacity_exceeded of runtime_capacity_snapshot

val resource_kind_to_string : resource_kind -> string
val fleet_admission_state_to_string : fleet_admission_state -> string
val admission_error_to_string : admission_error -> string

val configure_runtime_turn_limit : int -> unit
val runtime_turn_limit : unit -> int
val runtime_turn_inflight : unit -> int

val pause_fleet_admission : unit -> unit
val resume_fleet_admission : unit -> unit
val stop_fleet_admission : unit -> unit
val fleet_admission_state : unit -> fleet_admission_state

val acquire_runtime_turn_lease :
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  unit ->
  (unit, admission_error) result

val release_runtime_turn_lease : unit -> unit

val with_runtime_turn_lease :
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (unit -> 'a) ->
  ('a, admission_error) result

val reset_for_test : ?runtime_turn_limit:int -> unit -> unit
