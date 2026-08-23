(** Strict Keeper metadata snapshot storage.

    Included by [Keeper_types] so existing [Keeper_types.*] callers
    keep their read API while writes are restricted to complete Owner
    snapshots. *)

(** Read a keeper meta JSON file at [path]. Returns [Ok None] when
    the file does not exist. Unknown top-level keys are rejected with a
    reset-required error.

    Issue #28844: a non-canonical value in an enumerated field with a
    canonical default (e.g. [last_proactive_outcome]) is auto-repaired in
    place through the normal serializer and the read proceeds; all other
    corruption keeps failing loud and the file is left untouched.
    [ownership_root] scopes the durable directory-chain fsync of the repair
    write when the caller knows the workspace root.

    The parse-failure WARN is emitted on state transitions (new failure,
    changed failure reason, recovery) per (site, path), not on every
    repeated read of the same broken file. *)
val read_meta_file_path :
  ?ownership_root:string ->
  string ->
  (Keeper_meta_contract.keeper_meta option, string) result

(** Deploy-gate twin of [read_meta_file_path]: the same decode-and-repair
    decision without the fail-open. [Ok ()] when the runtime keeps the
    persisted snapshot (directly or after the in-place enum repair);
    [Error] exactly when the runtime would discard the meta as unreadable
    and re-materialise the Keeper from its declaration, losing the
    accumulated counters and the persisted task binding. The deployment
    preflight calls this before the runtime swap. *)
val validate_current_meta_file_result : string -> (unit, string) result

(** [true] when [f] has an exact canonical Keeper-metadata interpretation. *)
(** List keeper names with persisted JSON in [.masc/keepers/].
    Sidecars filtered, names validated, sorted ascending. *)
val persisted_keeper_names_result : Workspace.config -> (string list, string) result
val persisted_keeper_names : Workspace.config -> string list

(** Resolve a Keeper name from its current persisted [agent_name] binding.
    [Ok None] means no persisted Keeper owns [agent_name]. A metadata read
    failure or duplicate identity is returned as [Error] and is never
    collapsed into an absent Keeper. *)
val persisted_keeper_name_for_agent_name :
  Workspace.config -> agent_name:string -> (string option, string) result

(** Resolve an exact configured [mention_target] against effective metadata.
    The canonical filename and the same TOML-overlaid metadata snapshot are
    returned together so delivery and pending-message classification use one
    authority. Duplicate claims, configuration errors, and metadata read
    failures are explicit errors. *)
val persisted_keeper_for_mention_target :
  Workspace.config ->
  mention_target:string ->
  ((string * Keeper_meta_contract.keeper_meta) option, string) result

(** List keeper names declared in TOML config (overlay sources). *)
val configured_keeper_names : Workspace.config -> string list

(** Primary keeper discovery: persisted JSON names. *)
val keeper_names_result : Workspace.config -> (string list, string) result
val keeper_names : Workspace.config -> string list

(** Default autoboot policy when a keeper has TOML config but no
    persisted JSON yet. *)
val declarative_autoboot_enabled_by_default : Workspace.config -> string -> bool
val effective_autoboot_enabled :
  Workspace.config -> string -> Keeper_meta_contract.keeper_meta -> bool

(** Names of keepers eligible for the keepalive fiber set —
    autoboot enabled, not paused. Logs and excludes on read failure
    (issue #8377); the WARN fires on failure-state transitions only
    (issue #28844). *)
val keepalive_keeper_names : Workspace.config -> string list

(** Names of keepers expected to persist across sessions. Mirrors
    [keepalive_keeper_names] for readers caring about durability
    rather than the keepalive fiber. *)
val persistent_agent_names : Workspace.config -> string list

(** Read the keeper meta for [name]. The name is the canonical keeper
    filename component; agent-name aliases are not retried here. Callers
    that accept aliases must normalize explicitly before reading. *)
val read_meta_resolved :
  Workspace.config ->
  string ->
  ((string * Keeper_meta_contract.keeper_meta) option, string) result

(** Like [read_meta_resolved] but discards the filename component. *)
val read_meta :
  Workspace.config -> string -> (Keeper_meta_contract.keeper_meta option, string) result

(** Read persisted keeper meta and overlay Keeper configuration defaults before
    returning it. Status/list/operator surfaces should use this for
    TOML-owned fields such as [sandbox_profile] and [network_mode]. *)
val read_effective_meta_resolved :
  Workspace.config ->
  string ->
  ((string * Keeper_meta_contract.keeper_meta) option, string) result

(** Like [read_effective_meta_resolved] but discards the filename component. *)
val read_effective_meta :
  Workspace.config -> string -> (Keeper_meta_contract.keeper_meta option, string) result

(** Read keeper meta only if the canonical [name] file's mtime exceeds
    [last_mtime]. Returns [Some (meta, mtime)] when changed, [None] when
    unchanged, missing, or unparsable (logs the parse-failure case). *)
val read_meta_if_changed :
  Workspace.config ->
  string ->
  last_mtime:float ->
  (Keeper_meta_contract.keeper_meta * float) option

(** Durably replace the complete current snapshot. The per-Keeper Owner is the
    only production caller and therefore the only write authority. Any failed
    durability stage remains an error even when the renamed bytes are visible
    in the current process. *)
val replace_snapshot :
  Workspace.config -> Keeper_meta_contract.keeper_meta -> (unit, string) result

(** Durably remove the current snapshot for a Keeper deleted by its Owner. *)
val remove_snapshot : Workspace.config -> name:string -> (unit, string) result

module For_testing : sig
  val settle_durable_replace
    :  string
    -> (unit, Keeper_fs.durable_write_error) result
    -> (unit, string) result

  val settle_durable_remove
    :  string
    -> (unit, Keeper_fs.durable_remove_error) result
    -> (unit, string) result
end
