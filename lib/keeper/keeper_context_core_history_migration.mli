type history_migration_stats =
  { moved_lines : int
  ; dropped_lines : int
  ; kept_lines : int
  ; malformed_lines : int
  }

val empty_history_migration_stats : history_migration_stats
val has_world_state_signature : string -> bool
val migrate_session_history_logs : session_dir:string -> history_migration_stats

val history_path_for_source :
  session_dir:string -> source:string option -> string

val persist_message :
  ?source:string ->
  Keeper_types.session_context ->
  Agent_sdk.Types.message ->
  unit
