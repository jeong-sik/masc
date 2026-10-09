(** Durable received Child snapshots, independent of root chat bus/client lifetime.
    Source and attempt are captured execution facts, not inferred Task ownership. *)
type error =
  | Invalid_scope of string | Invalid_observation of string | Missing_store
  | Corrupt of { seq : int; detail : string }
  | Conflicting_observation of string
  | Sequence_exhausted | Cursor_store_mismatch | Cursor_ahead
  | Io_failed of exn
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Store_unavailable of { operation : string; detail : string }
  | Commit_unconfirmed of string
type cleanup_failure = { operation : string; detail : string }
type 'a outcome = { result : ('a,error) result; cleanup_failure : cleanup_failure list }
type record = private { seq : int; recorded_at : float; observation : Keeper_child_content.view }
(** [recorded_at] is the local append clock, not provider reception time or
    an ordering proof against root chat events. Sequence is local to this store. *)
type commit = Appended of record | Replayed of record
type issue = { observation_id : string; ordinal : int; channel : Runtime_claude_code.content_channel;
  error : error option; cleanup_failure : cleanup_failure list }
type t
type publication
type reader
type cursor = private { store_id : string; after_sequence : int }
type validation = private { store_id : string; through_sequence : int }
type snapshot = private { validation : validation; records : record list }
val create : base_path:string -> keeper_name:string -> source:Keeper_native_task_journal.source ->
  redact_text:(string -> string) -> t
val prepare : t -> attempt:Runtime_native_tasks.attempt ->
  Keeper_claude_task_binding.child_observation -> (publication,error) result
val append : publication -> commit outcome
(** One disk-owned SQLite write transaction allocates sequence and exact replay.
    Key is (actual observation_id, original ordinal, channel); full scoped payload
    must agree for replay. Unknown and later snapshots have distinct accepted IDs.
    Retry this same sealed redacted publication after Commit_unconfirmed; never
    remint a frame observation or reprepare with another source/redactor/attempt.
    Each block commits separately: receipts are not full-envelope completeness.
    First collector write audits history; later writes validate addressed row,
    immutable schema/full ticket scope and tail. No stat-based trust cache. *)
val observe : t -> attempt:Runtime_native_tasks.attempt ->
  Keeper_claude_task_binding.child_observation -> commit outcome
(** Collector-local failures only; after collector loss historical coverage is
    unknown. An empty list or a valid read is not completeness/liveness evidence. *)
val health : t -> issue list
val report : keeper_name:string -> commit outcome -> unit
val cursor : store_id:string -> after_sequence:int -> (cursor,error) result
val next_cursor : snapshot -> cursor
val open_reader : base_path:string -> keeper_name:string -> receiver_generation:string ->
  session_id:string -> client_uuid:string -> (reader,error) result
(** Caller captures authenticated workspace/Keeper; public payload cannot select
    them. All three actual invocation fields must match immutable store metadata. *)
val reader_of_publication : publication -> reader
val path : reader -> string
val read : ?after:cursor -> reader -> snapshot outcome
(** READONLY/no creation. Full semantic scope/key/sequence audit in one snapshot
    before suffix return; cursor must match actual store incarnation. Every row
    matches captured workspace/Keeper and all three ticket fields. This is not an
    automatic polling API: future repeated polling needs separate unchecked hints.
    Canonical directory preparation is reused; SQLite pathname open is separate
    from leaf checks and does not establish complete owned leaf-open continuity. *)
val error_to_string : error -> string
module For_testing : sig
  val append_with_io : commit:(Sqlite3.db -> Sqlite3.Rc.t) ->
    close:(Sqlite3.db -> bool) -> publication -> commit outcome
end
