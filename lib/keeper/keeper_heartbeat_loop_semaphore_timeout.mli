(** Semaphore-wait timeout helpers for the keeper heartbeat loop. *)

type semaphore_wait_observation_kind =
  Keeper_heartbeat_loop_observations.semaphore_wait_observation_kind =
  | Semaphore_wait_pending
  | Semaphore_wait_timeout

val record_semaphore_wait_observation
  :  ?phase_label:string
  -> base_path:string
  -> keeper_name:string
  -> channel:Keeper_world_observation.keeper_cycle_channel
  -> kind:semaphore_wait_observation_kind
  -> unit
  -> unit

val semaphore_wait_timeout_blocker_class
  :  Keeper_turn_slot.semaphore_wait_timeout
  -> Keeper_types.blocker_class

val semaphore_wait_timeout_diagnostics
  :  cascade_name:string
  -> Keeper_turn_slot.semaphore_wait_timeout
  -> string * string

val handle_semaphore_wait_timeout
  :  ctx:'a Keeper_types.context
  -> meta_after_triage:Keeper_types.keeper_meta
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> Keeper_turn_slot.semaphore_wait_timeout
  -> Keeper_types.keeper_meta
