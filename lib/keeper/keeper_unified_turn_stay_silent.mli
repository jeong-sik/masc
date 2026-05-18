(** Stay-silent loop recovery helpers for the unified keeper turn. *)

val mark_loop_detected
  :  config:Coord.config
  -> Keeper_types.keeper_meta
  -> streak:int
  -> threshold:int
  -> Keeper_types.keeper_meta

val clear_if_recovered
  :  config:Coord.config
  -> Keeper_types.keeper_meta
  -> previous_streak:int
  -> was_latched:bool
  -> Keeper_types.keeper_meta
