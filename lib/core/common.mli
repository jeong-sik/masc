(** Cross-cutting utilities used by many MASC subsystems.

    Kept small and dependency-light so every module can depend on it
    without introducing cycles. *)

val protect :
  module_name:string ->
  finally_label:string ->
  finally:(unit -> unit) ->
  (unit -> 'a) ->
  'a
(** Like [Fun.protect], but a failing [finally] is logged under [module_name]
    and [finally_label] instead of replacing the exception of the body. When
    the body returned normally, the failure is also re-raised if
    [MASC_STRICT_FINALIZERS] is ["1"], ["true"], ["yes"] or ["on"] (case and
    surrounding whitespace ignored). [Eio.Cancel.Cancelled] from [finally] is
    always re-raised. *)

val masc_dirname : string
(** SSOT directory name for MASC runtime state. Value is [".masc"].
    Call sites MUST reference this constant (or {!masc_dir_from_base_path})
    rather than inlining the literal — see #9571. *)

val owner_lease_dirname : string
(** Directory beside [<base_path>/.masc] that holds the BasePath owner lease
    when no lease root is configured. Value is [".masc-owner"]. *)

val searxng_dirname : string
(** The directory under [.masc] that is mounted into the SearXNG container as
    [/etc/searxng]. *)

val dos_dirname : string
(** The DOS machine's directory under [.masc]: its programs, saves and
    checkpoints. Value is ["dos"]. *)

val msx_dirname : string
(** The MSX machine's directory under [.masc]: its BIOS and cartridges.
    Value is ["msx"]. *)

val masc_dir_from_base_path : base_path:string -> string
(** [masc_dir_from_base_path ~base_path] is
    [Filename.concat base_path masc_dirname]. Canonical way to spell
    [<base_path>/.masc]. *)

val keepers_runtime_dirname : string
(** OUTPUT root segment for server-written keeper runtime state. Single literal
    behind both keeper-dir SSOT functions; the input/output relocation flips it. *)

val default_keepers_dirname : string
(** Config-tree directory holding the roster a fresh workspace starts with.
    Distinct from {!keepers_runtime_dirname}, which is where it lands. *)

val seeds_into_fresh_config_root : string -> bool
(** Whether a distribution config asset may be written into a fresh runtime
    config root {b verbatim}. Takes an asset path relative to the embedded
    [config/] tree ([runtime.toml], [prompts/keeper.md]) or a bare top-level
    entry name, so the filesystem seed and the embedded seed answer from one
    place.

    [false] for keeper manifests — the roster is declared per workspace, and the
    shipped examples autoboot into a sandbox the host may not have — for
    {!default_keepers_dirname}, which seeds under a different name and so is
    routed through {!fresh_config_root_keeper_seed_target}, for [dune], a
    build input rather than runtime config, and for [keeper.env], the retired
    deploy-time credential file, which must never seed fresh roots. *)

val fresh_config_root_keeper_seed_target : string -> string option
(** Where a {!default_keepers_dirname} asset lands in a fresh config root:
    [keepers-default/x.toml] becomes [Some "keepers/x.toml"]. [None] for every
    other path, including a non-[.toml] file in that directory.

    A fresh workspace gets exactly what this directory holds. It carries no
    autoboot, so it cannot repeat the 2026-09-05 failure the exclusion above
    was written for, and both seed paths route through here so the filesystem
    and embedded roots agree on the roster. *)

val keepers_runtime_dir_of_base : base_path:string -> string
(** [<base_path>/.masc/keepers] for callers holding only a [base_path].
    Low-level SSOT that avoids the Workspace dependency cycle
    [Workspace.keepers_runtime_dir] would impose. *)

type keeper_runtime_store =
  | Keeper_tool_usage
  | Keeper_runtime_manifests
  | Keeper_metrics
  | Keeper_execution_receipts
  | Keeper_turn_records
  | Keeper_provider_inputs
  | Keeper_memory_recall_artifacts
  | Keeper_reaction_ledger
  | Keeper_trajectories
  | Keeper_crash_events
  | Keeper_shutdown_operations
  | Keeper_configuration_removals
(** Canonical child-store names under {!keepers_runtime_dirname}. *)

val keeper_runtime_store_dirname : keeper_runtime_store -> string
val keeper_runtime_stores : keeper_runtime_store list

type keeper_runtime_store_placement =
  | Keeper_scoped_dated
      (** [keepers/<name>/<store>/YYYY-MM/DD.jsonl]. Grows without bound, so
          both the startup pass and the 24h pass prune it by age. *)
  | Keeper_scoped_versioned
      (** [keepers/<name>/<store>/v<N>/]. A schema change moves to the next
          directory and the previous one is simply never read again, which is
          what a hard cut is supposed to look like. *)
  | Keeper_scoped_rotated
      (** [keepers/<name>/<store>/<file>.jsonl] plus numeric rotations. The
          flat-file pass owns these, not the dated one. *)
  | Keepers_root_scoped
      (** [keepers/<store>/<file>]: beside the keeper directories, so a reader
          that walks [keepers/] must not take it for a keeper. No retention
          pass owns it. *)
  | Workspace_scoped
      (** [<masc root>/<store>]: named here for the dirname, but not written
          under [keepers/]. *)

val keeper_runtime_store_placement
  :  keeper_runtime_store
  -> keeper_runtime_store_placement
(** Where a store puts its files, and therefore which retention pass owns it.

    A store has to say where it lives, and the match is exhaustive, so the next
    one cannot be added without answering. *)

val keepers_root_store_dirnames : string list
(** Directory names of the stores placed [Keepers_root_scoped]: they sit
    beside the keeper directories under [keepers/], so no keeper may take one
    of these names. *)

val is_keepers_root_store_dirname : string -> bool
(** Whether [name] is one of {!keepers_root_store_dirnames}, ignoring ASCII
    case: on a case-insensitive filesystem (macOS APFS by default)
    [keepers/Tool_Usage] is the same directory as [keepers/tool_usage]. *)

val auth_dir_from_base_path : base_path:string -> string
(** [<base_path>/.masc/auth]. SSOT path so {!Auth} and
    {!Keeper_identity} can both compute it without depending on each
    other (RFC P2 cycle-break prep). *)

val agents_dir_from_base_path : base_path:string -> string
(** [<base_path>/.masc/auth/agents]. Same SSOT motivation as
    {!auth_dir_from_base_path}; this is where keeper credential JSON
    files live ([<agent_name>.json]). *)

val max_tool_result_wire_bytes : int
(** Ceiling for one tool result on the wire, below which an official-client
    CLI does not spill it to a file the Keeper cannot read.

    Bounds both halves of externalization: what becomes a blob, and how much
    of a blob one read returns, and it is the only ceiling on a tool result.
    A separate 64KB constant once carried both, which made a read of an
    externalized result exactly the size that gets spilled.

    It does not bound how much output the runtime accepts from a subprocess —
    that is {!max_process_capture_head_bytes} + {!max_process_capture_tail_bytes}.
    Conflating the two is what let a single [Execute] call retain 590MB. *)

val max_agent_core_inline_result_bytes : int
(** How much of one tool result MASC carries inline when it owns the wire.

    An agent-core lane has no CLI between the model and the result, so nothing
    spills and the reason {!max_tool_result_wire_bytes} is low does not apply.
    Bounding context growth is the only job left, so this is a separate number
    rather than the same one scaled.

    Applying the lower ceiling here turned a result the model could have read
    into a blob it had to fetch back, inside the same turn that produced it. *)

val max_process_capture_head_bytes : int
(** Bytes retained from the {e start} of one captured subprocess stream.
    Backed by a growable buffer, so this budget costs nothing until output
    actually reaches it. *)

val max_process_capture_tail_bytes : int
(** Bytes retained from the {e end} of one captured subprocess stream.
    Backed by a ring allocated eagerly at this size, so it is set to the
    256KB scale the dashboard already pays per keeper rather than to the
    head budget.

    Head + tail is the acceptance ceiling for a single stream. claude-code's
    comparable ceiling is 64 MiB, but it streams bash output to a file on
    disk while MASC retains the capture in memory for the turn, so the
    ceiling here is lower. The drainer keeps reading past the ceiling so the
    exit status and the tail (where failures report) stay exact; only
    retention is bounded, so memory is O(head + tail) rather than
    O(output). Elided bytes are reported by {!Exec_buffer.render}'s
    truncation marker rather than dropped silently. *)

val safe_filename : string -> string
(** Fold a value into one path component: lowercase, keep [a-z0-9._-], and
    escape anything else as [_XX]. Every layer that turns a name into a file
    name goes through this, so a name cannot mean two files. *)

val tool_call_read_index_basename : string
(** File name of the derived SQLite read index that [Keeper_tool_call_index]
    stores inside [<masc root>/tool_calls/]. Shared so the index owner and the
    durable-source scanners agree on one spelling. *)

val is_tool_call_read_index_file : string -> bool
(** Whether [path] (or a bare file name) names {!tool_call_read_index_basename}
    or one of the sidecar files SQLite creates beside it while the WAL or
    rollback journal is active ([-wal], [-shm], [-journal]). *)

val chat_operation_store_basename : string
(** File name of the authoritative SQLite operation store that
    [Keeper_chat_operation_store] keeps at
    [<masc root>/keepers/<keeper>/chat-operations.sqlite3]. Shared so the store
    owner and durable-source scanners agree on one spelling. *)

val is_chat_operation_store_sidecar_file : string -> bool
(** Whether [path] (or a bare file name) names one of the SQLite WAL or
    rollback-journal sidecar files beside {!chat_operation_store_basename}
    ([-wal], [-shm], [-journal]). Unlike {!is_tool_call_read_index_file}, the
    database file itself is authoritative and must be inspected rather than
    skipped. *)

val auth_dirname : string
(** The directory {!auth_dir_from_base_path} names below [<base>/.masc]. *)

val sqlite_wal_suffix : string
(** The suffix SQLite gives a database's write-ahead log. *)

val sqlite_shm_suffix : string
(** The suffix SQLite gives a database's shared-memory index. *)

val sqlite_journal_suffix : string
(** The suffix SQLite gives a database's rollback journal. *)

val recovery_mirror_suffix : string
(** The suffix of the last good copy a ledger keeps beside itself. *)

val tui_dirname : string
(** The TUI's directory below [<base>/.masc]. *)

val tui_music_dirname : string
(** The TUI music player's directory below [<base>/.masc]. *)

val tui_account_login_filename : string
(** The TUI's pending account login below [<base>/.masc]. *)

val tui_play_pending_filename : string
(** The TUI's pending Play requests below [<base>/.masc]. *)

val tui_artifact_share_pending_filename : string
(** The TUI's pending artifact shares below [<base>/.masc]. *)
