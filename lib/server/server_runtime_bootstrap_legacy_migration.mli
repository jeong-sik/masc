(** Runtime bootstrap migration helpers for old on-disk directory names. *)

val keeper_meta_updated_ts : Keeper_types.keeper_meta -> float
val should_promote_legacy_keeper_meta : legacy_path:string -> current_path:string -> bool

val migrate_legacy_dirs_with_renames
  :  Mcp_server.server_state
  -> (string * string) list
  -> unit

val migrate_legacy_dirs : Mcp_server.server_state -> unit
val migrate_legacy_keeper_dirs_blocking : Mcp_server.server_state -> unit
