(** Keeper meta store I/O and CAS write helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers
    keep their public API while durable meta storage is separated
    from the compatibility facade. *)


(** Hook invoked after each successful [write_meta] /
    [write_meta_with_merge]. Reset by the runtime to keep
    [Workspace_state] caches in sync. *)
val runtime_meta_write_sync_hook :
  Workspace.config -> Keeper_meta_contract.keeper_meta -> unit

(** Replace [runtime_meta_write_sync_hook] with [f]. *)
val register_runtime_meta_write_sync :
  (Workspace.config -> Keeper_meta_contract.keeper_meta -> unit) -> unit

(** Pre-compiled regex matching the CAS [meta version conflict]
    error message. Exposed for symmetry — used internally by
    [is_version_conflict_error]. *)
val version_conflict_re : Re.re

(** Read a keeper meta JSON file at [path]. Returns [Ok None] when
    the file does not exist; warns on unknown keys; scrubs deprecated
    persisted fields before parsing. *)
val read_meta_file_path :
  string -> (Keeper_meta_contract.keeper_meta option, string) result

(** Sidecar stem suffixes (without the trailing [.json]). Files
    matching [<name><suffix>.json] are filtered out of the keeper
    discovery scan (e.g. [<name>.dataset.json]). *)
val keeper_sidecar_stem_suffixes : string list

(** [true] iff [f] is a [.json] file whose stem is not a sidecar. *)
val is_keeper_meta_file : string -> bool

(** List keeper names with persisted JSON in [.masc/keepers/].
    Sidecars filtered, names validated, sorted ascending. *)
val persisted_keeper_names_result : Workspace.config -> (string list, string) result
val persisted_keeper_names : Workspace.config -> string list

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
    (issue #8377). *)
val keepalive_keeper_names : Workspace.config -> string list

(** Names of paused keepers whose durable meta should still be inspected
    during supervisor reconciliation. These keepers are not keepalive
    execution candidates, but a previous runtime may have left them paused
    while still owning an active backlog task. *)
val paused_reconcile_keeper_names : Workspace.config -> string list

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

(** Read persisted keeper meta and overlay TOML/persona defaults before
    returning it. Status/list/operator surfaces should use this for
    TOML-owned fields such as [sandbox_profile], [network_mode], and
    [tool_access]. *)
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

(** Atomic write of [persisted] to [path]; runs the
    [runtime_meta_write_sync_hook] on success. *)
val persist_meta :
  Workspace.config -> string -> Keeper_meta_contract.keeper_meta -> (unit, string) result

(** Persist [m] with a CAS bump on [meta_version]: the write is rejected
    if the on-disk version has moved since [m] was read. There is no force
    / bypass path — cumulative usage counters are a monotone invariant
    (RFC-0225 §3.2, RFC-0237), so callers that lost a race must resolve the
    conflict through {!write_meta_with_merge}, not overwrite the disk. *)
val write_meta :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  (unit, string) result

type identity_update_error =
  | Identity_missing
  | Identity_changed
  | Identity_read_failed of string
  | Identity_write_failed of string

val identity_update_error_to_string : identity_update_error -> string

(** Re-read and CAS-update [name] only while its trace/generation identity
    matches the shutdown snapshot. Every CAS retry rechecks identity before
    applying [update], so a replacement generation is never overwritten. *)
val update_meta_if_identity :
  Workspace.config ->
  name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  generation:int ->
  (Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta) ->
  (Keeper_meta_contract.keeper_meta, identity_update_error) result

type identity_remove_error =
  | Remove_identity_missing
  | Remove_identity_changed
  | Remove_identity_read_failed of string
  | Remove_identity_unlink_failed of string

val identity_remove_error_to_string : identity_remove_error -> string

(** Remove [name]'s meta only while the same trace/generation still occupies
    the path. This shares the per-path lock used by [write_meta]. *)
val remove_meta_if_identity :
  Workspace.config ->
  name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  generation:int ->
  (unit, identity_remove_error) result

(** [true] iff [msg] matches [version_conflict_re]. *)
val is_version_conflict_error : string -> bool

(** Strip retired top-level keys from persisted keeper meta files —
    fields left behind by schema removals (e.g. the #23929 continuity
    purge left [last_continuity_update_ts]/[continuity_summary] in
    [.masc/keepers/], re-warning on every read until the next save;
    dormant keepers never save). Deletion is destructive, so the drop
    set is an explicit in-code list ([retired_keeper_meta_key_names]),
    not a set derived from the codec: parser-consumed keys the
    serializer never emits ([autoboot_enabled], [compaction_mode],
    [keeper_name], ...) must survive, and deriving the complement was
    twice shown to misclassify them. Forgetting to extend the list is
    fail-safe — the unknown-keys warning keeps firing until the key is
    added. Retired keys are filtered out of the raw JSON in place
    ([Keeper_fs.save_json_atomic]); no re-serialization, no
    [meta_version] bump, every surviving field keeps its exact on-disk
    value. Unreadable or parser-rejected files are logged and preserved
    untouched. Call once at boot BEFORE keeper loops start; the write is
    not CAS-guarded, so the only writers that can race it are external
    request-driven mutations inside the per-file read/save span during
    boot — a CAS-guarded loser self-heals on its retry path. *)
val migrate_retired_keeper_meta_keys : Workspace.config -> unit

(** Retry [write_meta] on CAS version conflicts using caller-declared
    field ownership via [merge]. Use [Keeper_meta_merge.caller_wins]
    for payload-wins writes, or a narrower merge such as
    [Keeper_meta_merge.heartbeat_fields_from_disk] when concurrent
    writers own specific fields. *)
val write_meta_with_merge :
  ?max_retries:int ->
  merge:(latest:Keeper_meta_contract.keeper_meta -> caller:Keeper_meta_contract.keeper_meta -> Keeper_meta_contract.keeper_meta) ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  (unit, string) result
