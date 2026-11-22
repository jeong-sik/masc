val prune_flat_jsonl_older_than : days:int -> string -> int
(** Flat-file mtime retention under an absolute physical directory spelling.
    Root links are refused; production passes use a held runtime root. *)
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
    exactly this function so the covered-store set cannot drift. One admitted
    physical runtime-root descriptor owns all traversal and unlink operations;
    configured BasePath aliases are resolved before that binding, while runtime
    root/descendant links are refused or skipped. This is per-pass containment,
    not boot-pinned root continuity. Each Keeper whose turn-record day files
    it removed is told to {!Keeper_memory_health_input}: the Keeper's memory
    health row reads the newest of them. Returns the number of files removed.
    Exposed for unit tests. *)

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
(** Run one retention pass. Exceptions, including cancellation, propagate to
    the owning maintenance runner for observation and isolation. *)

val startup_sweep_microvm_guests : Mcp_server.server_state -> unit
(** Collect abandoned guests with the runtime lifecycle lock. Failure is
    logged without failing server readiness. *)

val startup_count_superseded_lanes : Mcp_server.server_state -> unit
(** Log one {!Lane_addon_superseded_census} line: the bytes of the retained
    Lane instances {!Lane_addon_superseded.plan} finds eligible for deletion,
    of the ones it keeps, and of [observations]. Sizes are read on a worker
    domain. Moves and deletes nothing. *)

val prune_empty_completion_review_dirs : masc_root:string -> int
(** Remove empty [completion-review-*] directories under [<masc_root>/keepers]
    (and their empty dated/flat store subdirectories) without following
    symlinks. Non-empty or active review directories are preserved. *)

val prune_settled_verifier_executions :
  ?now:float ->
  base_path:string ->
  days:int ->
  unit ->
  (int, string) result
(** Remove aged [<base_path>/.masc/verifier-executions/<digest>] directories
    whose digest is no longer referenced by any live [verifier-reviews] owner
    record and whose entire tree is strictly older than [days]. Fails closed
    without deleting anything if live review records cannot be read or if any
    symlink is encountered. *)

val sweep_atomic_orphans :
  base_path:string -> Fs_compat.atomic_orphan_cleanup_report
(** Run {!Fs_compat.cleanup_atomic_orphans} on [.masc/] roots with
    [unlink_private_jsonl_stages:true] (removing dead un-flocked
    [.private_jsonl_*.stage] files while preserving live flocked writers) and
    [recovery_parent] set to the classified [fs-publication-recovery] root so
    no unclassified [.masc/.recovered] directory is created. *)

type stale_lock_sweep_report =
  { removed : int
  ; kept_held : int
  ; kept_target_present : int
  ; failed : int
  }

val sweep_stale_durable_locks : base_path:string -> stale_lock_sweep_report
(** Sweep unheld, target-absent durable [.lock] files across
    [antigravity-*.prepare.lock], [board_attention_candidates/*.jsonl.lock],
    [artifact_drafts/*.json.lock], and [traces/*.checkpoint.lock] using
    {!File_lock_eio.unlink_if_unheld}. Never unlinks a held lock or a lock
    whose target or declared Keeper still exists. *)

type temp_orphan_sweep_report =
  { removed_files : int
  ; removed_dirs : int
  ; skipped_live : int
  ; failed : int
  }

val sweep_stale_temp_orphans :
  ?temp_dir:string ->
  ?min_age_seconds:float ->
  ?is_pid_alive:(int -> bool) ->
  ?now:float ->
  unit ->
  temp_orphan_sweep_report
(** Sweep orphaned MASC temp files/directories owned by the effective UID under
    [temp_dir] (default {!Filename.get_temp_dir_name}). PID-tagged entries are
    removed only when their creator PID is confirmed dead; untagged legacy
    entries are removed only when their entire tree is older than
    [min_age_seconds] (default 24h). Symlinks and unrelated entries are never
    touched. *)

val startup_sweep_orphan_hygiene : Mcp_server.server_state -> unit
(** Run boot-time orphan hygiene (atomic staging orphans, stale durable locks,
    settled shutdown-operation directories, settled verifier execution trees,
    and dead/aged temp artifacts) off the main Eio domain. *)

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

val unknown_memory_recall_keepers :
  keepers_dir:string -> (string list, string) result
(** The names in [\[typesafeai\].memory_recall_keepers] that
    {!declared_keeper_names} does not list, or the declaration-directory read
    failure. When no name is listed the directory is not read: the answer is
    [Ok []] whatever the directory is. *)

val report_unknown_memory_recall_keepers : base_path:string -> unit
(** One warning per name {!unknown_memory_recall_keepers} finds, or one
    directory-read warning without accusing any configured name. Called once
    the runtime table is loaded. *)

val report_unarmed_typesafeai_destinations : unit -> unit
(** One warning per destination {!Typesafeai_config.unarmed_destinations}
    finds. Called once the runtime table is loaded. *)

type task =
  | Jsonl_retention
  | Microvm_guest_sweep
  | Superseded_lane_census
  | Orphan_hygiene_sweep

val start_maintenance :
  sw:Eio.Switch.t -> task:task -> run:(unit -> unit) -> unit
(** Fork switch-owned startup maintenance outside the Keeper readiness barrier.
    Logs start, completion, failure, and cancellation; shutdown cancels the
    maintenance fiber. Ordinary failure is observed without failing readiness.
    [task] identifies observations; [run] supplies the work. The microVM
    runtime's protected lifecycle section completes before cancellation takes
    effect and each CLI command retains its timeout. *)
