(** Closed public native-task read envelopes. These are unprivileged views,
    distinct from journal records/publications and private runtime/input owners.
    No decoder constructs any of those capabilities. *)
type error_code =
  | Store_missing | Invalid_scope | Cursor_store_mismatch | Cursor_ahead
  | Store_corrupt | Conflicting_uuid | Sequence_exhausted | Io_failed
  | Directory_prepare_failed | Store_unavailable | Commit_unconfirmed
  | Invalid_query | Invalid_keeper

type decode_error =
  | Invalid_shape of string
  | Invalid_number of string
  | Invalid_observation of string
  | Scope_mismatch
  | Cursor_mismatch
  | Sequence_mismatch
  | Duplicate_event_uuid
  | Duplicate_receiver
  | Unexpected_response
val decode_error_to_string : decode_error -> string

type receiver = { receiver_generation : string; session_id : string }
type scope = { keeper_name : string; receiver : receiver }
type cursor = { store_id : string; after_sequence : int }
type record = private
  { seq : int; recorded_at : float; observation : Runtime_native_tasks.t }
type issue = private
  { receiver : receiver option; event_uuid : string; error : error_code option
  ; cleanup_failures : string list }
(** [None] receiver/error encodes the existing required explicit JSON null.
    Cleanup operations are diagnostics, never private exception details. *)
type health =
  | Unavailable of error_code
  | Process_only of { process_epoch : string; issues : issue list }
(** Coverage and all historical/provider completeness remain explicitly unknown.
    Presence/absence is not task or receiver liveness. *)
type storage = Audited of cursor | Failed of error_code
type entry = private { receiver : receiver; storage : storage }
type records = private
  { scope : scope; records : record list; next_cursor : cursor
  ; cleanup_failures : string list; health : health }
type receivers = private
  { keeper_name : string; receivers : entry list
  ; cleanup_failures : string list; health : health }
type failure = private { error : error_code; health : health option }
(** Absent health is allowed only for the existing early invalid-Keeper response;
    nested storage/issue errors never carry health. *)
type response = Records of records | Receivers of receivers | Failure of failure

val error_code_of_journal : Keeper_native_task_journal.error -> error_code
val failure : ?health:health -> error_code -> response
val health_of_journal :
  (Keeper_native_task_journal.issue_snapshot, Keeper_native_task_journal.error) result -> health
val records_of_journal : redact_text:(string -> string) -> scope:scope -> snapshot:Keeper_native_task_journal.snapshot ->
  cleanup_failures:Keeper_native_task_journal.cleanup_failure list -> health:health -> response
val receivers_of_journal : keeper_name:string ->
  entries:Keeper_native_task_journal.discovery_entry list ->
  cleanup_failures:Keeper_native_task_journal.cleanup_failure list -> health:health -> response
(** One-way projections from authoritative reads. Never a public-to-private cast. *)

val to_json : response -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (response, decode_error) result
(** Exact closed objects at every level. Required explicit nulls are accepted
    only at their existing nullable health leaves; missing/extra/duplicate keys,
    unknown schema/enums, nonfinite times and unsafe sequence numbers refuse.
    DTOs reuse Runtime_native_tasks.of_json. Rows must retain scope, distinct UUIDs,
    contiguous increasing sequence and the validation/next-cursor tail receipt.
    This structural decode cannot know the request's first sequence. *)

type records_request = { scope : scope; after : cursor option }
val records_of_response : request:records_request -> response ->
  (records, decode_error) result
(** Caller must use this after structural decoding: validates exact requested
    scope, requested store incarnation and complete suffix from after+1 (or 1),
    including an empty caught-up suffix. No implicit cursor reset/empty fallback.
    Validates public constructible request cursor numbers and incarnation too.
    Caller first branches on [Failure] to retain its typed service error/health;
    this success matcher refuses a failure/other endpoint as Unexpected_response.
    Workspace authority stays with the authenticated connection/cache key. *)
val receivers_of_response : keeper_name:string -> response ->
  (receivers, decode_error) result
