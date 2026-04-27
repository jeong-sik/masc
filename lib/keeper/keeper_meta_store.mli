(** Keeper meta store I/O and CAS write helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers
    keep their public API while durable meta storage is separated
    from the compatibility facade. *)

open Keeper_types_profile
open Keeper_meta_contract

(** Hook invoked after each successful [write_meta] /
    [write_meta_with_retry] / [write_meta_with_merge]. Reset by the
    runtime to keep [Coord_state] caches in sync. *)
val runtime_meta_write_sync_hook :
  (Coord.config -> keeper_meta -> unit) ref

(** Replace [runtime_meta_write_sync_hook] with [f]. *)
val register_runtime_meta_write_sync :
  (Coord.config -> keeper_meta -> unit) -> unit

(** Pre-compiled regex matching the CAS [meta version conflict]
    error message. Exposed for symmetry — used internally by
    [is_version_conflict_error]. *)
val version_conflict_re : Re.re

(** Read a keeper meta JSON file at [path]. Returns [Ok None] when
    the file does not exist; warns on unknown keys; scrubs deprecated
    persisted fields before parsing. *)
val read_meta_file_path :
  string -> (keeper_meta option, string) result

(** Sidecar stem suffixes (without the trailing [.json]). Files
    matching [<name><suffix>.json] are filtered out of the keeper
    discovery scan (e.g. [<name>.dataset.json]). *)
val keeper_sidecar_stem_suffixes : string list

(** [true] iff [f] is a [.json] file whose stem is not a sidecar. *)
val is_keeper_meta_file : string -> bool

(** List keeper names with persisted JSON in [.masc/keepers/].
    Sidecars filtered, names validated, sorted ascending. *)
val persisted_keeper_names : Coord.config -> string list

(** List keeper names declared in TOML config (overlay sources). *)
val configured_keeper_names : Coord.config -> string list

(** Primary keeper discovery: persisted JSON names. *)
val keeper_names : Coord.config -> string list

(** Default autoboot policy when a keeper has TOML config but no
    persisted JSON yet. *)
val declarative_autoboot_enabled_by_default : string -> bool

(** Names of keepers eligible for the keepalive fiber set —
    autoboot enabled, not paused. Logs and excludes on read failure
    (issue #8377). *)
val keepalive_keeper_names : Coord.config -> string list

(** Names of keepers expected to persist across sessions. Mirrors
    [keepalive_keeper_names] for readers caring about durability
    rather than the keepalive fiber. *)
val persistent_agent_names : Coord.config -> string list

(** Re-exports from [Keeper_identity] kept on this module for the
    [Keeper_types.*] facade. *)
val keeper_name_from_agent_name : string -> string option
val canonical_keeper_name_from_agent_name : string -> string option
val canonical_keeper_name : string -> string option

(** Variants of [name] used for alias-tolerant lookup
    ([_]/[-] swap). Order-preserving + deduped. *)
val separator_alias_variants : string -> string list

(** Read the keeper meta for [name] under alias-tolerant lookup
    (separator variants + agent-alias derivation). Returns the
    matched filename component plus the parsed meta. *)
val read_meta_resolved :
  Coord.config ->
  string ->
  ((string * keeper_meta) option, string) result

(** Like [read_meta_resolved] but discards the filename component. *)
val read_meta :
  Coord.config -> string -> (keeper_meta option, string) result

(** Read keeper meta only if the file's mtime exceeds [last_mtime].
    Returns [Some (meta, mtime)] when changed, [None] when unchanged,
    missing, or unparsable (logs the parse-failure case). *)
val read_meta_if_changed :
  Coord.config ->
  string ->
  last_mtime:float ->
  (keeper_meta * float) option

(** Current UTC timestamp as ISO-8601 (Z-suffixed). *)
val current_utc_timestamp : unit -> string

(** Refresh the [Updated:] line in the keeper progress markdown.
    Best-effort — swallows all exceptions. *)
val refresh_progress_updated_line : Coord.config -> string -> unit

(** Atomic write of [persisted] to [path]; runs the
    [runtime_meta_write_sync_hook] and refreshes the progress
    timestamp on success. *)
val persist_meta :
  Coord.config -> string -> keeper_meta -> (unit, string) result

(** Persist [m] with a CAS bump on [meta_version]. When [force] is
    set, the version is bumped without checking the disk version. *)
val write_meta :
  ?force:bool ->
  Coord.config ->
  keeper_meta ->
  (unit, string) result

(** [true] iff [msg] matches [version_conflict_re]. *)
val is_version_conflict_error : string -> bool

(** Like [write_meta] but retries up to [max_retries] times on a
    CAS version conflict, lifting the caller's payload onto the
    latest disk version each retry. Caller payload wins at the
    field level (see #9764/#9733/#9769). Heartbeat must NOT use
    this helper — it would invert the data-loss tradeoff. *)
val write_meta_with_retry :
  ?max_retries:int ->
  Coord.config ->
  keeper_meta ->
  (unit, string) result

(** Like [write_meta_with_retry] but lets the caller declare field
    ownership via [merge]. Used by the turn-failure / cycle path
    via [Keeper_meta_merge.heartbeat_fields_from_disk] so retry
    does not clobber heartbeat-owned fields. *)
val write_meta_with_merge :
  ?max_retries:int ->
  merge:(latest:keeper_meta -> caller:keeper_meta -> keeper_meta) ->
  Coord.config ->
  keeper_meta ->
  (unit, string) result
