(** Registry entry construction shared by registration paths. *)

val create :
  base_path:string ->
  string ->
  Keeper_types.keeper_meta ->
  phase:Keeper_state_machine.phase ->
  conditions:Keeper_state_machine.conditions ->
  Keeper_registry_types.registry_entry
(** Allocate a fresh registry entry with per-fiber atomics/promises and
    default counters. *)
