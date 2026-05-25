val keeper_meta_updated_ts : Keeper_types.keeper_meta -> float
val should_promote_legacy_keeper_meta :
  legacy_path:string -> current_path:string -> bool
val migrate_legacy_dirs_with_renames :
  Mcp_server.server_state -> (string * String.t) list -> unit
val migrate_legacy_dirs : Mcp_server.server_state -> unit
val migrate_legacy_keeper_dirs_blocking :
  Mcp_server.server_state -> unit
val default_room_for_flat_migration : string
val legacy_room_candidates : string -> string list
val infer_current_room_from_legacy_dirs : string -> string option
val load_current_room_or_default : string -> string -> string option
val migrate_room_to_flat : Mcp_server.server_state -> unit
val migrate_legacy_trace_dirs : Mcp_server.server_state -> unit
val startup_prune_jsonl : Mcp_server.server_state -> unit
val startup_prune_auth_archive : Mcp_server.server_state -> unit
val startup_migrate_keeper_histories :
  Mcp_server.server_state -> unit
