(** Deliver the typed post-finalization event. Registered by server boot
    before shutdown recovery starts. *)
val handle_completion :
  Keeper_shutdown_types.t ->
  Keeper_shutdown_types.completion_action ->
  (unit, string) result
