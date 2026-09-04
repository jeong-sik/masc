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




val keeper_scoped_flat_stores : string list
(** Flat-JSONL stores pruned keeper-scoped ([keepers/<name>/<store>]) by
    mtime in BOTH passes: [raw-traces] (one file per turn) and
    [runtime-manifests] (one rotated JSONL per trace). SSOT like
    [keeper_scoped_dated_stores]. *)

val top_level_dated_stores : string list
(** Top-level dated-JSONL stores under the masc root pruned by BOTH the
    startup pass and the 24h periodic pass. SSOT for both loops — never
    reintroduce an inline store list in either caller. *)

val prune_shared_jsonl_stores :
  prune_dir:(string -> int) -> days:int -> masc_root:string -> int
(** Prune every shared retention-covered JSONL store in one fold:
    [top_level_dated_stores], flat [logs/] day files, keeper-scoped
    trajectories and [keeper_chat_events], [resilience_audit],
    [decision_audit], flat [messages/] JSON files,
    [keeper_scoped_dated_stores], [keeper_scoped_versioned_stores] and
    [keeper_scoped_flat_stores]. Both the startup pass and the 24h periodic
    pass call exactly this function so the covered-store set cannot drift.
    Returns the number of files removed. Exposed for unit tests. *)

val startup_prune_jsonl : Mcp_server.server_state -> unit

val startup_sweep_microvm_guests : Mcp_server.server_state -> unit
(** Remove microvm guests whose owning server is gone. Runs at boot, before
    this process owns any guest, so every candidate belongs to an earlier
    server -- and one still running keeps its own pid alive, which is what
    stops a second server from collecting a first one's guests. Failure is
    logged: a leaked guest costs memory, a refused boot costs the fleet. *)
