(** Submit exact-lane dead-tombstone finalization without blocking the
    supervisor sweep. *)
val cleanup_dead_tombstone :
  'a Keeper_types_profile.context ->
  Keeper_registry.registry_entry ->
  unit

(** Deliver the typed post-finalization event/hook. Registered by server boot
    before shutdown recovery starts. *)
val handle_completion :
  Workspace.config ->
  Keeper_shutdown_types.t ->
  Keeper_shutdown_types.completion_action ->
  (unit, string) result
