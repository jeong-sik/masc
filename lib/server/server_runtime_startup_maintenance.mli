val prune_children_dirs : prune_dir:(string -> int) -> string -> int
(** Fold [prune_dir] over the immediate sub-directories of the given
    root path. Missing root counts 0; stray files are skipped.
    Exposed for unit tests. *)

val startup_prune_jsonl : Mcp_server.server_state -> unit

(** Boot-time pass over [.masc/keepers/*.json]: remove only keys in the
    explicit retired-key set (see
    [Keeper_meta_store.migrate_retired_keeper_meta_keys]). Exceptions are
    logged and swallowed — the next boot retries, and until then stale keys
    only keep producing the existing unknown-key warning. *)
val startup_migrate_retired_keeper_meta_keys : Mcp_server.server_state -> unit

(** Resolve crash-left keeper lifecycle journals before keeper metadata
    migrations, credential projection, autoboot, or request mutation paths. *)
val startup_recover_keeper_lifecycle_transactions :
  Mcp_server.server_state ->
  unit

val startup_migrate_keeper_histories :
  Mcp_server.server_state -> unit
