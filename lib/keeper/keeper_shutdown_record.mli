(** Durable record written before a shutdown may unregister an interrupted
    Keeper lane. *)

val path :
  config:Workspace.config ->
  Keeper_shutdown_types.interrupted_turn ->
  string

val persist :
  config:Workspace.config ->
  Keeper_shutdown_types.interrupted_turn ->
  (Keeper_shutdown_types.persisted_interrupted_turn, string) result
