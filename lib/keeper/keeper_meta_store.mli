(** Strict Keeper metadata snapshot storage.

    Included by [Keeper_types] so existing [Keeper_types.*] callers
    keep their read API while writes are restricted to complete Owner
    snapshots. *)

(** Read a keeper meta JSON file at [path]. Returns [Ok None] when the file
    does not exist, and also when it is JSON that does not decode as the
    current schema (an unknown, missing or wrong-typed field): that file is
    left exactly as it is, the loss is logged as a WARN, and the boot path
    re-materialises the Keeper from its declaration. [Error] when the file
    cannot be read or is not JSON. The read never writes the file.
    Existence and byte capture use one optional read; a denied or malformed
    parent path is a read error, not an absent metadata snapshot.

    The parse-failure WARN is emitted on state transitions (new failure,
    changed failure reason, recovery) per (site, path), not on every
    repeated read of the same broken file. *)
val read_meta_file_path :
  string ->
  (Keeper_meta_contract.keeper_meta option, string) result

(** What the store holds at a Keeper's canonical path, keeping the two
    cases [read_meta_file_path] folds into [Ok None] apart. *)
type meta_presence =
  | Meta_absent  (** No file at the path. *)
  | Meta_present of Keeper_meta_contract.keeper_meta
      (** The file decodes as the current schema. *)
  | Meta_not_current of string
      (** A file is at the path but this binary does not decode it as the
          current schema. [read_meta_file_path] reads it as absent and the
          boot path re-materialises the Keeper from its declaration. The
          string is the decode detail the runtime logs. *)

(** [read_meta_file_path] with the presence kept; the same decode decision
    and failure reporting, and no write. *)
val read_meta_file_path_presence : string -> (meta_presence, string) result

(** Why the deployment gate rejects a persisted Keeper meta, split by what
    the boot path does with the same file.  The two classes need different
    operator action, so the split is typed here rather than read out of the
    detail text. *)
type current_meta_rejection =
  | Unreadable of string
      (** The file cannot be read. [read_meta_file_path]
          returns [Error] for it and the boot path refuses the Keeper
          outright. Boot quarantine cannot bypass an I/O failure; repair
          file access or the file kind before restarting. *)
  | Invalid_json of string
      (** The bytes were read but are not JSON. [read_meta_file_path]
          returns [Error]; boot may quarantine the rejected bytes only
          after the operator accepts that loss of persisted state. *)
  | Not_current of string
      (** The JSON does not decode as the current schema. The ordinary
          runtime read treats it as absent (#29610), so boot reconciliation
          refuses it until it is repaired or explicitly accepted for
          quarantine. Re-materialising from the declaration loses the
          accumulated counters and persisted task binding. The lossless
          fix is stripping retired fields or filling missing ones. *)

val read_meta_file_path_read_only :
  ownership_root:string ->
  string ->
  (Keeper_meta_contract.keeper_meta option, current_meta_rejection) result
(** Strict no-follow snapshot read. It does not update failure-reporting
    state. *)

(** Deploy-gate twin of [read_meta_file_path]: the same exact decode,
    shared with the runtime read so the two cannot drift, minus the
    fail-open, retaining I/O and JSON parse failures as separate constructors.
    [Ok ()] when the runtime would keep the snapshot, or when
    there is no file at [path]; [Error] carries the class above and the same
    detail the runtime logs.  The deployment preflight runs this between the
    previous runtime's stop and the next one's start, so a rejection holds
    the plane down until the operator repairs the file and redeploys. *)
val validate_current_meta_file_result :
  string -> (unit, current_meta_rejection) result

(** [true] when [f] has an exact canonical Keeper-metadata interpretation. *)
(** List keeper names with persisted JSON in [.masc/keepers/].
    Sidecars filtered, names validated, sorted ascending. *)
val persisted_keeper_names_result : Workspace.config -> (string list, string) result
val persisted_keeper_names_read_only_result :
  Workspace.config -> (string list, string) result
(** Persisted metadata names without creating the store directory. An absent
    root is empty; an inaccessible or non-directory root is an error. *)
val retained_keeper_names_read_only_result :
  Workspace.config -> (string list, string) result
(** Union of persisted metadata owners and typed retained Keeper runtime
    directories, read without creating or repairing state. *)
val persisted_keeper_names : Workspace.config -> string list


(** What to do with a file at a Keeper's path that this binary cannot decode
    as the current schema ({!meta_presence}'s [Meta_not_current]). *)
type undecodable_meta =
  | Skip_undecodable_meta
      (** Read it as no Keeper, as {!read_meta_file_path} does. *)
  | Fail_on_undecodable_meta
      (** Make it the error, for a reader that must not take "cannot read" for
          "no such Keeper". *)

(** Every persisted Keeper's TOML-overlaid metadata with its canonical
    filename, in name order. The first Keeper that cannot be read is the
    error. *)
val persisted_effective_metas :
  on_undecodable:undecodable_meta ->
  Workspace.config ->
  ((string * Keeper_meta_contract.keeper_meta) list, string) result

(** The Keeper among [metas] (from {!persisted_effective_metas}) whose
    [mention_targets] contain [mention_target]. [Ok None] when none does, and
    an error when more than one does. *)
val keeper_for_mention_target_in :
  (string * Keeper_meta_contract.keeper_meta) list ->
  mention_target:string ->
  ((string * Keeper_meta_contract.keeper_meta) option, string) result

(** Resolve an exact configured [mention_target] against effective metadata.
    The canonical filename and the same TOML-overlaid metadata snapshot are
    returned together so delivery and pending-message classification use one
    authority. Duplicate claims, configuration errors, and metadata read
    failures are explicit errors. This is {!keeper_for_mention_target_in} over
    {!persisted_effective_metas}, so a mention target that is not a Keeper id
    reads no file. *)
val persisted_keeper_for_mention_target :
  Workspace.config ->
  mention_target:string ->
  ((string * Keeper_meta_contract.keeper_meta) option, string) result

(** List keeper names declared in TOML config (overlay sources). *)
val configured_keeper_names : Workspace.config -> string list

(** Primary keeper discovery: persisted JSON names. An [Error] means the
    Keeper directory did not list; it is not an empty fleet, and each caller
    decides what an unlisted fleet means where it reads it. *)
val keeper_names_result : Workspace.config -> (string list, string) result

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

(** [read_meta] with the presence kept: the same path and the same blank-name
    answer ([Meta_absent]), but a file this binary does not decode is
    [Meta_not_current] instead of folding into absence. Readers that decide
    on absence use this. *)
val read_meta_presence : Workspace.config -> string -> (meta_presence, string) result

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

(** [read_effective_meta] with the presence kept: [Meta_present] carries the
    TOML-overlaid snapshot, and an overlay failure is [Error]. An empty name
    is [Error]. Readers that decide on absence use this, since [Ok None]
    from [read_effective_meta] also covers a file this binary cannot
    decode. *)
val read_effective_meta_presence :
  Workspace.config -> string -> (meta_presence, string) result

(** The presence together with the Keeper identity minted from the requested
    name. The name is parsed once, here: a blank name is [Error] and every
    [Ok] carries an identity (RFC-0468 §3.1). *)
val read_effective_meta_presence_named :
  Workspace.config ->
  string ->
  (Keeper_identity.Keeper_id.t * meta_presence, string) result

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
