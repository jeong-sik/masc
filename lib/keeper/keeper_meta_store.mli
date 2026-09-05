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

(** Why the deployment gate rejects a persisted Keeper meta, split by what
    the boot path does with the same file.  The two classes need different
    operator action, so the split is typed here rather than read out of the
    detail text. *)
type current_meta_rejection =
  | Unreadable of string
      (** The file cannot be read or is not JSON.  [read_meta_file_path]
          returns [Error] for it and the boot path refuses the Keeper
          outright.  The lossless fix is restoring the file from backup. *)
  | Not_current of string
      (** The JSON does not decode as the current schema, even after the
          enumerated-field repair.  The boot path reads it as absent and
          re-materialises the Keeper from its declaration (#29610), losing
          the accumulated counters and the persisted task binding.  The
          lossless fix is stripping retired fields or filling missing ones. *)

val read_meta_file_path_read_only :
  ownership_root:string ->
  string ->
  (Keeper_meta_contract.keeper_meta option, current_meta_rejection) result
(** Strict no-follow snapshot read. It does not apply enumerated-field repair
    or update failure-reporting state. *)

(** Deploy-gate twin of [read_meta_file_path]: the same decode decision
    (exact decode, then the issue #28844 enumerated-field repair with a
    redecode), shared with the runtime read so the two cannot drift, minus
    the fail-open and the repair write.  [Ok ()] when the runtime would keep
    the snapshot, directly or after repairing it in place, or when there is
    no file at [path]; [Error] carries the class above and the same detail
    the runtime logs.  The deployment preflight runs this between the
    previous runtime's stop and the next one's start, so a rejection holds
    the plane down until the operator repairs the file and redeploys. *)
val validate_current_meta_file_result :
  string -> (unit, current_meta_rejection) result

(** [true] when [f] has an exact canonical Keeper-metadata interpretation. *)
(** List keeper names with persisted JSON in [.masc/keepers/].
    Sidecars filtered, names validated, sorted ascending. *)
val persisted_keeper_names_result : Workspace.config -> (string list, string) result
val retained_keeper_names_read_only_result :
  Workspace.config -> (string list, string) result
(** Union of persisted metadata owners and typed retained Keeper runtime
    directories, read without creating or repairing state. *)
val persisted_keeper_names : Workspace.config -> string list


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

(** Durably replace the complete current snapshot. The per-Keeper Owner is the
    only production caller and therefore the only write authority. Any failed
    durability stage remains an error even when the renamed bytes are visible
    in the current process. *)
val replace_snapshot :
  Workspace.config -> Keeper_meta_contract.keeper_meta -> (unit, string) result

(** Durably remove the current snapshot for a Keeper deleted by its Owner. *)
val remove_snapshot : Workspace.config -> name:string -> (unit, string) result

(** The one process-local record of store problems, keyed by a typed site
    and path. [should_report] is the write side (log-gating callers), the
    snapshot functions are the read side — the dashboard projects the same
    rows, so a failure is recorded once and read everywhere. *)
module Problem_report_state : sig
  type site =
    | Meta_read
    | Meta_read_changed
    | Meta_repair
    | Keepalive_scan
    | Persistent_scan

  type entry = {
    site : site;
    path : string;
    detail : string;
    first_observed : float;
  }

  val should_report : site:site -> path:string -> detail:string -> bool
  val clear : site:site -> path:string -> unit
  val site_to_string : site -> string
  val snapshot : unit -> entry list
  val snapshot_to_yojson : unit -> Yojson.Safe.t
  val reset : unit -> unit
end

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
