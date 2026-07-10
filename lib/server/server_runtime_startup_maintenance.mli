val startup_prune_jsonl : Mcp_server.server_state -> unit

(** Boot-time pass over [.masc/keepers/*.json]: rewrite files carrying
    keys outside the canonical serializer key set (see
    [Keeper_meta_store.canonicalize_persisted_meta_files]). Exceptions
    are logged and swallowed — the next boot retries, and until then
    stale keys only keep producing the existing unknown-key warning. *)
val startup_canonicalize_keeper_metas : Mcp_server.server_state -> unit

val startup_migrate_keeper_histories :
  Mcp_server.server_state -> unit
