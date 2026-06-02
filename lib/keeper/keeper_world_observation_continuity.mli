(** Continuity summary reader for keeper world observation. *)

val read_continuity_summary
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> string
