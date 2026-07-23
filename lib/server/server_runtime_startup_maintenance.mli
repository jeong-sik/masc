val prune_children_dirs : prune_dir:(string -> int) -> string -> int
(** Fold [prune_dir] over the immediate sub-directories of the given
    root path. Missing root counts 0; stray files are skipped.
    Exposed for unit tests. *)

val keeper_scoped_dated_stores : string list
(** Dated-JSONL stores pruned keeper-scoped ([keepers/<name>/<store>]) by
    BOTH the startup pass and the 24h periodic pass. SSOT for both loops —
    never reintroduce an inline store list in either caller. *)

val prune_keeper_scoped_stores :
  prune_dir:(string -> int) -> masc_root:string -> int
(** Fold [prune_dir] over every [keepers/<name>/<store>] path, for each store
    in [keeper_scoped_dated_stores] and each keeper dir under
    [masc_root/keepers]. Missing keepers root counts 0. Shared by the startup
    pass and the 24h periodic pass so both prune the same store set.
    Exposed for unit tests. *)

val prune_flat_jsonl_older_than : days:int -> string -> int
(** Delete regular [*.jsonl] files directly under the given directory whose
    mtime is older than [days]; returns the number of files removed.
    Used for stores with a flat layout (e.g. [trajectories/<keeper>/])
    where [Dated_jsonl.prune] finds no [YYYY-MM] month dirs and is a no-op.
    Exposed for unit tests. *)

val startup_prune_jsonl : Mcp_server.server_state -> unit

(** Resolve crash-left keeper lifecycle journals before credential projection,
    autoboot, or request mutation paths. *)
val startup_recover_keeper_lifecycle_transactions :
  Mcp_server.server_state ->
  unit

val startup_migrate_keeper_histories :
  Mcp_server.server_state -> unit
