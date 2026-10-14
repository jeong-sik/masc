val prune_children_dirs : prune_dir:(string -> int) -> string -> int
(** Fold [prune_dir] over the immediate sub-directories of the given
    root path. Missing root counts 0; stray files are skipped.
    Exposed for unit tests. *)

val prune_flat_jsonl_older_than : days:int -> string -> int




val keeper_scoped_flat_stores : string list
(** Flat-JSONL stores pruned keeper-scoped ([keepers/<name>/<store>]) by
    mtime in BOTH passes: [raw-traces] (one file per turn) and
    [runtime-manifests] (one rotated JSONL per trace). *)

val prune_shared_jsonl_stores :
  days:int -> masc_root:string -> int
(** Prune every shared retention-covered JSONL store in one fold: the
    date-split stores of {!Dated_jsonl.Store.all} by their own rules (with
    [days] as the operator window), then by mtime the flat [logs/] day
    files, keeper-scoped trajectories and [keeper_chat_events], flat
    [messages/] JSON files and [keeper_scoped_flat_stores]. [masc_root] is
    [<base>/.masc]. Both the startup pass and the 24h periodic pass call
    exactly this function so the covered-store set cannot drift. Returns the
    number of files removed. Exposed for unit tests. *)

type jsonl_prune_outcome = {
  pruned : int;  (** Files removed. *)
  days : int;  (** The window this pass used. *)
  source : Server_maintenance_toml_config.source;  (** Where the window came from. *)
  diagnostics : Server_maintenance_toml_config.diagnostic list;
      (** runtime.toml [maintenance] problems for the caller to log. *)
}

val retention_source_label : Server_maintenance_toml_config.source -> string
(** ["env"], ["runtime.toml"] or ["default"], for prune log lines. *)

val prune_jsonl_at_resolved_window : base_path:string -> jsonl_prune_outcome
(** One prune of {!prune_shared_jsonl_stores} under [<base_path>/.masc] at
    the window {!Server_maintenance_toml_config.resolve_retention_days} gives
    for the workspace runtime.toml under [base_path]. The startup pass and the 24h
    periodic pass both call this, so neither can read a different window. *)

val startup_prune_jsonl : Mcp_server.server_state -> unit

val startup_sweep_microvm_guests : Mcp_server.server_state -> unit
(** Collect abandoned guests with the runtime lifecycle lock. Failure is
    logged without failing server readiness. *)

val declared_keeper_names :
  keepers_dir:string -> (string list, string) result
(** The keepers a directory declares: the basenames of its [.toml] files, or
    the directory read failure. An unreadable directory is not an empty
    roster. *)

val unknown_typesafeai_exclusions :
  keepers_dir:string -> (string list, string) result
(** The names in [\[typesafeai\].excluded_keepers] that {!declared_keeper_names}
    does not list, or the declaration-directory read failure. *)

val report_unknown_typesafeai_exclusions : base_path:string -> unit
(** One warning per name {!unknown_typesafeai_exclusions} finds, or one
    directory-read warning without accusing any configured name. Called once
    the runtime table is loaded. *)

val report_unarmed_typesafeai_destinations : unit -> unit
(** One warning per destination {!Typesafeai_config.unarmed_destinations}
    finds. Called once the runtime table is loaded. *)

val start_microvm_guest_maintenance :
  sw:Eio.Switch.t -> sweep:(unit -> unit) -> unit
(** Fork a switch-owned startup sweep outside the Keeper readiness barrier.
    Logs start, completion, failure, and cancellation; shutdown cancels the
    maintenance fiber. The runtime's protected lifecycle section completes
    before cancellation takes effect; each CLI command retains its timeout.
    [sweep] owns per-backend outcome observations. *)
