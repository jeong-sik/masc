(** Continuity summary reader for keeper world observation. *)

val read_continuity_summary
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> string
