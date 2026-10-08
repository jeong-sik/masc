(** Sole-authority SQLite persistence for privately admitted native task observations.
    This does not extend provider receiver lifetime or establish event completeness. *)
type source =
  | Operation of Keeper_chat_operation.Operation_id.t
  | Autonomous_turn of Ids.Turn_ref.t

type error =
  | Invalid_scope of string
  | Invalid_observation of string
  | Missing_store
  | Corrupt of { line : int; detail : string }
  | Conflicting_uuid of string
  | Sequence_exhausted
  | Cursor_store_mismatch
  | Cursor_ahead
  | Io_failed of exn
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Store_unavailable of { operation : string; detail : string }
  | Commit_unconfirmed of string

type cleanup_failure = { operation : string; detail : string }
type record = private
  { seq : int; recorded_at : float; observation : Runtime_native_tasks.t }
type commit = Appended of record | Replayed of record
type 'a outcome =
  { result : ('a, error) result; cleanup_failure : cleanup_failure list }
(** Cleanup diagnostics never replace a known committed receipt or primary error. *)
type issue =
  { event_uuid : string; error : error option; cleanup_failure : cleanup_failure list }
type t
type publication
type reader

type cursor = private { store_id : string; after_sequence : int }
val cursor : store_id:string -> after_sequence:int -> (cursor, error) result
(** Strict nonempty incarnation and JSON-safe nonnegative sequence. The store ID
    is minted once with immutable metadata bound to the exact authenticated
    workspace/Keeper/receiver scope; copied foreign databases are rejected. An externally
    supplied cursor is checked against the actual store inside the read snapshot. *)
type validation = private { store_id : string; through_sequence : int }
type snapshot = private { validation : validation; records : record list }
val next_cursor : snapshot -> cursor

val create : base_path:string -> keeper_name:string -> source:source ->
  redact_text:(string -> string) -> t
val prepare : t -> attempt:Runtime_native_tasks.attempt ->
  Keeper_claude_task_binding.bound -> (publication, error) result
val append : publication -> commit outcome
(** One SQLite transaction derives sequence and UUID replay/conflict from disk.
    The collector's first transaction for a store incarnation audits full history;
    later writes validate the addressed row/new observation, schema/scope and tail
    boundary only. Unrelated historical semantic tampering can remain undetected
    until a full read or a new collector's first audit. No stat-based trust cache.
    SQLite busy is an immediate typed refusal. COMMIT failure is unconfirmed,
    not proof the event was never committed; reconcile with the same UUID. *)
val observe : t -> attempt:Runtime_native_tasks.attempt ->
  Keeper_claude_task_binding.bound -> commit outcome
val health : t -> issue list
val report : keeper_name:string -> commit outcome -> unit
val cleanup_failure_to_string : cleanup_failure -> string

val open_reader : base_path:string -> keeper_name:string ->
  receiver_generation:string -> session_id:string -> (reader, error) result
val reader_of_publication : publication -> reader
val path : reader -> string
val read : ?after:cursor -> reader -> snapshot outcome
(** READONLY, never creates a missing store. Every row in one SQLite read
    transaction is semantically validated before any selected rows are returned.
    [validation] names that exact fully audited snapshot, not later live state.
    No terminal row is not proof of task completion; no sequence gap is not proof
    that all provider events persisted. Storage failure history is not supplied. *)
val error_to_string : error -> string

type receiver = { receiver_generation : string; session_id : string }
type process_issue = { receiver : receiver option; issue : issue }
type issue_snapshot = { process_epoch : string; issues : process_issue list }
val issue_snapshot : base_path:string -> keeper_name:string -> (issue_snapshot,error) result
(** Known failure/cleanup snapshots from this server process only. No collector
    or DB handles retained; successful observations are not registered and do
    not clear prior failures. Historical coverage remains unknown. [None]
    receiver means publication preparation failed before a valid binding. *)
type discovery_entry = { receiver : receiver; state : (validation, error) result }
val discover : base_path:string -> keeper_name:string -> discovery_entry list outcome
(** Read-only descriptor-owned enumeration of canonical managed v2 directories.
    Every bound workspace root/ancestor, including empty Keeper/generation
    directories, must have the effective UID and lack group/other write
    permission; final descriptor/path validation repeats those checks.
    Cold absence is allowed only by an initial child open below a freshly
    validated bound workspace root. Root failures and failures after binding
    remain errors; an already enumerated generation disappearing is an error.
    Unknown filenames are ignored, never deleted. Includes receiver identities from known process
    issues even when a failed first append left no file. Outer errors mean
    enumeration failed; entry errors mean that receiver could not be validated.
    Neither an empty result nor a valid file proves historical completeness.
    Directory enumeration and later SQLite pathname opens are independent;
    this API does not establish owned leaf-open continuity or fix leaf TOCTOU. *)

module For_testing : sig
  val discover : before_read:(string -> unit) -> after_read:(string -> unit) ->
    base_path:string -> keeper_name:string -> discovery_entry list outcome
  (** Fault callbacks after actual directory binding and after enumeration.
      Uses the production descriptor-owned discovery path. *)
  val append_with_io : commit:(Sqlite3.db -> Sqlite3.Rc.t) ->
    close:(Sqlite3.db -> bool) -> publication -> commit outcome
  (** The actual append transaction with injected COMMIT/close operations.
      Callers retain the production transaction, validation and rollback paths. *)
end
