(** Deliver the typed post-finalization event/hook. Registered by server boot
    before shutdown recovery starts. *)
val handle_completion :
  Workspace.config ->
  Keeper_shutdown_types.t ->
  Keeper_shutdown_types.completion_action ->
  (unit, string) result
