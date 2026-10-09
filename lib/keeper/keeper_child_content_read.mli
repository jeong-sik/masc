(** Unprivileged closed Child read views, never runtime/binding/publication grants. *)
type receiver = { receiver_generation : string; session_id : string; client_uuid : string }
type scope = { keeper_name : string; receiver : receiver }
type cursor = { store_id : string; after_sequence : int }
type error_code =
  | Store_missing | Invalid_scope | Invalid_observation | Cursor_store_mismatch | Cursor_ahead
  | Store_corrupt | Conflicting_observation | Sequence_exhausted | Io_failed
  | Directory_prepare_failed | Store_unavailable | Commit_unconfirmed | Invalid_query | Invalid_keeper
(** Codes contain no filesystem path, exception details or secret body. *)
type coverage = Unavailable
(** Collector-local failure history is unavailable here, not an empty success
    history. Provider/historical completeness and liveness remain unknown. *)
type record = private { seq : int; recorded_at : float; observation : Keeper_child_content.view }
type storage = Audited of cursor | Failed of error_code
type entry = private { receiver : receiver; storage : storage }
type hint_storage = Unchecked of cursor | Hint_failed of error_code
type hint_entry = private { receiver : receiver; hint : hint_storage }
type records = private { scope : scope; records : record list; next_cursor : cursor;
  cleanup_failures : string list; coverage : coverage }
type receivers = private { keeper_name : string; receivers : entry list;
  cleanup_failures : string list; coverage : coverage }
type hints = private { keeper_name : string; hints : hint_entry list;
  cleanup_failures : string list; coverage : coverage }
type failure = private { error : error_code; coverage : coverage }
type response = Records of records | Receivers of receivers | Hints of hints | Failure of failure

type decode_error = Invalid_shape of string | Invalid_number of string
  | Invalid_child of Keeper_child_content.error | Scope_mismatch | Cursor_mismatch
  | Sequence_mismatch | Duplicate_observation | Duplicate_receiver | Unexpected_response
val decode_error_to_string : decode_error -> string
val error_code_of_journal : Keeper_child_content_journal.error -> error_code
val failure : error_code -> response
val records_of_journal : redact_text:(string -> string) -> scope:scope ->
  snapshot:Keeper_child_content_journal.snapshot ->
  cleanup_failures:Keeper_child_content_journal.cleanup_failure list -> response
val receivers_of_journal : keeper_name:string ->
  entries:Keeper_child_content_journal.discovery_entry list ->
  cleanup_failures:Keeper_child_content_journal.cleanup_failure list -> response
val hints_of_journal : keeper_name:string ->
  entries:Keeper_child_content_journal.hint_entry list ->
  cleanup_failures:Keeper_child_content_journal.cleanup_failure list -> response
(** One-way authoritative projections. Human body/model are redacted again at
    read serialization; protocol identities/evidence/refusal/absence stay exact. *)
val to_json : response -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (response,decode_error) result
(** Exact schemas masc.child_content.{records,receivers,hints,error}.v1. Unknown,
    duplicate, null, unsafe/nonfinite numeric and malformed members refuse.
    Child observations reuse their strict codec. Rows match full ticket3 scope,
    unique observation_id/ordinal/channel keys, increasing contiguous sequence
    and actual validation/cursor tail. Decode grants no privileged authority. *)
type records_request = { scope : scope; after : cursor option }
val records_of_response : request:records_request -> response -> (records,decode_error) result
(** Mandatory success matcher checks exact requested scope/incarnation and entire
    suffix after+1 (or1), including empty caught-up suffix. Public constructible
    request scope/cursor values are validated. Caller branches Failure first to
    retain typed service refusal; this matcher never defaults a failure to empty.
    Captured authenticated workspace belongs to connection/cache, not this DTO. *)
val receivers_of_response : keeper_name:string -> response -> (receivers,decode_error) result
val hints_of_response : keeper_name:string -> response -> (hints,decode_error) result
(** Hints remain unchecked; they never certify or clear an audited failure. *)
